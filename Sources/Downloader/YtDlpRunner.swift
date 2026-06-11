import Foundation

/// Drives one yt-dlp `Process` per job.
/// - `fetchMetadata`: `yt-dlp -J --no-playlist <url>` → decoded `VideoMetadata`.
/// - `startDownload`: real download with parseable progress lines on stdout.
/// All `onProgress`/`completion` callbacks are delivered on the main actor.
final class YtDlpRunner {

    enum RunnerError: LocalizedError {
        case ytDlpMissing
        case cancelled
        case noOutputPath
        case processFailed(status: Int32, stderrTail: String)
        case metadataDecodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .ytDlpMissing:
                return "yt-dlp is not installed. Install it from Settings → Downloads."
            case .cancelled:
                return "Download cancelled."
            case .noOutputPath:
                return "yt-dlp finished but did not report an output file."
            case .processFailed(let status, let stderrTail):
                let detail = stderrTail.isEmpty ? "no error output" : stderrTail
                return "yt-dlp exited with status \(status): \(detail)"
            case .metadataDecodingFailed(let detail):
                return "Could not read video information: \(detail)"
            }
        }
    }

    /// Produces stdout lines like `FUSEP|  42.7%|  3.21MiB/s|00:35` (see ProgressParser).
    static let progressTemplate =
        "download:FUSEP|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"

    // MARK: - Metadata

    func fetchMetadata(url: String) async throws -> VideoMetadata {
        guard ToolManager.shared.ytDlpInstalled else { throw RunnerError.ytDlpMissing }
        let ytDlp = ToolManager.shared.ytDlpURL
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = ytDlp
                process.arguments = ["-J", "--no-playlist", url]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Drain stderr asynchronously so a chatty stderr can never fill
                // its 64 KB pipe buffer and deadlock the stdout read below.
                let stderrSync = DispatchQueue(label: "com.rgv250cc.Fuse.ytdlp.meta.stderr")
                var stderrData = Data()
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        stderrSync.sync { stderrData.append(chunk) }
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                guard process.terminationStatus == 0 else {
                    let stderrText = stderrSync.sync { String(decoding: stderrData, as: UTF8.self) }
                    let tail = stderrText
                        .components(separatedBy: "\n")
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .suffix(20)
                        .joined(separator: "\n")
                    continuation.resume(throwing: RunnerError.processFailed(
                        status: process.terminationStatus, stderrTail: tail))
                    return
                }
                do {
                    continuation.resume(returning: try VideoMetadata.decode(from: stdoutData))
                } catch {
                    continuation.resume(throwing: RunnerError.metadataDecodingFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Download

    /// Cancellation handle for a running download.
    final class DownloadHandle {
        private let process: Process
        fileprivate init(process: Process) { self.process = process }
        /// SIGTERM — yt-dlp exits promptly and leaves .part files for later cleanup.
        func cancel() {
            if process.isRunning { process.terminate() }
        }
    }

    /// Thread-safe accumulator shared by the pipe readability handlers
    /// (background queues) and the termination handler (another thread).
    private final class StreamState {
        private let lock = NSLock()
        private var stdoutRemainder = ""
        private var stderrLines: [String] = []
        private var lastNonProgressLine: String?

        /// Appends raw stdout bytes; returns the complete lines now available.
        func appendStdout(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            stdoutRemainder += String(decoding: data, as: UTF8.self)
            var lines = stdoutRemainder.components(separatedBy: "\n")
            stdoutRemainder = lines.removeLast() // unterminated tail stays buffered
            return lines
        }

        /// Returns and clears any unterminated final line (call at termination).
        func flushStdoutTail() -> String? {
            lock.lock(); defer { lock.unlock() }
            let tail = stdoutRemainder.trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutRemainder = ""
            return tail.isEmpty ? nil : tail
        }

        /// The last non-progress stdout line is the `--print after_move:filepath` result.
        func recordCandidateFilePath(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lastNonProgressLine = line
        }

        var candidateFilePath: String? {
            lock.lock(); defer { lock.unlock() }
            return lastNonProgressLine
        }

        func appendStderr(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            let lines = String(decoding: data, as: UTF8.self)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            stderrLines.append(contentsOf: lines)
            if stderrLines.count > 20 {
                stderrLines.removeFirst(stderrLines.count - 20)
            }
        }

        var stderrTail: String {
            lock.lock(); defer { lock.unlock() }
            return stderrLines.joined(separator: "\n")
        }
    }

    /// Starts a download. Returns a handle for cancellation.
    /// `onProgress` and `completion` are invoked on the main actor;
    /// `completion` delivers the final file path or an error.
    @discardableResult
    func startDownload(url: String,
                       preset: String,
                       destinationPath: String,
                       onProgress: @escaping @MainActor (DownloadProgress) -> Void,
                       completion: @escaping @MainActor (Result<String, Error>) -> Void) throws -> DownloadHandle {
        guard ToolManager.shared.ytDlpInstalled else { throw RunnerError.ytDlpMissing }

        let ffmpegPath = ToolManager.shared.ffmpegPath()
        var arguments = FormatPresets.arguments(preset: preset, ffmpegAvailable: ffmpegPath != nil)
        arguments += FormatPresets.containerArguments(
            container: UserDefaults.standard.string(forKey: "downloader.container") ?? "mp4",
            preset: preset,
            ffmpegAvailable: ffmpegPath != nil)
        arguments += [
            "--no-playlist",
            "--newline",
            "--progress-template", Self.progressTemplate,
            "--print", "after_move:filepath", // final path, after any merge/move
            "--no-simulate",                  // --print alone implies simulation; cancel that
            "-P", destinationPath,
            "-o", "%(title)s [%(id)s].%(ext)s",
        ]
        if let ffmpegPath {
            arguments += ["--ffmpeg-location", (ffmpegPath as NSString).deletingLastPathComponent]
        }
        arguments.append(url)

        let process = Process()
        process.executableURL = ToolManager.shared.ytDlpURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = StreamState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { // EOF
                handle.readabilityHandler = nil
                return
            }
            for line in state.appendStdout(data) {
                if let progress = ProgressParser.parse(line: line) {
                    Task { @MainActor in onProgress(progress) }
                } else {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { state.recordCandidateFilePath(trimmed) }
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            state.appendStderr(data)
        }

        process.terminationHandler = { proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            // Drain anything buffered after the handlers detached.
            if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                for line in state.appendStdout(rest) where ProgressParser.parse(line: line) == nil {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { state.recordCandidateFilePath(trimmed) }
                }
            }
            if let tail = state.flushStdoutTail(), ProgressParser.parse(line: tail) == nil {
                state.recordCandidateFilePath(tail)
            }
            if let errRest = try? stderrPipe.fileHandleForReading.readToEnd(), !errRest.isEmpty {
                state.appendStderr(errRest)
            }

            let result: Result<String, Error>
            if proc.terminationReason == .uncaughtSignal {
                result = .failure(RunnerError.cancelled) // our own terminate() → SIGTERM
            } else if proc.terminationStatus == 0 {
                if let path = state.candidateFilePath {
                    result = .success(path)
                } else {
                    result = .failure(RunnerError.noOutputPath)
                }
            } else {
                result = .failure(RunnerError.processFailed(
                    status: proc.terminationStatus, stderrTail: state.stderrTail))
            }
            Task { @MainActor in completion(result) }
        }

        try process.run()
        Log.downloader.info("yt-dlp started for \(url, privacy: .public)")
        return DownloadHandle(process: process)
    }
}
