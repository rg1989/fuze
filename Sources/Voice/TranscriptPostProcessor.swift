import Foundation

/// Cleans raw Whisper output before pasting: strips [bracketed] and
/// (parenthesized) non-speech annotations, collapses whitespace runs to single
/// spaces, trims the ends, and returns nil when nothing remains.
enum TranscriptPostProcessor {
    private static let annotationPattern = #"\[[^\]]*\]|\([^)]*\)"#

    static func clean(_ raw: String) -> String? {
        let withoutAnnotations = raw.replacingOccurrences(
            of: annotationPattern,
            with: " ",
            options: .regularExpression)
        let collapsed = withoutAnnotations.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
