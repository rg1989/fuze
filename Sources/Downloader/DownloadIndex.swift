import Foundation

/// Maps yt-dlp video ids to the last known on-disk path (title-only filenames).
enum DownloadIndex {
    private static let fileName = "download-index.json"

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fuse", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Returns the basename of an existing download for this video, if the file is still on disk.
    static func existingFilename(forVideoId videoId: String, in directory: String) -> String? {
        if let path = load()[videoId], FileManager.default.fileExists(atPath: path) {
            return (path as NSString).lastPathComponent
        }
        // Legacy downloads used `Title [videoId].ext`.
        let tag = "[\(videoId)]"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return names.first { $0.contains(tag) }
    }

    static func record(videoId: String, path: String) {
        var index = load()
        index[videoId] = path
        save(index)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save(_ index: [String: String]) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
