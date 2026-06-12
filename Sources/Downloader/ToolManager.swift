import Darwin
import Foundation

/// Locates and manages the external command-line tools the downloader drives.
///
/// Fuse keeps its OWN copy of yt-dlp at ~/Library/Application Support/Fuse/bin/yt-dlp
/// so it can self-update the binary without re-signing the app bundle.
/// ffmpeg (needed to merge bestvideo+bestaudio and to extract MP3 audio)
/// is resolved from the standard Homebrew locations if installed.
final class ToolManager {
    static let shared = ToolManager()

    enum ToolError: LocalizedError {
        case badDownloadResponse(Int)

        var errorDescription: String? {
            switch self {
            case .badDownloadResponse(let code):
                return "yt-dlp download failed (HTTP \(code)). Check your network connection and try again."
            }
        }
    }

    /// Standalone universal2 macOS build published with every yt-dlp release.
    static let ytDlpReleaseURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// Lightweight metadata endpoint for the latest stable release tag.
    static let ytDlpLatestReleaseAPI = URL(
        string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    /// At most one auto-update check per day: yt-dlp ships site fixes almost
    /// daily, so an installed binary that never refreshes slowly loses sites.
    static let autoUpdateInterval: TimeInterval = 24 * 60 * 60

    /// ~/Library/Application Support/Fuse/bin/yt-dlp (master plan §6.5).
    var ytDlpURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Fuse/bin/yt-dlp")
    }

    var ytDlpInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ytDlpURL.path)
    }

    /// First existing executable among the standard Homebrew install paths
    /// (Apple Silicon first, then Intel/Rosetta prefix).
    func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Downloads the latest yt-dlp_macos to `ytDlpURL` via URLSession,
    /// then chmod 755 and strips the quarantine attribute.
    func installOrUpdateYtDlp() async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: Self.ytDlpReleaseURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ToolError.badDownloadResponse(http.statusCode)
        }

        let fm = FileManager.default
        let binDir = ytDlpURL.deletingLastPathComponent()
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: ytDlpURL.path) {
            try fm.removeItem(at: ytDlpURL)
        }
        try fm.moveItem(at: tempURL, to: ytDlpURL)

        // CRITICAL: URLSession-downloaded files carry the com.apple.quarantine
        // extended attribute; Gatekeeper blocks executing a quarantined binary
        // via Process. Make it executable, then remove the quarantine xattr.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ytDlpURL.path)
        if removexattr(ytDlpURL.path, "com.apple.quarantine", 0) != 0 && errno != ENOATTR {
            Log.downloader.warning("removexattr failed: errno \(errno)")
        }
        Log.downloader.info("yt-dlp installed at \(self.ytDlpURL.path, privacy: .public)")
    }

    /// Runs `yt-dlp --version` and returns the trimmed output (e.g. "2026.05.13"),
    /// or nil if the binary is missing or fails to launch.
    func installedVersion() async -> String? {
        guard ytDlpInstalled else { return nil }
        let ytDlp = ytDlpURL
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = ytDlp
                process.arguments = ["--version"]
                let stdoutPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let version = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: version.isEmpty ? nil : version)
            }
        }
    }

    /// Latest stable release tag (e.g. "2026.06.09") from GitHub, or nil if
    /// the network/API is unavailable. Best-effort — never throws.
    func latestReleaseVersion() async -> String? {
        var request = URLRequest(url: Self.ytDlpLatestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether enough time has elapsed since the last check to run another.
    /// Pure for testability (see ToolManagerTests).
    static func shouldCheckForUpdate(now: Date, lastCheck: Date?,
                                     minInterval: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= minInterval
    }

    /// Best-effort background refresh: if yt-dlp is ALREADY installed and a
    /// newer stable build exists, download it. Deliberately never installs
    /// from scratch — the first-use consent flow (Settings → Downloads) owns
    /// that decision. Safe to call on every launch; the caller throttles via
    /// `shouldCheckForUpdate`.
    func autoUpdateIfNeeded() async {
        guard ytDlpInstalled else { return }
        guard let latest = await latestReleaseVersion() else {
            Log.downloader.info("yt-dlp update check skipped (offline?)")
            return
        }
        let current = await installedVersion()
        guard latest != current else {
            Log.downloader.info("yt-dlp up to date (\(latest, privacy: .public))")
            return
        }
        do {
            try await installOrUpdateYtDlp()
            Log.downloader.info("yt-dlp auto-updated \(current ?? "?", privacy: .public) → \(latest, privacy: .public)")
        } catch {
            Log.downloader.warning("yt-dlp auto-update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
