import XCTest
@testable import Fuse

final class ClipboardVisualsTests: XCTestCase {
    func testEveryKnownKindHasDistinctStyle() {
        let kinds = ["text", "rtf", "link", "image", "file"]
        let styles = kinds.map(KindStyle.style(for:))
        XCTAssertEqual(Set(styles.map(\.symbol)).count, kinds.count, "symbols must be distinct")
        XCTAssertEqual(Set(styles.map(\.tint)).count, kinds.count, "tints must be distinct")
    }

    func testUnknownKindFallsBack() {
        XCTAssertEqual(KindStyle.style(for: "mystery").symbol, "questionmark.square")
    }

    func testVideoDetectionByExtension() {
        XCTAssertTrue(ClipboardMedia.isVideo(path: "/tmp/clip.mov"))
        XCTAssertTrue(ClipboardMedia.isVideo(path: "/tmp/clip.mp4"))
        XCTAssertTrue(ClipboardMedia.isVideo(path: "/tmp/CLIP.M4V"))
        XCTAssertFalse(ClipboardMedia.isVideo(path: "/tmp/photo.png"))
        XCTAssertFalse(ClipboardMedia.isVideo(path: "/tmp/document.pdf"))
        XCTAssertFalse(ClipboardMedia.isVideo(path: "/tmp/noextension"))
    }
}
