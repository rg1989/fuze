import XCTest
@testable import Fuse

final class SpeakerAlignerTests: XCTestCase {
    private func tok(_ t: String, _ s: Double, _ e: Double) -> AlignToken { .init(text: t, start: s, end: e) }
    private func seg(_ i: Int, _ s: Double, _ e: Double, _ f: Bool = true) -> AlignSpeakerSegment {
        .init(speakerIndex: i, start: s, end: e, isFinalized: f)
    }
    /// Stable, predictable ids so line identity is assertable.
    private func counter() -> () -> UUID {
        var n = 0
        return { defer { n += 1 }; return UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")! }
    }

    func testWordsSplitOnLeadingSpaceAndAttributeByMaxOverlap() {
        // "hello world" by speaker 0, then "bye" by speaker 1.
        let tokens = [tok("hello", 0.0, 0.4), tok(" world", 0.4, 0.8), tok(" bye", 2.0, 2.3)]
        let segs = [seg(0, 0.0, 1.0), seg(1, 1.9, 2.5)]
        let lines = SpeakerAligner.lines(tokens: tokens, segments: segs, idFactory: counter())
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].speakerIndex, 0)
        XCTAssertEqual(lines[0].text, "hello world")     // coalesced same-speaker run
        XCTAssertEqual(lines[0].speakerLabel, "Speaker 1")  // 0-based → 1-based display
        XCTAssertEqual(lines[1].speakerIndex, 1)
        XCTAssertEqual(lines[1].text, "bye")
    }

    func testWordInDiarizerGapFallsBackToNearestMidpoint() {
        let tokens = [tok("stray", 5.0, 5.3)]              // no overlapping segment
        let segs = [seg(0, 0.0, 1.0), seg(1, 4.0, 4.5)]    // nearest by midpoint = seg 1
        let lines = SpeakerAligner.lines(tokens: tokens, segments: segs, idFactory: counter())
        XCTAssertEqual(lines.first?.speakerIndex, 1)
    }

    func testTentativeSegmentMarksLineNonFinal() {
        let lines = SpeakerAligner.lines(
            tokens: [tok("hi", 0.0, 0.3)],
            segments: [seg(0, 0.0, 1.0, false)], idFactory: counter())
        XCTAssertEqual(lines.first?.isFinal, false)
    }

    func testSpeakerChangeBreaksLineEvenIfPreviousFinal() {
        // Two finalized segments, different speakers → two lines.
        let tokens = [tok("a", 0.0, 0.3), tok(" b", 1.1, 1.4)]
        let segs = [seg(0, 0.0, 1.0, true), seg(1, 1.0, 2.0, true)]
        let lines = SpeakerAligner.lines(tokens: tokens, segments: segs, idFactory: counter())
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].speakerIndex, 0)
        XCTAssertEqual(lines[1].speakerIndex, 1)
    }

    func testNoTokensYieldNoLines() {
        XCTAssertTrue(SpeakerAligner.lines(tokens: [], segments: []).isEmpty)
        XCTAssertTrue(SpeakerAligner.lines(tokens: [], segments: [seg(0, 0, 1)]).isEmpty)
    }

    func testDefaultsToSpeaker1WhenNoDiarizationYet() {
        // No diarizer segments (solo speaker / startup) → text still appears,
        // attributed to Speaker 1 and marked tentative.
        let lines = SpeakerAligner.lines(
            tokens: [tok("hello", 0, 0.5), tok(" world", 0.5, 1.0)],
            segments: [], idFactory: counter())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(lines[0].text, "hello world")
        XCTAssertEqual(lines[0].isFinal, false)
    }

    func testAudioBoundaryStartsNewMessageForSameSpeaker() {
        // Same speaker; an audio-silence boundary at 2.5s splits into two messages.
        let tokens = [tok("first", 0, 0.5), tok(" part", 0.5, 1.0),
                      tok(" second", 3.0, 3.5)]
        let lines = SpeakerAligner.lines(tokens: tokens, segments: [seg(0, 0, 5)],
                                         boundaries: [2.5], idFactory: counter())
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "first part")
        XCTAssertEqual(lines[1].text, "second")
        XCTAssertEqual(lines[1].start, 3.0)              // new message carries its own start time
    }

    func testNoBoundaryKeepsSameMessage() {
        // Same speaker, no audio boundary → one message even across a token gap.
        let tokens = [tok("a", 0, 0.3), tok(" b", 3.0, 3.3)]
        let lines = SpeakerAligner.lines(tokens: tokens, segments: [seg(0, 0, 4)],
                                         boundaries: [], idFactory: counter())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "a b")
    }
}
