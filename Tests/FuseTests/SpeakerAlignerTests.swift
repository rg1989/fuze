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

    // MARK: split (speaker-turn splitting within one utterance)

    private func tok(_ t: String, _ s: Double, _ e: Double) -> AlignToken { .init(text: t, start: s, end: e) }
    private func counter() -> () -> UUID {
        var n = 0
        return { defer { n += 1 }; return UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")! }
    }

    func testSplitBreaksIntoOneBubblePerSpeaker() {
        // "hello there" by speaker 0, then "hi back" by speaker 1 — no pause between.
        let tokens = [tok("hello", 0, 0.5), tok(" there", 0.5, 1.0),
                      tok(" hi", 1.2, 1.5), tok(" back", 1.5, 2.0)]
        let segs = [seg(0, 0, 1.1), seg(1, 1.1, 2.5)]
        let lines = SpeakerAttribution.split(tokens: tokens, segments: segs, idFactory: counter())
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].speakerIndex, 0); XCTAssertEqual(lines[0].text, "hello there")
        XCTAssertEqual(lines[1].speakerIndex, 1); XCTAssertEqual(lines[1].text, "hi back")
    }

    func testSplitSingleSpeakerIsOneBubble() {
        let tokens = [tok("one", 0, 0.3), tok(" two", 0.3, 0.6), tok(" three", 0.6, 0.9)]
        let lines = SpeakerAttribution.split(tokens: tokens, segments: [seg(0, 0, 2)], idFactory: counter())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "one two three")
    }

    func testSplitNoSegmentsDefaultsToSpeaker1() {
        let lines = SpeakerAttribution.split(tokens: [tok("hi", 0, 1)], segments: [], idFactory: counter())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].speakerLabel, "Speaker 1")
    }

    func testSplitEmptyTokensYieldNoLines() {
        XCTAssertTrue(SpeakerAttribution.split(tokens: [], segments: [seg(0, 0, 1)]).isEmpty)
    }
}
