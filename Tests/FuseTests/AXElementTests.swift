import XCTest
@testable import Fuse

final class AXElementTests: XCTestCase {
    func testSystemWideElementConstructs() {
        let element = AXElement.systemWide()
        // Without Accessibility permission these return nil/[] — they must never crash.
        _ = element.role
        _ = element.children
        _ = element.actionNames()
    }
}
