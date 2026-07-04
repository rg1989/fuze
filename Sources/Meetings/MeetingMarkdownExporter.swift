import Foundation

/// Pure, deterministic transcript rendering — mirrors `MarkdownExporter`.
/// Each message is prefixed with its [start–end] timecode. Always ends with
/// exactly one trailing newline.
enum MeetingMarkdownExporter {
    /// Seconds → "m:ss" (or "h:mm:ss" past an hour).
    static func timecode(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    static func transcript(title: String, segments: [MeetingSegment]) -> String {
        var lines: [String] = []
        if !title.isEmpty { lines.append("# \(title)") }
        for seg in segments {
            let span = "\(timecode(seg.startSeconds))–\(timecode(seg.endSeconds))"
            lines.append("[\(span)] \(seg.speakerId): \(seg.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
