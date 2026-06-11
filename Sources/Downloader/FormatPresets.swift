import Foundation

/// Maps the "downloader.qualityPreset" settings value to yt-dlp arguments
/// (the -f format selector plus any post-processing extras).
///
/// With ffmpeg: merged selectors (separate bestvideo + bestaudio streams,
/// merged locally — required for 4K on most sites) and MP3 extraction.
/// Without ffmpeg: degrade to single-file formats ("b") that need no merging,
/// and "audio" downloads the native best-audio file without converting to MP3.
enum FormatPresets {
    static func arguments(preset: String, ffmpegAvailable: Bool) -> [String] {
        switch preset {
        case "1080p":
            return ffmpegAvailable
                ? ["-f", "bv*[height<=1080]+ba/b[height<=1080]"]
                : ["-f", "b"]
        case "720p":
            return ffmpegAvailable
                ? ["-f", "bv*[height<=720]+ba/b[height<=720]"]
                : ["-f", "b"]
        case "audio":
            return ffmpegAvailable
                ? ["-f", "ba/b", "-x", "--audio-format", "mp3"]
                : ["-f", "ba/b"]
        default: // "best" and any unknown/corrupt settings value
            return ffmpegAvailable ? ["-f", "bv*+ba/b"] : ["-f", "b"]
        }
    }
}
