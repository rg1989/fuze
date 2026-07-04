import XCTest
@testable import Fuse

final class TextStructurerTests: XCTestCase {
    private func line(_ t: String, y: Double, h: Double = 0.03, x: Double = 0.1) -> RecognizedLine {
        .init(text: t, rect: CGRect(x: x, y: y, width: 0.3, height: h))
    }

    func testEmptyYieldsEmpty() {
        XCTAssertEqual(TextStructurer.markdown(from: []), "")
    }

    func testHeadingAndParagraphBlocks() {
        let lines = [
            line("Title", y: 0.05, h: 0.06),                  // ~2x line height → heading
            line("First paragraph line one", y: 0.15),
            line("line two", y: 0.18),                        // close → same block, next line
            line("Second paragraph", y: 0.30),               // big gap → new block
        ]
        XCTAssertEqual(TextStructurer.markdown(from: lines),
                       "# Title\n\nFirst paragraph line one\nline two\n\nSecond paragraph\n")
    }

    func testBulletsNormalizedToDash() {
        let lines = [line("- item one", y: 0.10), line("• item two", y: 0.14)]
        XCTAssertEqual(TextStructurer.markdown(from: lines), "- item one\n- item two\n")
    }

    func testOrderedListKeptAsIs() {
        let lines = [line("1. first", y: 0.10), line("2) second", y: 0.14)]
        XCTAssertEqual(TextStructurer.markdown(from: lines), "1. first\n2) second\n")
    }

    func testSameRowFragmentsJoinLeftToRight() {
        let lines = [line("Right", y: 0.10, x: 0.5), line("Left", y: 0.10, x: 0.1)]
        XCTAssertEqual(TextStructurer.markdown(from: lines), "Left Right\n")
    }
}
