import XCTest
@testable import Fuse

final class MarkdownExporterTests: XCTestCase {
    private func block(_ kind: BlockKind, _ text: String,
                       language: String = "", image: Data? = nil) -> NoteBlock {
        NoteBlock(id: nil, noteId: 1, orderIndex: 0, kind: kind,
                  textContent: text, language: language, imageData: image)
    }

    func testFullNoteWithAllFourBlockKinds() {
        let blocks = [
            block(.text, "Some intro text."),
            block(.code, "print(\"hi\")", language: "swift"),
            block(.link, "https://example.com"),
            block(.image, "", image: Data([0x89])),
        ]
        let expected = [
            "# My Note",
            "",
            "Some intro text.",
            "",
            "```swift",
            "print(\"hi\")",
            "```",
            "",
            "<https://example.com>",
            "",
            "> *[image block — not exported]*",
            "",
        ].joined(separator: "\n")
        XCTAssertEqual(MarkdownExporter.markdown(title: "My Note", blocks: blocks), expected)
    }

    func testEmptyTitleOmitsHeading() {
        let md = MarkdownExporter.markdown(title: "", blocks: [block(.text, "Just text.")])
        XCTAssertEqual(md, "Just text.\n")
    }

    func testCodeBlockWithEmptyLanguageRendersBareFence() {
        let md = MarkdownExporter.markdown(title: "", blocks: [block(.code, "ls -la")])
        XCTAssertEqual(md, ["```", "ls -la", "```", ""].joined(separator: "\n"))
    }

    func testOutputEndsWithExactlyOneTrailingNewline() {
        let md = MarkdownExporter.markdown(title: "T", blocks: [block(.text, "body")])
        XCTAssertEqual(md, "# T\n\nbody\n")
        XCTAssertTrue(md.hasSuffix("\n"))
        XCTAssertFalse(md.hasSuffix("\n\n"))
    }
}
