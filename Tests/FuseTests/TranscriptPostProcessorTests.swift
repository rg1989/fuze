import XCTest
@testable import Fuse

final class TranscriptPostProcessorTests: XCTestCase {
    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(TranscriptPostProcessor.clean("  hello world \n"), "hello world")
    }

    func testCollapsesInternalNewlinesAndRunsToSingleSpaces() {
        XCTAssertEqual(TranscriptPostProcessor.clean("hello\nworld  again\t!"), "hello world again !")
    }

    func testBlankAudioArtifactAloneBecomesNil() {
        XCTAssertNil(TranscriptPostProcessor.clean("[BLANK_AUDIO]"))
    }

    func testParenthesizedAnnotationAloneBecomesNil() {
        XCTAssertNil(TranscriptPostProcessor.clean("(upbeat music)"))
    }

    func testArtifactInsideSpeechIsStripped() {
        XCTAssertEqual(TranscriptPostProcessor.clean("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testEmptyStringBecomesNil() {
        XCTAssertNil(TranscriptPostProcessor.clean(""))
    }

    func testPlainSentencePassesThroughUnchanged() {
        XCTAssertEqual(TranscriptPostProcessor.clean("Testing one two three."), "Testing one two three.")
    }

    func testMultipleArtifactsAreAllStripped() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("[MUSIC] hello [BLANK_AUDIO] world (applause)"),
            "hello world")
    }
}
