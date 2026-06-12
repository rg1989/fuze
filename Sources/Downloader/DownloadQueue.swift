import Foundation

enum DownloadState: Equatable {
    case queued
    case fetchingMetadata
    case downloading
    case paused
    case finished
    case failed
    case cancelled
}

struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    var url: String
    var state: DownloadState
    var metadata: VideoMetadata?
    var progress: DownloadProgress?
    var resultPath: String?
    var errorMessage: String?
    /// Current step text shown before numeric progress is available
    /// ("Reading page…", "Merging audio + video…", etc.).
    var statusDetail: String? = nil
}

/// Observable download queue. Settings (destination, preset, concurrency)
/// are read live from UserDefaults using the master-plan §6.4 keys so changes
/// in the settings tab apply to the next job without restart.
@MainActor
final class DownloadQueue: ObservableObject {
    @Published var items: [DownloadItem] = []

    private let runner = YtDlpRunner()
    private var handles: [UUID: YtDlpRunner.DownloadHandle] = [:]

    var maxConcurrent: Int {
        let value = UserDefaults.standard.integer(forKey: "downloader.maxConcurrent")
        return value > 0 ? value : 2
    }

    var destinationPath: String {
        UserDefaults.standard.string(forKey: "downloader.destinationPath")
            ?? NSHomeDirectory() + "/Downloads"
    }

    var qualityPreset: String {
        UserDefaults.standard.string(forKey: "downloader.qualityPreset") ?? "best"
    }

    /// Pure scheduling helper: indices of queued items allowed to start now.
    /// Active = fetchingMetadata or downloading. nonisolated so unit tests
    /// can call it synchronously without MainActor hops.
    nonisolated static func nextStartable(items: [DownloadItem], maxConcurrent: Int) -> [Int] {
        let active = items.filter { $0.state == .downloading || $0.state == .fetchingMetadata }.count
        let slots = max(0, maxConcurrent - active)
        guard slots > 0 else { return [] }
        var result: [Int] = []
        for (index, item) in items.enumerated() where item.state == .queued {
            result.append(index)
            if result.count == slots { break }
        }
        return result
    }

    /// Validates and enqueues a URL, then pumps the queue.
    /// Returns false (and enqueues nothing) when the string is not an http(s) URL.
    @discardableResult
    func add(url rawURL: String) -> Bool {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host != nil else {
            Log.downloader.info("rejected non-http(s) input")
            return false
        }
        items.append(DownloadItem(id: UUID(), url: trimmed, state: .queued,
                                  metadata: nil, progress: nil,
                                  resultPath: nil, errorMessage: nil))
        pump()
        return true
    }

    func cancel(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .queued:
            items[index].state = .cancelled
        case .fetchingMetadata:
            // No process handle yet; beginDownload's state guard aborts the job.
            items[index].state = .cancelled
        case .downloading:
            items[index].state = .cancelled
            handles[id]?.cancel()
            handles[id] = nil
        case .paused:
            // No running process; the .part file is left for cleanup.
            items[index].state = .cancelled
        case .finished, .failed, .cancelled:
            return
        }
        pump()
    }

    /// Pause an in-flight download: stop the process but keep its `.part` file
    /// (and last progress) so `resume` can continue in place via yt-dlp
    /// --continue. A freed slot lets the next queued item start.
    func pause(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .downloading else { return }
        items[index].state = .paused
        items[index].statusDetail = nil
        handles[id]?.cancel()   // SIGTERM — yt-dlp keeps the .part file
        handles[id] = nil
        pump()
    }

    /// Resume a paused download. Re-queues it (respecting maxConcurrent);
    /// `start` skips the metadata fetch since we already have it, and
    /// yt-dlp --continue picks up the partial file.
    func resume(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .paused else { return }
        items[index].state = .queued
        pump()
    }

    /// Remove all completed downloads from the list (files stay on disk).
    func clearFinished() {
        items.removeAll { $0.state == .finished }
        pump()
    }

    /// Remove all failed and cancelled downloads from the list.
    func clearFailed() {
        let removable: Set<DownloadState> = [.failed, .cancelled]
        for item in items where removable.contains(item.state) { handles[item.id] = nil }
        items.removeAll { removable.contains($0.state) }
        pump()
    }

    var hasFinished: Bool { items.contains { $0.state == .finished } }
    var hasFailed: Bool { items.contains { $0.state == .failed || $0.state == .cancelled } }

    func retry(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .failed || items[index].state == .cancelled else { return }
        items[index].state = .queued
        items[index].progress = nil
        items[index].resultPath = nil
        items[index].errorMessage = nil
        items[index].statusDetail = nil
        pump()
    }

    func remove(id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }),
           items[index].state == .downloading || items[index].state == .fetchingMetadata {
            cancel(id: id)
        }
        items.removeAll { $0.id == id }
        handles[id] = nil
        pump()
    }

    /// Starts queued jobs while the active count is below maxConcurrent.
    func pump() {
        for index in Self.nextStartable(items: items, maxConcurrent: maxConcurrent) {
            start(itemAt: index)
        }
    }

    private func start(itemAt index: Int) {
        let id = items[index].id
        // Resume/retry already have metadata — skip the slow `-J` fetch and let
        // yt-dlp --continue pick up any .part file.
        if let metadata = items[index].metadata {
            beginDownload(id: id, metadata: metadata)
            return
        }
        let url = items[index].url
        items[index].state = .fetchingMetadata
        items[index].statusDetail = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let metadata = try await self.runner.fetchMetadata(url: url) { [weak self] step in
                    self?.updateStatus(id: id, step: step)
                }
                self.beginDownload(id: id, metadata: metadata)
            } catch {
                self.markFailed(id: id, error: error)
            }
        }
    }

    private func beginDownload(id: UUID, metadata: VideoMetadata) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .fetchingMetadata
                || items[index].state == .queued else { return } // cancelled/removed meanwhile
        items[index].metadata = metadata
        items[index].state = .downloading
        do {
            let handle = try runner.startDownload(
                url: items[index].url,
                preset: qualityPreset,
                destinationPath: destinationPath,
                onProgress: { [weak self] progress in
                    self?.updateProgress(id: id, progress: progress)
                },
                onStatus: { [weak self] step in
                    self?.updateStatus(id: id, step: step)
                },
                completion: { [weak self] result in
                    self?.finish(id: id, result: result)
                })
            handles[id] = handle
        } catch {
            markFailed(id: id, error: error)
        }
    }

    private func updateProgress(id: UUID, progress: DownloadProgress) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .downloading else { return }
        items[index].progress = progress
        items[index].statusDetail = nil   // numeric progress supersedes step text
    }

    /// Surface yt-dlp's current step while there's no numeric progress yet.
    private func updateStatus(id: UUID, step: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .fetchingMetadata
                || items[index].state == .downloading,
              items[index].progress == nil else { return }
        items[index].statusDetail = step
    }

    private func finish(id: UUID, result: Result<String, Error>) {
        handles[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            pump()
            return
        }
        if items[index].state == .cancelled || items[index].state == .paused {
            // User cancelled or paused; ignore the late process exit so the
            // .part file and last progress are preserved for resume.
            pump()
            return
        }
        switch result {
        case .success(let path):
            items[index].state = .finished
            items[index].resultPath = path
            items[index].progress = DownloadProgress(percent: 100, speed: "", eta: "")
            Log.downloader.info("finished: \(path, privacy: .public)")
        case .failure(let error):
            if let runnerError = error as? YtDlpRunner.RunnerError, case .cancelled = runnerError {
                items[index].state = .cancelled
            } else {
                items[index].state = .failed
                items[index].errorMessage = error.localizedDescription   // friendly
                Log.downloader.error("failed: \(Self.rawDetail(error), privacy: .public)")
            }
        }
        pump()
    }

    /// Raw, unmapped error text for logging (the UI shows the friendly
    /// `localizedDescription`; Console keeps yt-dlp's full stderr tail).
    private static func rawDetail(_ error: Error) -> String {
        (error as? YtDlpRunner.RunnerError)?.diagnosticDetail ?? error.localizedDescription
    }

    private func markFailed(id: UUID, error: Error) {
        Log.downloader.error("failed: \(Self.rawDetail(error), privacy: .public)")
        markFailed(id: id, message: error.localizedDescription)   // friendly in UI
    }

    private func markFailed(id: UUID, message: String) {
        if let index = items.firstIndex(where: { $0.id == id }),
           items[index].state != .cancelled {
            items[index].state = .failed
            items[index].errorMessage = message
        }
        pump()
    }
}
