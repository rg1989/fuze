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

    // Single press = the "& Copy" variant; a quick double press drops the copy.
    func testKeyMapSinglePress() {
        XCTAssertEqual(ReviewKeyMap.action(for: .return, isDouble: false), .saveAndCopy)
        XCTAssertEqual(ReviewKeyMap.action(for: .escape, isDouble: false), .deleteAndCopy)
    }

    func testKeyMapDoublePress() {
        XCTAssertEqual(ReviewKeyMap.action(for: .return, isDouble: true), .save)
        XCTAssertEqual(ReviewKeyMap.action(for: .escape, isDouble: true), .delete)
    }
}
