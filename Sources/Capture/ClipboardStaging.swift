import Foundation

/// App-managed home for capture files whose ONLY remaining owner is the
/// clipboard: "Delete & Copy" on a recording moves the clip here and puts
/// this file's URL on the pasteboard. The staged file lives exactly as long
/// as some clipboard-history item still references it — once that entry is
/// pruned, deleted, or cleared, the next sweep removes the file. (The OS
/// temp dir is unsuitable: macOS purges it on its own schedule, silently
/// killing the paste.)
enum ClipboardStaging {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fuse/Clipboard Staging", isDirectory: true)
    }

    /// Files newer than this never get swept — insurance against the gap
    /// between writing the pasteboard and the watcher recording the entry.
    static let sweepGrace: TimeInterval = 60

    /// Moves `url` into staging, returning its new URL. A UUID prefix keeps
    /// same-named captures from colliding.
    static func stage(_ url: URL) throws -> URL {
        let dest = try reserveURL(forFileName: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Reserves a unique destination inside staging for an export to write to.
    static func reserveURL(forFileName name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    /// Deletes every file in `directory` that is not in `referencedPaths`
    /// (standardized file paths) and is older than the grace interval.
    static func sweep(directory: URL = ClipboardStaging.directory,
                      referencedPaths: Set<String>,
                      now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files {
            guard !referencedPaths.contains(file.standardizedFileURL.path) else { continue }
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            guard now.timeIntervalSince(created) > sweepGrace else { continue }
            try? fm.removeItem(at: file)
            Log.capture.info("reclaimed staged clip: \(file.lastPathComponent, privacy: .public)")
        }
    }
}
