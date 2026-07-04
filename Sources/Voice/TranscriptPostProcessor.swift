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

        text = restoreQuestions(text)

        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if removeFillers, let first = trimmed.first, first.isLowercase {
            // A removed leading filler ("Um, hello") leaves a lowercase start.
            trimmed = first.uppercased() + trimmed.dropFirst()
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    // Words that OPEN a question. A be-verb followed by a subject/determiner, or a
    // modal / do-auxiliary followed by a subject pronoun, is a question opening.
    // This excludes subject-less imperatives ("Have a nice day", "Do the dishes").
    private static let beVerbs: Set<String> =
        ["is", "are", "am", "was", "were", "isn't", "aren't", "wasn't", "weren't"]
    private static let beFollowers: Set<String> =
        ["the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her",
         "its", "our", "their", "there", "i", "you", "we", "they", "he", "she", "it"]
    private static let modals: Set<String> =
        ["do", "does", "did", "can", "could", "will", "would", "shall", "should", "may",
         "might", "must", "have", "has", "had", "don't", "doesn't", "didn't", "can't",
         "couldn't", "won't", "wouldn't", "shouldn't", "haven't", "hasn't", "hadn't"]
    private static let subjectPronouns: Set<String> =
        ["i", "you", "we", "they", "he", "she", "it", "there"]

    /// Whether a sentence clearly opens as a question.
    static func isQuestionOpening(_ sentence: String) -> Bool {
        let words = sentence.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        guard let first = words.first.map(String.init) else { return false }
        let second = words.count > 1 ? String(words[1]) : ""
        if beVerbs.contains(first) { return beFollowers.contains(second) }
        if modals.contains(first) { return subjectPronouns.contains(second) }
        return false
    }

    /// Best-effort question-mark restoration: ASR (Parakeet/Whisper) often ends a
    /// spoken question with a period or nothing. Upgrade a sentence that opens as
    /// a question to end with "?" — conservatively, so statements/imperatives are
    /// untouched. Preserves original spacing; only sentence terminators change.
    static func restoreQuestions(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = ""
        var sentence = ""
        func flush(_ terminator: Character?) {
            let isQ = isQuestionOpening(sentence.trimmingCharacters(in: .whitespaces))
            switch terminator {
            case ".": result += sentence + (isQ ? "?" : ".")
            case let t?: result += sentence + String(t)          // keep ! and existing ?
            case nil: result += sentence + (isQ && !sentence.trimmingCharacters(in: .whitespaces).isEmpty ? "?" : "")
            }
            sentence = ""
        }
        for ch in text {
            if ".!?".contains(ch) { flush(ch) } else { sentence.append(ch) }
        }
        flush(nil)
        return result
    }
}
