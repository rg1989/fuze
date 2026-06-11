import XCTest
@testable import Fuse

final class ModifierHoldTests: XCTestCase {
    private let rightCmd: UInt = 0x0010
    private let rightOpt: UInt = 0x0040
    private let leftShift: UInt = 0x0002

    func testDownFiresWhenComboFullyHeld() {
        var detector = ModifierHoldDetector(combo: ModifierCombo(rawMask: rightCmd | rightOpt))
        XCTAssertNil(detector.process(rawFlags: rightCmd))               // partial — nothing
        XCTAssertEqual(detector.process(rawFlags: rightCmd | rightOpt), .down)
        XCTAssertTrue(detector.isHeld)
    }

    func testExtraModifiersBeyondComboStillSatisfy() {
        var detector = ModifierHoldDetector(combo: ModifierCombo(rawMask: rightCmd))
        XCTAssertEqual(detector.process(rawFlags: rightCmd | leftShift), .down)
    }

    func testUpFiresWhenAnyComboKeyReleased() {
        var detector = ModifierHoldDetector(combo: ModifierCombo(rawMask: rightCmd | rightOpt))
        XCTAssertEqual(detector.process(rawFlags: rightCmd | rightOpt), .down)
        XCTAssertEqual(detector.process(rawFlags: rightOpt), .up)        // cmd released
        XCTAssertFalse(detector.isHeld)
    }

    func testNoRepeatEdgesWhileHeldOrReleased() {
        var detector = ModifierHoldDetector(combo: ModifierCombo(rawMask: rightCmd))
        XCTAssertEqual(detector.process(rawFlags: rightCmd), .down)
        XCTAssertNil(detector.process(rawFlags: rightCmd))               // still held
        XCTAssertEqual(detector.process(rawFlags: 0), .up)
        XCTAssertNil(detector.process(rawFlags: 0))                      // still released
    }

    func testOffComboNeverFires() {
        var detector = ModifierHoldDetector(combo: .off)
        XCTAssertNil(detector.process(rawFlags: rightCmd | rightOpt))
        XCTAssertNil(detector.process(rawFlags: 0))
    }

    func testDisplayStringNamesSideSpecificKeys() {
        XCTAssertEqual(ModifierCombo(rawMask: rightCmd | rightOpt).displayString, "Right ⌥ + Right ⌘")
        XCTAssertEqual(ModifierCombo.off.displayString, "Off")
    }

    func testPressedExtractsOnlyInterestBits() {
        // 0x0100 (device-independent ⌘ summary bit area) is outside our mask.
        XCTAssertEqual(ModifierCombo.pressed(inFlags: rightCmd | 0x0010_0000), rightCmd)
    }
}

final class FillerRemovalTests: XCTestCase {
    func testRemovesFillersAndTidiesPunctuation() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("Um, send the report, uh, tomorrow.", removeFillers: true),
            "Send the report, tomorrow.")
    }

    func testRemovesElongatedFillers() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("Hmmm so the answer is, uhhh, forty-two", removeFillers: true),
            "So the answer is, forty-two")
    }

    func testKeepsRealWordsContainingFillerLetters() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("summer hummus measures 5 mm", removeFillers: true),
            "Summer hummus measures 5 mm")
    }

    func testToggleOffLeavesFillersAlone() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("Um, hello there", removeFillers: false),
            "Um, hello there")
    }

    func testAllFillerInputBecomesNil() {
        XCTAssertNil(TranscriptPostProcessor.clean("Umm... uh, hmm.", removeFillers: true))
    }

    func testCombinesWithAnnotationStripping() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("[BLANK_AUDIO] um, testing one two", removeFillers: true),
            "Testing one two")
    }
}
