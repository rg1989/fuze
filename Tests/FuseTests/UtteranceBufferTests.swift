import XCTest
@testable import Fuse

final class UtteranceBufferTests: XCTestCase {
    private let loud = [Float](repeating: 0.5, count: 1600)   // 0.1s "speech"
    private let quiet = [Float](repeating: 0.0, count: 1600)  // 0.1s silence

    // onUtterance fires on the buffer's serial queue; flush() is q.sync, so after
    // it returns every queued feed + the final close have run and are visible.
    private func collect(_ build: (UtteranceBuffer) -> Void) -> [(count: Int, start: Double, end: Double)] {
        let buf = UtteranceBuffer(pauseSeconds: 0.5, maxSeconds: 100)
        var utts: [(count: Int, start: Double, end: Double)] = []
        buf.onUtterance = { s, start, end in utts.append((s.count, start, end)) }
        build(buf)
        buf.flush()
        return utts
    }

    func testSplitsOnPause() {
        let utts = collect { buf in
            buf.feed(loud); buf.feed(loud)          // 0.2s speech
            for _ in 0..<6 { buf.feed(quiet) }      // 0.6s silence > 0.5 → closes utterance 1
            buf.feed(loud); buf.feed(loud)          // 0.2s speech → utterance 2 (closed by flush)
        }
        XCTAssertEqual(utts.count, 2)
        XCTAssertEqual(utts[0].start, 0.0, accuracy: 0.001)   // first utterance starts at t=0
        XCTAssertGreaterThan(utts[1].start, utts[0].end - 0.0001)  // second starts after the first
    }

    func testSilenceOnlyProducesNoUtterance() {
        let utts = collect { buf in for _ in 0..<10 { buf.feed(quiet) } }
        XCTAssertTrue(utts.isEmpty)
    }

    func testContinuousSpeechIsCappedByMaxDuration() {
        let buf = UtteranceBuffer(pauseSeconds: 5, maxSeconds: 0.3)   // 0.3s = 4800 samples cap
        var count = 0
        buf.onUtterance = { _, _, _ in count += 1 }
        for _ in 0..<9 { buf.feed(loud) }   // 0.9s continuous speech → ~3 capped utterances
        buf.flush()
        XCTAssertGreaterThanOrEqual(count, 2)
    }
}
