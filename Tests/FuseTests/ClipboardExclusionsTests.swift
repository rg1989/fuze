import XCTest
@testable import Fuse

final class ClipboardExclusionsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "FuseTests.exclusions")!
        defaults.removePersistentDomain(forName: "FuseTests.exclusions")
    }

    func testEmptyByDefault() {
        XCTAssertTrue(ClipboardExclusions.current(defaults: defaults).isEmpty)
    }

    func testAddRemoveRoundtrip() {
        ClipboardExclusions.add("com.apple.Terminal", defaults: defaults)
        ClipboardExclusions.add("com.googlecode.iterm2", defaults: defaults)
        XCTAssertEqual(ClipboardExclusions.current(defaults: defaults),
                       ["com.apple.Terminal", "com.googlecode.iterm2"])
        ClipboardExclusions.remove("com.apple.Terminal", defaults: defaults)
        XCTAssertEqual(ClipboardExclusions.current(defaults: defaults), ["com.googlecode.iterm2"])
    }

    func testIsExcluded() {
        let set: Set<String> = ["com.apple.Terminal"]
        XCTAssertTrue(ClipboardExclusions.isExcluded("com.apple.Terminal", in: set))
        XCTAssertFalse(ClipboardExclusions.isExcluded("com.apple.Safari", in: set))
        XCTAssertFalse(ClipboardExclusions.isExcluded(nil, in: set))
    }
}
