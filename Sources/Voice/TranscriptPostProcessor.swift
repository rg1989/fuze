import Foundation

/// Cleans raw Whisper output before pasting: strips [bracketed] and
/// (parenthesized) non-speech annotations, optionally removes standalone
/// vocal fillers (um, uh, erm, hmm…), collapses whitespace runs to single
/// spaces, trims the ends, and returns nil when nothing remains.
enum TranscriptPostProcessor {
    private static let annotationPattern = #"\[[^\]]*\]|\([^)]*\)"#

    /// Standalone vocal fillers, word-bounded and case-insensitive.
    /// Deliberately conservative — only pure vocalizations, never real words.
    /// Notably EXCLUDED: bare "er" (the ER), bare "ah"/"eh" (interjections),
    /// bare "mm" (millimeters).
    private static let fillerPattern = #"(?i)\b(?:u+h+m*|u+m+|e+r+m+|e+r+r+|a+h+h+|h+m+m*|mhm)\b"#

    static func clean(_ raw: String, removeFillers: Bool = false) -> String? {
        var text = raw.replacingOccurrences(
            of: annotationPattern, with: " ", options: .regularExpression)

        if removeFillers {
            text = text.replacingOccurrences(
                of: fillerPattern, with: " ", options: .regularExpression)
        }

        text = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)

        if removeFillers {
            // Tidy punctuation orphaned by removed fillers:
            // "report, , tomorrow" -> "report, tomorrow"; ", hello" -> "hello".
            text = text.replacingOccurrences(
                of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(
                of: #"([,;:])\s*[,;:]+"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(
                of: #"^[,.;:!?\s]+"#, with: "", options: .regularExpression)
        }

        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if removeFillers, let first = trimmed.first, first.isLowercase {
            // A removed leading filler ("Um, hello") leaves a lowercase start.
            trimmed = first.uppercased() + trimmed.dropFirst()
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
