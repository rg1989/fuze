import XCTest
@testable import Fuse

final class SnapZoneTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    func testLeftEdgeMiddleIsLeftHalf() {
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 5, y: 500), in: screen), .leftHalf)
    }

    func testLeftEdgeTopQuarterIsTopLeft() {
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 5, y: 900), in: screen), .topLeft)
    }

    func testLeftEdgeBottomQuarterIsBottomLeft() {
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 5, y: 100), in: screen), .bottomLeft)
    }

    func testRightEdgeMirrors() {
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 1595, y: 500), in: screen), .rightHalf)
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 1595, y: 950), in: screen), .topRight)
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 1595, y: 20), in: screen), .bottomRight)
    }

    func testTopEdgeCenterIsMaximize() {
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 800, y: 995), in: screen), .maximize)
    }

    func testTopEdgeOuterQuartersAreTopCorners() {
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 200, y: 995), in: screen), .topLeft)
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 1400, y: 995), in: screen), .topRight)
    }

    func testExactCornerPrefersQuarter() {
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 0, y: 1000), in: screen), .topLeft)
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 1600, y: 0), in: screen), .bottomRight)
    }

    func testBottomEdgeIsDead() {
        XCTAssertNil(SnapZone.action(for: CGPoint(x: 800, y: 5), in: screen))
    }

    func testScreenInteriorIsDead() {
        XCTAssertNil(SnapZone.action(for: CGPoint(x: 800, y: 500), in: screen))
    }

    func testNonZeroOriginScreen() {
        // Secondary display to the right of a 1600-wide primary.
        let secondary = CGRect(x: 1600, y: 200, width: 1200, height: 800)
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 1605, y: 600), in: secondary), .leftHalf)
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 2795, y: 950), in: secondary), .topRight)
        XCTAssertEqual(SnapZone.action(for: CGPoint(x: 2200, y: 995), in: secondary), .maximize)
        XCTAssertNil(SnapZone.action(for: CGPoint(x: 2200, y: 205), in: secondary))
    }
}
