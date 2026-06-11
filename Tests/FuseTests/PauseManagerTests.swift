import XCTest
import KeyboardShortcuts
@testable import Fuse

final class PauseManagerTests: XCTestCase {
    override func tearDown() {
        PauseManager.shared.setPaused(false)   // never leak paused state into other tests
        super.tearDown()
    }

    func testPauseFlipsStateDisablesShortcutsAndPosts() {
        let manager = PauseManager.shared
        manager.setPaused(false)
        let note = expectation(forNotification: PauseManager.pauseStateChanged, object: manager)

        manager.setPaused(true)

        XCTAssertTrue(manager.isPaused)
        XCTAssertFalse(KeyboardShortcuts.isEnabled)
        wait(for: [note], timeout: 1)

        manager.setPaused(false)
        XCTAssertFalse(manager.isPaused)
        XCTAssertTrue(KeyboardShortcuts.isEnabled)
    }

    func testRedundantSetPostsNothing() {
        let manager = PauseManager.shared
        manager.setPaused(false)
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: PauseManager.pauseStateChanged, object: manager, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.setPaused(false)   // already false — must be a no-op

        XCTAssertEqual(posts, 0)
    }
}
