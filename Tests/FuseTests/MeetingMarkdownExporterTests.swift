import XCTest
@testable import Fuse

final class MeetingMarkdownExporterTests: XCTestCase {
    private func seg(_ speaker: String, _ text: String) -> MeetingSegment {
        MeetingSegment(id: nil, meetingId: 1, orderIndex: 0, speakerId: speaker,
                       text: text, startSeconds: 0, endSeconds: 1)
    }

    func testRendersTitleAndSpeakerLines() {
        let out = MeetingMarkdownExporter.transcript(
            title: "Standup",
            segments: [seg("Speaker 1", "hello everyone"), seg("Speaker 2", "hi there")])
        XCTAssertEqual(out, "# Standup\n[Speaker 1] hello everyone\n[Speaker 2] hi there\n")
    }

    func testExactlyOneTrailingNewline() {
        let out = MeetingMarkdownExporter.transcript(title: "T", segments: [seg("Speaker 1", "x")])
        XCTAssertTrue(out.hasSuffix("\n"))
        XCTAssertFalse(out.hasSuffix("\n\n"))
    }

    func testEmptyTitleOmitsHeading() {
        let out = MeetingMarkdownExporter.transcript(title: "", segments: [seg("Speaker 1", "x")])
        XCTAssertEqual(out, "[Speaker 1] x\n")
    }
}
