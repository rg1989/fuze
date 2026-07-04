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

    // MARK: Question-mark restoration

    func testBeVerbQuestionPeriodBecomesQuestionMark() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("Is the project running updated."),
            "Is the project running updated?")
    }

    func testTrailingQuestionWithNoPunctuationGetsQuestionMark() {
        XCTAssertEqual(
            TranscriptPostProcessor.restoreQuestions("Are you sure about this"),
            "Are you sure about this?")
    }

    func testModalQuestionBecomesQuestionMark() {
        XCTAssertEqual(
            TranscriptPostProcessor.restoreQuestions("Do you want coffee."),
            "Do you want coffee?")
    }

    func testImperativeIsNotAQuestion() {
        // Subject-less "Have"/"Do" openings are imperatives, left alone.
        XCTAssertEqual(TranscriptPostProcessor.restoreQuestions("Have a nice day."), "Have a nice day.")
        XCTAssertEqual(TranscriptPostProcessor.restoreQuestions("Do the dishes."), "Do the dishes.")
    }

    func testStatementIsNotAQuestion() {
        XCTAssertEqual(TranscriptPostProcessor.restoreQuestions("This is fine."), "This is fine.")
        XCTAssertEqual(TranscriptPostProcessor.restoreQuestions("It was great."), "It was great.")
    }

    func testOnlyTheQuestionSentenceIsChanged() {
        XCTAssertEqual(
            TranscriptPostProcessor.restoreQuestions("Can we go. Let's leave now."),
            "Can we go? Let's leave now.")
    }

    func testExistingQuestionMarkPreserved() {
        XCTAssertEqual(TranscriptPostProcessor.restoreQuestions("Are you ok?"), "Are you ok?")
    }
}
