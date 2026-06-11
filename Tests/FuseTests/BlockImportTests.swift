import XCTest
@testable import Fuse

final class BlockImportTests: XCTestCase {
    func testPNGTypeYieldsImage() {
        XCTAssertEqual(BlockImport.plannedBlock(types: ["public.png"], plainString: nil), .image)
    }

    func testTIFFTypeYieldsImage() {
        XCTAssertEqual(BlockImport.plannedBlock(types: ["public.tiff"], plainString: nil), .image)
    }

    func testHTTPSURLStringYieldsLink() {
        XCTAssertEqual(BlockImport.plannedBlock(types: ["public.utf8-plain-text"],
                                                plainString: "https://example.com/x"), .link)
    }

    func testNonURLStringYieldsText() {
        XCTAssertEqual(BlockImport.plannedBlock(types: ["public.utf8-plain-text"],
                                                plainString: "not a url"), .text)
    }

    func testURLWithSurroundingWordsYieldsText() {
        // Internal whitespace disqualifies the link interpretation.
        XCTAssertEqual(BlockImport.plannedBlock(types: ["public.utf8-plain-text"],
                                                plainString: "https://example.com and more words"), .text)
    }

    func testNonHTTPSchemeYieldsText() {
        XCTAssertEqual(BlockImport.plannedBlock(types: [], plainString: "ftp://example.com/file"), .text)
    }

    func testEmptyOrNilStringWithNoImageYieldsNil() {
        XCTAssertNil(BlockImport.plannedBlock(types: [], plainString: nil))
        XCTAssertNil(BlockImport.plannedBlock(types: ["public.utf8-plain-text"], plainString: ""))
        XCTAssertNil(BlockImport.plannedBlock(types: ["public.utf8-plain-text"], plainString: "   \n"))
    }

    func testImageTypesWinOverURLString() {
        XCTAssertEqual(BlockImport.plannedBlock(types: ["public.png", "public.utf8-plain-text"],
                                                plainString: "https://example.com"), .image)
    }
}
