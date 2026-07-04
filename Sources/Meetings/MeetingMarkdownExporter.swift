import Foundation

/// Pure, deterministic transcript rendering — mirrors `MarkdownExporter`.
/// Always ends with exactly one trailing newline.
enum MeetingMarkdownExporter {
    static func transcript(title: String, segments: [MeetingSegment]) -> String {
        var lines: [String] = []
        if !title.isEmpty { lines.append("# \(title)") }
        for seg in segments { lines.append("[\(seg.speakerId)] \(seg.text)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
