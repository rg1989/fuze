import Foundation

/// Turns yt-dlp's stderr "step" chatter into a short, friendly status line so
/// the Downloads UI can show what's happening during the otherwise-opaque
/// metadata and pre-download phases (which can take 10–20s on some sites).
/// Pure and unit-tested. Returns nil for lines that aren't a meaningful step
/// (progress frames, debug spam, warnings, errors, blanks).
enum YtDlpStatus {
    static func currentStep(line: String) -> String? {
        let raw = line.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.hasPrefix("FUSEP|") else { return nil }
        let lower = raw.lowercased()
        guard !lower.hasPrefix("[debug]"),
              !lower.hasPrefix("warning:"),
              !lower.hasPrefix("error:") else { return nil }

        // Friendly labels for the common, recognizable steps.
        if lower.contains("merging formats") || lower.contains("[merger]") {
            return "Merging audio + video…"
        }
        if lower.contains("[extractaudio]") || lower.contains("extracting audio") {
            return "Extracting audio…"
        }
        if lower.contains("downloading webpage") {
            return "Reading page…"
        }
        if lower.contains("downloading m3u8") || lower.contains("downloading mpd")
            || lower.contains("format information") {
            return "Reading stream info…"
        }
        if lower.contains("downloading")
            && (lower.contains("api") || lower.contains("player") || lower.contains("json")) {
            return "Reading video data…"
        }
        if lower.contains("extracting url") {
            return "Resolving link…"
        }
        if lower.contains("format(s):")
            || (lower.contains("downloading") && lower.contains("format")) {
            return "Preparing download…"
        }
        if lower.contains("destination:") {
            return "Starting download…"
        }

        // Generic fallback: strip the "[extractor] id:" prefix and keep the
        // message only if it begins with an activity verb.
        let msg = strippedPrefix(raw)
        let verbs: Set<String> = ["downloading", "extracting", "merging", "checking",
                                  "resolving", "searching", "converting", "fixing", "deleting"]
        if let first = msg.split(separator: " ").first.map({ $0.lowercased() }),
           verbs.contains(first) {
            return msg.hasSuffix("…") ? msg : msg + "…"
        }
        return nil
    }

    /// Drops a leading "[extractor]" tag and any following "id:" token.
    static func strippedPrefix(_ line: String) -> String {
        var s = line
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        // Drop a leading "<token>:" where the token has no spaces (a video id).
        if let colon = s.firstIndex(of: ":") {
            let head = s[s.startIndex..<colon]
            if !head.contains(" ") {
                s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}
