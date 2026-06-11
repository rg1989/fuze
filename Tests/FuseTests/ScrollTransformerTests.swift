import XCTest
@testable import Fuse

// Tests for the scroll feature's pure logic: ScrollSettings (this task)
// and ScrollTransformer (Task 2.2 appends its test class below).

final class ScrollSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "FuseTests.ScrollSettings"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsWhenNoKeysWereEverWritten() {
        let s = ScrollSettings.current(defaults: defaults)
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.reverseTrackpad)
        XCTAssertTrue(s.reverseMouse)
        XCTAssertFalse(s.reverseHorizontal)
    }

    func testReadsExplicitlySetFalseValues() {
        defaults.set(false, forKey: "scroll.enabled")
        defaults.set(false, forKey: "scroll.reverseTrackpad")
        defaults.set(false, forKey: "scroll.reverseMouse")
        let s = ScrollSettings.current(defaults: defaults)
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(s.reverseTrackpad)
        XCTAssertFalse(s.reverseMouse)
        XCTAssertFalse(s.reverseHorizontal)
    }

    func testReadsExplicitlySetTrueHorizontal() {
        defaults.set(true, forKey: "scroll.reverseHorizontal")
        let s = ScrollSettings.current(defaults: defaults)
        XCTAssertTrue(s.reverseHorizontal)
    }

    func testRegisterDefaultsSeedsAllFourKeys() {
        ScrollSettings.registerDefaults(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "scroll.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "scroll.reverseTrackpad"))
        XCTAssertTrue(defaults.bool(forKey: "scroll.reverseMouse"))
        XCTAssertFalse(defaults.bool(forKey: "scroll.reverseHorizontal"))
    }
}

final class ScrollTransformerTests: XCTestCase {
    /// Asymmetric values so a wrong-axis negation can never pass by accident.
    private let sample = ScrollDeltas(
        deltaAxis1: 3, deltaAxis2: -2,
        pointDeltaAxis1: 30, pointDeltaAxis2: -20,
        fixedPtDeltaAxis1: 196_608, fixedPtDeltaAxis2: -131_072)

    private func settings(enabled: Bool = true,
                          trackpad: Bool = true,
                          mouse: Bool = true,
                          horizontal: Bool = false) -> ScrollSettings {
        ScrollSettings(enabled: enabled, reverseTrackpad: trackpad,
                       reverseMouse: mouse, reverseHorizontal: horizontal)
    }

    func testTrackpadVerticalReversedHorizontalUntouched() {
        let out = ScrollTransformer.transform(sample, source: .continuous, settings: settings())
        XCTAssertEqual(out, ScrollDeltas(
            deltaAxis1: -3, deltaAxis2: -2,
            pointDeltaAxis1: -30, pointDeltaAxis2: -20,
            fixedPtDeltaAxis1: -196_608, fixedPtDeltaAxis2: -131_072))
    }

    func testMouseWheelVerticalReversed() {
        let out = ScrollTransformer.transform(sample, source: .lineBased, settings: settings())
        XCTAssertEqual(out, ScrollDeltas(
            deltaAxis1: -3, deltaAxis2: -2,
            pointDeltaAxis1: -30, pointDeltaAxis2: -20,
            fixedPtDeltaAxis1: -196_608, fixedPtDeltaAxis2: -131_072))
    }

    func testMousePassesThroughWhenMouseFlagOff() {
        let out = ScrollTransformer.transform(sample, source: .lineBased, settings: settings(mouse: false))
        XCTAssertNil(out)
    }

    func testTrackpadPassesThroughWhenTrackpadFlagOff() {
        let out = ScrollTransformer.transform(sample, source: .continuous, settings: settings(trackpad: false))
        XCTAssertNil(out)
    }

    func testHorizontalAlsoReversedWhenBothFlagsOn() {
        let out = ScrollTransformer.transform(sample, source: .continuous, settings: settings(horizontal: true))
        XCTAssertEqual(out, ScrollDeltas(
            deltaAxis1: -3, deltaAxis2: 2,
            pointDeltaAxis1: -30, pointDeltaAxis2: 20,
            fixedPtDeltaAxis1: -196_608, fixedPtDeltaAxis2: 131_072))
    }

    func testHorizontalFlagAloneDoesNotReverse() {
        let out = ScrollTransformer.transform(
            sample, source: .continuous,
            settings: settings(trackpad: false, horizontal: true))
        XCTAssertNil(out)
    }

    func testDisabledReturnsNilEvenWithAllFlagsOn() {
        let out = ScrollTransformer.transform(
            sample, source: .continuous,
            settings: settings(enabled: false, horizontal: true))
        XCTAssertNil(out)
    }

    func testZeroDeltasStayZero() {
        let zero = ScrollDeltas(deltaAxis1: 0, deltaAxis2: 0,
                                pointDeltaAxis1: 0, pointDeltaAxis2: 0,
                                fixedPtDeltaAxis1: 0, fixedPtDeltaAxis2: 0)
        let out = ScrollTransformer.transform(zero, source: .continuous, settings: settings(horizontal: true))
        XCTAssertEqual(out, zero)
    }
}
