import XCTest
@testable import Fuse

final class SpeakerAlignerTests: XCTestCase {
    private func seg(_ i: Int, _ s: Double, _ e: Double) -> AlignSpeakerSegment {
        .init(speakerIndex: i, start: s, end: e, isFinalized: true)
    }

    func testDominantSpeakerByMaxTotalOverlap() {
        // Utterance 1.0–4.0: speaker 1 covers 3s of it, speaker 0 only 0.5s.
        let segs = [seg(0, 0, 1.5), seg(1, 1.0, 4.0)]
        XCTAssertEqual(SpeakerAttribution.dominantSpeaker(start: 1.0, end: 4.0, segments: segs), 1)
    }

    func testDominantSpeakerSumsMultipleSegments() {
        // Same speaker split across two segments should still win over a rival.
        let segs = [seg(2, 0, 1), seg(2, 2, 3), seg(0, 1, 2)]
        // Utterance 0–3: speaker 2 has 2s total, speaker 0 has 1s.
        XCTAssertEqual(SpeakerAttribution.dominantSpeaker(start: 0, end: 3, segments: segs), 2)
    }

    func testNoOverlapReturnsNil() {
        XCTAssertNil(SpeakerAttribution.dominantSpeaker(start: 10, end: 12, segments: [seg(0, 0, 1)]))
        XCTAssertNil(SpeakerAttribution.dominantSpeaker(start: 0, end: 1, segments: []))
    }

    func testSpeakerLabelIsOneBased() {
        let line = SpeakerLine(id: UUID(), speakerIndex: 0, text: "hi", start: 0, end: 1, isFinal: true)
        XCTAssertEqual(line.speakerLabel, "Speaker 1")
    }
}
