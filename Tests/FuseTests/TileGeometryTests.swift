import XCTest
@testable import Fuse

final class TileGeometryTests: XCTestCase {
    private let vf = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let anySize = CGSize(width: 400, height: 300)

    private func frame(_ action: TileAction,
                       gap: CGFloat = 0,
                       size: CGSize? = nil,
                       in visibleFrame: CGRect? = nil) -> CGRect {
        TileGeometry.frame(for: action,
                           visibleFrame: visibleFrame ?? vf,
                           currentWindowSize: size ?? anySize,
                           gap: gap)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.0001, "origin.x", file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.0001, "origin.y", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001, "height", file: file, line: line)
    }

    // MARK: - Gap 0 (visibleFrame 0,0,1600,1000)

    func testLeftHalfGap0() {
        assertRect(frame(.leftHalf), CGRect(x: 0, y: 0, width: 800, height: 1000))
    }

    func testRightHalfGap0() {
        assertRect(frame(.rightHalf), CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    func testTopHalfGap0() {
        // Cocoa coordinates: the TOP half has the LARGER y origin.
        assertRect(frame(.topHalf), CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    func testBottomHalfGap0() {
        assertRect(frame(.bottomHalf), CGRect(x: 0, y: 0, width: 1600, height: 500))
    }

    func testTopLeftGap0() {
        assertRect(frame(.topLeft), CGRect(x: 0, y: 500, width: 800, height: 500))
    }

    func testTopRightGap0() {
        assertRect(frame(.topRight), CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testBottomLeftGap0() {
        assertRect(frame(.bottomLeft), CGRect(x: 0, y: 0, width: 800, height: 500))
    }

    func testBottomRightGap0() {
        assertRect(frame(.bottomRight), CGRect(x: 800, y: 0, width: 800, height: 500))
    }

    func testMaximizeGap0() {
        assertRect(frame(.maximize), CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    func testCenterKeepsSizeGap0() {
        // 400×300 window centered in 1600×1000 → origin ((1600-400)/2, (1000-300)/2).
        assertRect(frame(.center, size: CGSize(width: 400, height: 300)),
                   CGRect(x: 600, y: 350, width: 400, height: 300))
    }

    func testCenterClampsOversizedWindowGap0() {
        // 2000×1200 window cannot fit; it is clamped to the visible frame.
        assertRect(frame(.center, size: CGSize(width: 2000, height: 1200)),
                   CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    // MARK: - Gap 10 (visibleFrame 0,0,1600,1000)
    // Half tiles: width/height = side/2 − 1.5·gap. Outer edges inset by gap;
    // the seam between two adjacent tiles is exactly gap points wide.

    func testLeftHalfGap10() {
        assertRect(frame(.leftHalf, gap: 10), CGRect(x: 10, y: 10, width: 785, height: 980))
    }

    func testRightHalfGap10() {
        // Right tile starts at midline + gap/2: 800 + 5 = 805.
        assertRect(frame(.rightHalf, gap: 10), CGRect(x: 805, y: 10, width: 785, height: 980))
    }

    func testTopHalfGap10() {
        // Top tile starts at vertical midline + gap/2: 500 + 5 = 505.
        assertRect(frame(.topHalf, gap: 10), CGRect(x: 10, y: 505, width: 1580, height: 485))
    }

    func testBottomHalfGap10() {
        assertRect(frame(.bottomHalf, gap: 10), CGRect(x: 10, y: 10, width: 1580, height: 485))
    }

    func testTopLeftGap10() {
        assertRect(frame(.topLeft, gap: 10), CGRect(x: 10, y: 505, width: 785, height: 485))
    }

    func testTopRightGap10() {
        assertRect(frame(.topRight, gap: 10), CGRect(x: 805, y: 505, width: 785, height: 485))
    }

    func testBottomLeftGap10() {
        assertRect(frame(.bottomLeft, gap: 10), CGRect(x: 10, y: 10, width: 785, height: 485))
    }

    func testBottomRightGap10() {
        assertRect(frame(.bottomRight, gap: 10), CGRect(x: 805, y: 10, width: 785, height: 485))
    }

    func testMaximizeGap10() {
        assertRect(frame(.maximize, gap: 10), CGRect(x: 10, y: 10, width: 1580, height: 980))
    }

    func testHorizontalSeamIsExactlyGapWide() {
        let left = frame(.leftHalf, gap: 10)
        let right = frame(.rightHalf, gap: 10)
        XCTAssertEqual(right.minX - left.maxX, 10, accuracy: 0.0001)
    }

    func testCenterKeepsSizeGap10() {
        // A window that fits is centered identically regardless of gap.
        assertRect(frame(.center, gap: 10, size: CGSize(width: 400, height: 300)),
                   CGRect(x: 600, y: 350, width: 400, height: 300))
    }

    func testCenterClampsOversizedWindowGap10() {
        // Clamped to the gap-inset frame (1580×980), then centered → origin (10, 10).
        assertRect(frame(.center, gap: 10, size: CGSize(width: 2000, height: 1200)),
                   CGRect(x: 10, y: 10, width: 1580, height: 980))
    }

    // MARK: - nextDisplay geometry == center geometry
    // WindowMover handles screen selection for .nextDisplay; geometrically it is
    // "center on the given visibleFrame, keeping (clamped) size" — same as .center.

    func testNextDisplayGeometryMatchesCenter() {
        let size = CGSize(width: 640, height: 480)
        assertRect(frame(.nextDisplay, gap: 10, size: size),
                   frame(.center, gap: 10, size: size))
    }

    // MARK: - Non-zero-origin visibleFrame (secondary display / Dock offset)

    func testOffsetOriginVisibleFrame() {
        let offset = CGRect(x: 100, y: 50, width: 1600, height: 1000)
        assertRect(frame(.leftHalf, in: offset),
                   CGRect(x: 100, y: 50, width: 800, height: 1000))
        assertRect(frame(.topRight, in: offset),
                   CGRect(x: 900, y: 550, width: 800, height: 500))
    }
}
