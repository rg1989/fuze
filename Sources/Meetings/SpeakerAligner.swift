import Foundation

/// A minimal ASR token: text + [start,end] seconds. Built from FluidAudio's
/// TokenTiming at the call site so this file stays dependency-free & testable.
struct AlignToken: Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// A diarizer interval reduced to what alignment needs.
struct AlignSpeakerSegment: Equatable {
    let speakerIndex: Int
    let start: Double
    let end: Double
    let isFinalized: Bool
}

/// One speaker-attributed line of transcript. `speakerIndex` is 0-based (the
/// diarizer's slot); the display label is 1-based ("Speaker 1").
struct SpeakerLine: Identifiable, Equatable {
    let id: UUID
    var speakerIndex: Int
    var text: String
    var start: Double
    var end: Double
    var isFinal: Bool
    var speakerLabel: String { "Speaker \(speakerIndex + 1)" }
}

/// Pure, unit-testable ASR↔speaker attribution. No FluidAudio imports — works on
/// plain value types, which is what makes it testable without models.
enum SpeakerAligner {
    /// Max-overlap attribution. A word in a diarizer gap falls back to the
    /// segment whose midpoint is nearest the word's midpoint.
    static func speakerIndex(forWordStart start: Double, end: Double,
                             segments: [AlignSpeakerSegment]) -> (index: Int, isFinal: Bool)? {
        var best: AlignSpeakerSegment? = nil
        var bestOverlap = 0.0
        for s in segments {
            let ov = min(end, s.end) - max(start, s.start)
            if ov > bestOverlap { bestOverlap = ov; best = s }
        }
        if best == nil, !segments.isEmpty {
            let mid = (start + end) / 2
            best = segments.min {
                abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid)
            }
        }
        guard let best else { return nil }
        return (best.speakerIndex, best.isFinalized)
    }

    /// Group tokens → words (a leading-space token starts a new word), attribute
    /// each word to a speaker, and coalesce consecutive same-speaker words into
    /// lines. A finalized attribution freezes a line; a tentative one leaves it
    /// open so a later tick can extend it.
    static func lines(tokens: [AlignToken], segments: [AlignSpeakerSegment],
                      idFactory: () -> UUID = { UUID() }) -> [SpeakerLine] {
        struct Word { var text: String; var start: Double; var end: Double }
        var words: [Word] = []
        for tk in tokens {
            let newWord = tk.text.hasPrefix(" ") || words.isEmpty
            if newWord {
                words.append(Word(text: tk.text.trimmingCharacters(in: .whitespaces),
                                  start: tk.start, end: tk.end))
            } else {
                words[words.count - 1].text += tk.text
                words[words.count - 1].end = tk.end
            }
        }
        var lines: [SpeakerLine] = []
        for w in words where !w.text.isEmpty {
            guard let (idx, isFinal) = speakerIndex(forWordStart: w.start, end: w.end, segments: segments)
            else { continue }
            // Coalesce consecutive same-speaker words into one line. A whole pass
            // is recomputed each tick, so merge regardless of finality; the line
            // is "final" (solid) only when every word in it is finalized.
            if var last = lines.last, last.speakerIndex == idx {
                last.text += " " + w.text
                last.end = w.end
                last.isFinal = last.isFinal && isFinal
                lines[lines.count - 1] = last
            } else {
                lines.append(SpeakerLine(id: idFactory(), speakerIndex: idx,
                                         text: w.text, start: w.start, end: w.end, isFinal: isFinal))
            }
        }
        return lines
    }
}
