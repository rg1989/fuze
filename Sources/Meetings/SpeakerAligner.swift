import Foundation

/// One speaker-attributed message. `speakerIndex` is 0-based (the diarizer's
/// slot); the display label is 1-based ("Speaker 1").
struct SpeakerLine: Identifiable, Equatable {
    let id: UUID
    var speakerIndex: Int
    var text: String
    var start: Double
    var end: Double
    var isFinal: Bool
    var speakerLabel: String { "Speaker \(speakerIndex + 1)" }
}

/// A diarizer interval reduced to what attribution needs.
struct AlignSpeakerSegment: Equatable {
    let speakerIndex: Int
    let start: Double
    let end: Double
    let isFinalized: Bool
}

/// A minimal ASR token: text + [start,end] seconds (absolute audio-clock time).
struct AlignToken: Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// Attributes a whole utterance to a speaker from the diarizer's segments.
enum SpeakerAttribution {
    /// The speaker whose diarizer segments overlap [start,end] the MOST in total
    /// (an utterance can span several segments of the same speaker). Returns nil
    /// when no segment overlaps — the caller defaults to Speaker 1.
    static func dominantSpeaker(start: Double, end: Double,
                                segments: [AlignSpeakerSegment]) -> Int? {
        var overlapBySpeaker: [Int: Double] = [:]
        for s in segments {
            let ov = min(end, s.end) - max(start, s.start)
            if ov > 0 { overlapBySpeaker[s.speakerIndex, default: 0] += ov }
        }
        // Ties broken by lowest speaker index for determinism.
        return overlapBySpeaker.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key
    }

    /// Split one utterance's tokens into speaker-attributed messages: group tokens
    /// into words (leading-space token starts a new word), attribute each word to
    /// its max-overlap diarizer speaker, and coalesce consecutive same-speaker
    /// words into a line. A speaker change starts a NEW message — so a single
    /// pause-delimited utterance spanning two speakers becomes two bubbles. Words
    /// with no covering segment default to Speaker 1.
    static func split(tokens: [AlignToken], segments: [AlignSpeakerSegment],
                      idFactory: () -> UUID = { UUID() }) -> [SpeakerLine] {
        struct Word { var text: String; var start: Double; var end: Double }
        var words: [Word] = []
        for tk in tokens {
            if tk.text.hasPrefix(" ") || words.isEmpty {
                words.append(Word(text: tk.text.trimmingCharacters(in: .whitespaces),
                                  start: tk.start, end: tk.end))
            } else {
                words[words.count - 1].text += tk.text
                words[words.count - 1].end = tk.end
            }
        }
        var lines: [SpeakerLine] = []
        for w in words where !w.text.isEmpty {
            let idx = dominantSpeaker(start: w.start, end: w.end, segments: segments) ?? 0
            if var last = lines.last, last.speakerIndex == idx {
                last.text += " " + w.text
                last.end = w.end
                lines[lines.count - 1] = last
            } else {
                lines.append(SpeakerLine(id: idFactory(), speakerIndex: idx,
                                         text: w.text, start: w.start, end: w.end, isFinal: true))
            }
        }
        return lines
    }
}
