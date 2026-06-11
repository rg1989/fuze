import XCTest
import AppKit
@testable import Fuse

final class PasteServiceTests: XCTestCase {
    private func freshPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("FuseTests.\(UUID().uuidString)"))
    }

    func testSnapshotCapturesAllTypesOfAllItems() {
        let pb = freshPasteboard()
        pb.clearContents()
        pb.setString("hello", forType: .string)

        let snap = PasteService.snapshot(of: pb)

        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0][.string], Data("hello".utf8))
    }

    func testWriteThenSnapshotRoundtrips() {
        let pb = freshPasteboard()
        let items: [PasteService.ItemRepresentation] = [
            [.string: Data("one".utf8)],
            [.string: Data("two".utf8), NSPasteboard.PasteboardType("public.html"): Data("<b>two</b>".utf8)],
        ]

        PasteService.write(items, to: pb, markInternal: false)
        let snap = PasteService.snapshot(of: pb)

        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[0][.string], Data("one".utf8))
        XCTAssertEqual(snap[1][NSPasteboard.PasteboardType("public.html")], Data("<b>two</b>".utf8))
    }

    func testWriteMarksInternalByDefaultSemantics() {
        let pb = freshPasteboard()

        PasteService.write([[.string: Data("x".utf8)]], to: pb, markInternal: true)

        XCTAssertTrue(pb.types?.contains(PasteService.fuseInternalMarker) ?? false)
    }

    func testWriteWithoutMarkerLeavesNoMarker() {
        let pb = freshPasteboard()

        PasteService.write([[.string: Data("x".utf8)]], to: pb, markInternal: false)

        XCTAssertFalse(pb.types?.contains(PasteService.fuseInternalMarker) ?? false)
    }

    func testRestoreReplacesCurrentContents() {
        let pb = freshPasteboard()
        pb.clearContents()
        pb.setString("original", forType: .string)
        let saved = PasteService.snapshot(of: pb)

        pb.clearContents()
        pb.setString("intruder", forType: .string)
        PasteService.write(saved, to: pb, markInternal: true)

        XCTAssertEqual(pb.string(forType: .string), "original")
    }
}
