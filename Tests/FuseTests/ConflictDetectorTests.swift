import XCTest
@testable import Fuse

final class ConflictDetectorTests: XCTestCase {
    func testKnownConflictDetectedAndDescribed() {
        let conflicts = ConflictDetector.conflicts(
            amongBundleIDs: ["com.knollsoft.Rectangle", "com.example.unrelated"])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].appName, "Rectangle")
        XCTAssertEqual(conflicts[0].fuseFeature, "Window tiling")
        XCTAssertFalse(conflicts[0].advice.isEmpty)
    }

    func testResultsSortedByBundleID() {
        let ids: Set<String> = ["org.p0deje.Maccy", "com.knollsoft.Rectangle", "com.pilotmoon.scroll-reverser"]
        let bundleIDs = ConflictDetector.conflicts(amongBundleIDs: ids).map(\.bundleID)
        XCTAssertEqual(bundleIDs, bundleIDs.sorted())
        XCTAssertEqual(bundleIDs.count, 3)
    }

    func testNoKnownAppsMeansNoConflicts() {
        XCTAssertTrue(ConflictDetector.conflicts(amongBundleIDs: ["com.apple.finder"]).isEmpty)
        XCTAssertTrue(ConflictDetector.conflicts(amongBundleIDs: []).isEmpty)
    }
}
