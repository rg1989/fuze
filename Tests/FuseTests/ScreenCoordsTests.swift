import XCTest
@testable import Fuse

final class ScreenCoordsTests: XCTestCase {
    /// cocoa → ax → cocoa must be the identity for ANY rect on ANY display.
    private func assertRoundTrip(_ rect: CGRect, primaryHeight: CGFloat,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let ax = ScreenCoords.axOrigin(ofCocoaRect: rect, primaryScreenHeight: primaryHeight)
        let back = ScreenCoords.cocoaRect(axOrigin: ax, size: rect.size,
                                          primaryScreenHeight: primaryHeight)
        XCTAssertEqual(back.origin.x, rect.origin.x, accuracy: 0.0001, "x", file: file, line: line)
        XCTAssertEqual(back.origin.y, rect.origin.y, accuracy: 0.0001, "y", file: file, line: line)
        XCTAssertEqual(back.width, rect.width, accuracy: 0.0001, "width", file: file, line: line)
        XCTAssertEqual(back.height, rect.height, accuracy: 0.0001, "height", file: file, line: line)
    }

    func testFullscreenPrimaryRectHasAXOriginZero() {
        // A rect covering the whole 1920×1080 primary: Cocoa origin (0,0)
        // bottom-left ⇒ AX origin (0,0) top-left.
        let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let ax = ScreenCoords.axOrigin(ofCocoaRect: rect, primaryScreenHeight: 1080)
        XCTAssertEqual(ax.x, 0, accuracy: 0.0001)
        XCTAssertEqual(ax.y, 0, accuracy: 0.0001)
    }

    func testKnownConversionOnPrimary() {
        // Cocoa (100, 200, 800, 600) on a 1080-high primary:
        // AX y = 1080 − rect.maxY = 1080 − 800 = 280.
        let rect = CGRect(x: 100, y: 200, width: 800, height: 600)
        let ax = ScreenCoords.axOrigin(ofCocoaRect: rect, primaryScreenHeight: 1080)
        XCTAssertEqual(ax.x, 100, accuracy: 0.0001)
        XCTAssertEqual(ax.y, 280, accuracy: 0.0001)
    }

    func testRoundTripOnPrimary() {
        assertRoundTrip(CGRect(x: 100, y: 200, width: 800, height: 600), primaryHeight: 1080)
        assertRoundTrip(CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080)
        assertRoundTrip(CGRect(x: 37.5, y: 12.25, width: 311, height: 247), primaryHeight: 1080)
    }

    func testRoundTripOnSecondaryDisplayAtNegativeX() {
        // Secondary display left of the primary: Cocoa x is negative.
        assertRoundTrip(CGRect(x: -1920, y: 200, width: 800, height: 600), primaryHeight: 1080)
    }

    func testRoundTripOnSecondaryDisplayAbovePrimary() {
        // Secondary display above the primary: Cocoa y exceeds primary height.
        assertRoundTrip(CGRect(x: -1920, y: 1200, width: 800, height: 600), primaryHeight: 1080)
    }

    func testAXOriginIsNegativeForRectAbovePrimaryTop() {
        // Cocoa maxY = 1200 + 600 = 1800 > 1080 ⇒ AX y = 1080 − 1800 = −720.
        // Windows above the primary's top edge have NEGATIVE AX y. Real.
        let rect = CGRect(x: -1920, y: 1200, width: 800, height: 600)
        let ax = ScreenCoords.axOrigin(ofCocoaRect: rect, primaryScreenHeight: 1080)
        XCTAssertEqual(ax.x, -1920, accuracy: 0.0001)
        XCTAssertEqual(ax.y, -720, accuracy: 0.0001)
    }
}
