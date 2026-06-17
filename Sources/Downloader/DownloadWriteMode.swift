import Foundation

/// How yt-dlp should behave when the destination filename already exists.
enum DownloadWriteMode {
    /// Fail if the target path exists (`--no-overwrites`). Used for fresh downloads.
    case noOverwrite
    /// Replace the existing file (`--force-overwrites`).
    case replace
    /// Let yt-dlp pick the next free name, e.g. `Title (1).ext`.
    case autoRename

    var ytDlpArguments: [String] {
        switch self {
        case .noOverwrite: return ["--no-overwrites"]
        case .replace: return ["--force-overwrites"]
        case .autoRename: return []
        }
    }
}
