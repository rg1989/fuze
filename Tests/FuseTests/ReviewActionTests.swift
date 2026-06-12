import XCTest
@testable import Fuse

final class ReviewActionTests: XCTestCase {
    func testFourActionsExist() {
        XCTAssertEqual(ReviewAction.allCases.count, 4)
    }

    func testKeepsFile() {
        XCTAssertFalse(ReviewAction.delete.keepsFile)
        XCTAssertFalse(ReviewAction.deleteAndCopy.keepsFile)
        XCTAssertTrue(ReviewAction.save.keepsFile)
        XCTAssertTrue(ReviewAction.saveAndCopy.keepsFile)
    }

    func testCopiesToClipboard() {
        XCTAssertFalse(ReviewAction.delete.copiesToClipboard)
        XCTAssertTrue(ReviewAction.deleteAndCopy.copiesToClipboard)
        XCTAssertFalse(ReviewAction.save.copiesToClipboard)
        XCTAssertTrue(ReviewAction.saveAndCopy.copiesToClipboard)
    }

    func testTitles() {
        XCTAssertEqual(ReviewAction.delete.title, "Delete")
        XCTAssertEqual(ReviewAction.deleteAndCopy.title, "Delete & Copy")
        XCTAssertEqual(ReviewAction.save.title, "Save")
        XCTAssertEqual(ReviewAction.saveAndCopy.title, "Save & Copy")
    }
}
