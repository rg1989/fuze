import XCTest
@testable import Fuse

final class PermissionsTests: XCTestCase {
    func testChecksReturnWithoutCrashing() {
        _ = PermissionsService.hasAccessibility
        _ = PermissionsService.hasInputMonitoring
    }

    func testSettingsPaneURLsAreWellFormed() {
        for pane in SettingsPane.allCases {
            XCTAssertNotNil(URL(string: pane.urlString), "bad URL for \(pane)")
        }
    }
}
