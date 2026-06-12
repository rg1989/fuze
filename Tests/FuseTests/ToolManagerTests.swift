import XCTest
@testable import Fuse

final class ToolManagerTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstCheckEverIsAlwaysDue() {
        XCTAssertTrue(ToolManager.shouldCheckForUpdate(
            now: now, lastCheck: nil, minInterval: day))
    }

    func testNotDueBeforeIntervalElapses() {
        let oneHourAgo = now.addingTimeInterval(-3600)
        XCTAssertFalse(ToolManager.shouldCheckForUpdate(
            now: now, lastCheck: oneHourAgo, minInterval: day))
    }

    func testDueOnceIntervalHasElapsed() {
        let exactlyOneDayAgo = now.addingTimeInterval(-day)
        XCTAssertTrue(ToolManager.shouldCheckForUpdate(
            now: now, lastCheck: exactlyOneDayAgo, minInterval: day))

        let wellPast = now.addingTimeInterval(-day * 3)
        XCTAssertTrue(ToolManager.shouldCheckForUpdate(
            now: now, lastCheck: wellPast, minInterval: day))
    }
}
