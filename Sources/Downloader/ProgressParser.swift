import Foundation

/// One parsed yt-dlp progress update.
struct DownloadProgress: Equatable {
    var percent: Double
    var speed: String
    var eta: String
}

/// Parses progress lines produced by running yt-dlp with `--newline` and
/// `--progress-template "download:FUSEP|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"`.
/// Example stdout line: `FUSEP|  42.7%|  3.21MiB/s|00:35`
enum ProgressParser {
    /// Returns nil for non-progress lines (yt-dlp also prints destination
    /// paths, merge notices, and the final `--print` file path on stdout).
    static func parse(line: String) -> DownloadProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("FUSEP|") else { return nil }

        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }

        let percentField = parts[1].trimmingCharacters(in: .whitespaces)
        guard percentField.hasSuffix("%"),
              let percent = Double(percentField.dropLast()) else { return nil }

        // yt-dlp emits "N/A" (and occasionally "Unknown") before it can
        // estimate speed/ETA — map those to empty strings so the UI shows nothing.
        func clean(_ field: String) -> String {
            let value = field.trimmingCharacters(in: .whitespaces)
            if value == "N/A" || value.hasPrefix("Unknown") { return "" }
            return value
        }

        return DownloadProgress(percent: percent, speed: clean(parts[2]), eta: clean(parts[3]))
    }
}
