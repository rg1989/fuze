import XCTest
import KeyboardShortcuts
@testable import Fuse

final class HotkeyNamesTests: XCTestCase {
    func testAllNamesHaveDefaultShortcuts() {
        let all: [KeyboardShortcuts.Name] = [
            .pushToTalk, .pastePicker, .openDownloads, .clearNotifications,
            .tileLeftHalf, .tileRightHalf, .tileTopHalf, .tileBottomHalf,
            .tileTopLeft, .tileTopRight, .tileBottomLeft, .tileBottomRight,
            .tileMaximize, .tileCenter, .tileNextDisplay,
            .toggleNotesPanel,
            .captureRegion, .toggleRecording,
        ]
        for name in all {
            XCTAssertNotNil(name.defaultShortcut, "\(name.rawValue) is missing a default shortcut")
        }
    }
}
