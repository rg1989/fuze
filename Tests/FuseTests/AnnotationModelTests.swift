import XCTest
@testable import Fuse

final class AnnotationModelTests: XCTestCase {
    func testArrowHeadHorizontalArrow() {
        // Shaft (0,0)→(10,0), barbs of length 2 at ±30° off the shaft,
        // pointing back from the tip: x = 10 − 2·cos(30°), y = ±2·sin(30°).
        let (left, right) = AnnotationGeometry.arrowHeadPoints(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0), length: 2)
        let expectedX = 10 - 2 * cos(CGFloat.pi / 6)   // ≈ 8.268
        XCTAssertEqual(left.x, expectedX, accuracy: 0.001)
        XCTAssertEqual(right.x, expectedX, accuracy: 0.001)
        XCTAssertEqual(abs(left.y), 1.0, accuracy: 0.001)    // 2·sin(30°) = 1
        XCTAssertEqual(abs(right.y), 1.0, accuracy: 0.001)
        XCTAssertEqual(left.y, -right.y, accuracy: 0.001)    // symmetric barbs
    }

    func testArrowHeadVerticalArrow() {
        let (left, right) = AnnotationGeometry.arrowHeadPoints(
            from: CGPoint(x: 5, y: 20), to: CGPoint(x: 5, y: 0), length: 3)
        // Arrow points "up" in top-left space (decreasing y); barbs sit below
        // the tip, symmetric around x = 5.
        let expectedY = 3 * cos(CGFloat.pi / 6)   // ≈ 2.598
        XCTAssertEqual(left.y, expectedY, accuracy: 0.001)
        XCTAssertEqual(right.y, expectedY, accuracy: 0.001)
        XCTAssertEqual(left.x + right.x, 10, accuracy: 0.001)
        XCTAssertEqual(abs(left.x - 5), 1.5, accuracy: 0.001)   // 3·sin(30°)
    }

    func testArrowHeadDegenerateZeroLengthShaft() {
        // from == to: atan2(0,0) == 0 — must not crash; barbs land left of tip.
        let (left, right) = AnnotationGeometry.arrowHeadPoints(
            from: CGPoint(x: 4, y: 4), to: CGPoint(x: 4, y: 4), length: 2)
        XCTAssertLessThan(left.x, 4)
        XCTAssertLessThan(right.x, 4)
    }

    func testAnnotationDefaults() {
        let a = Annotation(tool: .arrow)
        XCTAssertEqual(a.points, [])
        XCTAssertEqual(a.rect, .zero)
        XCTAssertEqual(a.text, "")
        XCTAssertEqual(a.color, .red)
        XCTAssertEqual(a.lineWidth, 4)
    }

    func testAllToolsBuildAPathWithoutCrashing() {
        for tool in AnnotationTool.allCases {
            var a = Annotation(tool: tool)
            a.points = [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 9)]
            a.rect = CGRect(x: 1, y: 1, width: 8, height: 8)
            a.text = "x"
            _ = AnnotationPaths.path(for: a)   // text yields an empty path
        }
    }
}
