import XCTest
@testable import Fuse

final class SanityTests: XCTestCase {
    func testHostedTestRunLaunchesApp() {
        XCTAssertNotNil(NSApplication.shared)
    }
}
