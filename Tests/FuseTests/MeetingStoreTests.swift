import XCTest
import GRDB
@testable import Fuse

final class MeetingStoreTests: XCTestCase {
    private func makeStore() throws -> MeetingStore {
        try MeetingStore(dbQueue: DatabaseQueue())   // in-memory
    }

    private func save(_ store: MeetingStore, title: String,
                      _ segs: [(String, String)]) throws -> Meeting {
        try store.saveMeeting(
            title: title, date: Date(), durationSeconds: 12, cleanedText: nil,
            segments: segs.enumerated().map { (speakerId: $1.0, text: $1.1,
                                               start: Double($0), end: Double($0) + 1) })
    }

    func testRoundTripSaveAndFetchSegments() throws {
        let store = try makeStore()
        let m = try save(store, title: "Kickoff",
                         [("Speaker 1", "hello"), ("Speaker 2", "world")])
        let segs = try store.segments(forMeeting: m.id!)
        XCTAssertEqual(segs.map(\.text), ["hello", "world"])
        XCTAssertEqual(segs.map(\.orderIndex), [0, 1])
        XCTAssertEqual(segs.map(\.speakerId), ["Speaker 1", "Speaker 2"])
    }

    func testSearchMatchesTitleOrSegmentText() throws {
        let store = try makeStore()
        _ = try save(store, title: "Budget review", [("Speaker 1", "quarterly numbers")])
        _ = try save(store, title: "Standup", [("Speaker 1", "deploy pipeline")])
        XCTAssertEqual(try store.meetings(matching: "budget").count, 1)      // title
        XCTAssertEqual(try store.meetings(matching: "pipeline").count, 1)    // segment content
        XCTAssertEqual(try store.meetings(matching: "zzz").count, 0)
        XCTAssertEqual(try store.meetings(matching: nil).count, 2)
    }

    func testDeleteCascadesToSegments() throws {
        let store = try makeStore()
        let m = try save(store, title: "Temp", [("Speaker 1", "gone soon")])
        try store.deleteMeeting(id: m.id!)
        XCTAssertEqual(try store.meetings(matching: nil).count, 0)
        XCTAssertTrue(try store.segments(forMeeting: m.id!).isEmpty)   // cascade
    }

    func testExportRendersMarkdown() throws {
        let store = try makeStore()
        let m = try save(store, title: "Sync", [("Speaker 1", "a"), ("Speaker 2", "b")])
        let md = try store.export(meetingID: m.id!)
        XCTAssertEqual(md, "# Sync\n[0:00–0:01] Speaker 1: a\n[0:01–0:02] Speaker 2: b\n")
    }
}
