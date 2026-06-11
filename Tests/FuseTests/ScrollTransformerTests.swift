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
