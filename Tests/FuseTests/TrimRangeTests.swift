import CoreMedia
import XCTest
@testable import Fuse

final class TrimRangeTests: XCTestCase {
    func testFullRange() {
        let r = TrimMath.trimRange(start: 0, end: 1, duration: 10)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.start.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(r!.end.seconds, 10, accuracy: 0.001)
    }

    func testInteriorRange() {
        let r = TrimMath.trimRange(start: 0.25, end: 0.75, duration: 8)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.start.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(r!.end.seconds, 6, accuracy: 0.001)
        XCTAssertEqual(r!.duration.seconds, 4, accuracy: 0.001)
    }

    func testEndEqualToStartIsNil() {
        XCTAssertNil(TrimMath.trimRange(start: 0.5, end: 0.5, duration: 10))
    }

    func testEndBeforeStartIsNil() {
        XCTAssertNil(TrimMath.trimRange(start: 0.8, end: 0.2, duration: 10))
    }

    func testNonPositiveDurationIsNil() {
        XCTAssertNil(TrimMath.trimRange(start: 0, end: 1, duration: 0))
        XCTAssertNil(TrimMath.trimRange(start: 0, end: 1, duration: -3))
    }

    func testOutOfBoundsFractionsAreClamped() {
        let r = TrimMath.trimRange(start: -0.5, end: 1.5, duration: 4)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.start.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(r!.end.seconds, 4, accuracy: 0.001)
    }
}
