import XCTest
@testable import Fuse

final class PauseSegmenterTests: XCTestCase {
    private let loud = [Float](repeating: 0.5, count: 1600)   // 0.1s of "speech"
    private let quiet = [Float](repeating: 0.0, count: 1600)  // 0.1s of silence

    func testBoundaryRecordedWhenSpeechResumesAfterPause() {
        let seg = PauseSegmenter(pauseSeconds: 0.5)   // 0.5s = 8000 samples
        seg.process(loud)                              // speak (no boundary at very start)
        for _ in 0..<6 { seg.process(quiet) }          // 0.6s silence (> 0.5s)
        seg.process(loud)                              // speech resumes → one boundary
        let b = seg.boundaries()
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b.first ?? -1, 0.7, accuracy: 0.001)   // 1600 + 6*1600 samples / 16000
    }

    func testNoBoundaryForContinuousSpeech() {
        let seg = PauseSegmenter(pauseSeconds: 0.5)
        for _ in 0..<10 { seg.process(loud) }
        XCTAssertTrue(seg.boundaries().isEmpty)
    }

    func testNoBoundaryForShortPause() {
        let seg = PauseSegmenter(pauseSeconds: 0.5)
        seg.process(loud)
        for _ in 0..<3 { seg.process(quiet) }          // 0.3s < 0.5s — not a pause
        seg.process(loud)
        XCTAssertTrue(seg.boundaries().isEmpty)
    }

    func testMultiplePausesRecordMultipleBoundaries() {
        let seg = PauseSegmenter(pauseSeconds: 0.5)
        seg.process(loud)
        for _ in 0..<6 { seg.process(quiet) }; seg.process(loud)   // boundary 1
        for _ in 0..<6 { seg.process(quiet) }; seg.process(loud)   // boundary 2
        XCTAssertEqual(seg.boundaries().count, 2)
    }
}
