import AppKit
import XCTest
@testable import Fuse

final class ImageEncodingTests: XCTestCase {
    private func solidImage(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }

    func testPNGExtensionProducesPNGMagicBytes() {
        let data = ImageEditorState.imageData(of: solidImage(width: 4, height: 4),
                                              forPathExtension: "png")
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testJPGExtensionProducesJPEGMagicBytes() {
        let data = ImageEditorState.imageData(of: solidImage(width: 4, height: 4),
                                              forPathExtension: "jpg")
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(2)), [0xFF, 0xD8])
    }

    func testJPEGExtensionUppercaseAlsoJPEG() {
        let data = ImageEditorState.imageData(of: solidImage(width: 4, height: 4),
                                              forPathExtension: "JPEG")
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(2)), [0xFF, 0xD8])
    }

    func testUnknownExtensionFallsBackToPNG() {
        let data = ImageEditorState.imageData(of: solidImage(width: 4, height: 4),
                                              forPathExtension: "webp")
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
