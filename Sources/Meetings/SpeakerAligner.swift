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
}
