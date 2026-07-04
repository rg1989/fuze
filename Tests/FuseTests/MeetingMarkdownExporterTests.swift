import XCTest
@testable import Fuse

final class MeetingMarkdownExporterTests: XCTestCase {
    private func seg(_ speaker: String, _ text: String,
                    _ start: Double = 0, _ end: Double = 1) -> MeetingSegment {
        MeetingSegment(id: nil, meetingId: 1, orderIndex: 0, speakerId: speaker,
                       text: text, startSeconds: start, endSeconds: end)
    }

    func testRendersTitleTimecodesAndSpeakerLines() {
        let out = MeetingMarkdownExporter.transcript(
            title: "Standup",
            segments: [seg("Speaker 1", "hello everyone", 0, 3),
                       seg("Speaker 2", "hi there", 5, 7)])
        XCTAssertEqual(out, "# Standup\n[0:00–0:03] Speaker 1: hello everyone\n[0:05–0:07] Speaker 2: hi there\n")
    }

    func testTimecodePastAnHour() {
        XCTAssertEqual(MeetingMarkdownExporter.timecode(0), "0:00")
        XCTAssertEqual(MeetingMarkdownExporter.timecode(65), "1:05")
        XCTAssertEqual(MeetingMarkdownExporter.timecode(3661), "1:01:01")
    }

    func testExactlyOneTrailingNewline() {
        let out = MeetingMarkdownExporter.transcript(title: "T", segments: [seg("Speaker 1", "x")])
        XCTAssertTrue(out.hasSuffix("\n"))
        XCTAssertFalse(out.hasSuffix("\n\n"))
    }

    func testEmptyTitleOmitsHeading() {
        let out = MeetingMarkdownExporter.transcript(title: "", segments: [seg("Speaker 1", "x", 0, 1)])
        XCTAssertEqual(out, "[0:00–0:01] Speaker 1: x\n")
    }
}
