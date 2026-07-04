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
    /// each word to a speaker, and coalesce consecutive words into messages. A new
    /// message starts on a speaker change OR an utterance boundary (a real silence
    /// pause detected from the audio, in `boundaries`) — so each pause-separated
    /// utterance is its own timestamped bubble. Words with no covering diarizer
    /// segment default to Speaker 1, so text shows live and for solo speakers
    /// before diarization catches up.
    static func lines(tokens: [AlignToken], segments: [AlignSpeakerSegment],
                      boundaries: [Double] = [],
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
        let bounds = boundaries.sorted()
        // Utterance index = how many pause boundaries precede this word's start.
        func utterance(at start: Double) -> Int {
            var n = 0
            for b in bounds { if b <= start { n += 1 } else { break } }
            return n
        }
        var lines: [SpeakerLine] = []
        var lastUtterance = -1
        for w in words where !w.text.isEmpty {
            let attribution = speakerIndex(forWordStart: w.start, end: w.end, segments: segments)
            let idx = attribution?.index ?? 0
            let isFinal = attribution?.isFinal ?? false
            let utt = utterance(at: w.start)
            // Extend the current message only for the same speaker AND same
            // utterance; otherwise start a new one. Recomputed each tick, so merge
            // regardless of finality; a message is solid only when all words are.
            if var last = lines.last, last.speakerIndex == idx, utt == lastUtterance {
                last.text += " " + w.text
                last.end = w.end
                last.isFinal = last.isFinal && isFinal
                lines[lines.count - 1] = last
            } else {
                lines.append(SpeakerLine(id: idFactory(), speakerIndex: idx,
                                         text: w.text, start: w.start, end: w.end, isFinal: isFinal))
                lastUtterance = utt
            }
        }
        return lines
    }
}
