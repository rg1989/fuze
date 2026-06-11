import XCTest
import GRDB
@testable import Fuse

final class NoteStoreTests: XCTestCase {
    /// Returns the store AND its DatabaseQueue so tests can run raw SQL
    /// (e.g. backdating updatedAt) against the same in-memory database.
    private func makeStore() throws -> (store: NoteStore, dbQueue: DatabaseQueue) {
        let dbQueue = try DatabaseQueue()   // in-memory
        return (try NoteStore(dbQueue: dbQueue), dbQueue)
    }

    /// Creates a note, then sleeps 10 ms so updatedAt values (millisecond
    /// precision in GRDB's date encoding) are strictly ordered between creates.
    @discardableResult
    private func makeNote(_ store: NoteStore, title: String) throws -> Note {
        let note = try store.createNote(title: title)
        Thread.sleep(forTimeInterval: 0.01)
        return note
    }

    func testCreateAndFetchNote() throws {
        let (store, _) = try makeStore()
        let created = try store.createNote(title: "Groceries")
        XCTAssertNotNil(created.id)
        let all = try store.notes(matching: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Groceries")
        XCTAssertFalse(all[0].pinned)
    }

    func testNotesOrderedPinnedFirstThenUpdatedAtDescending() throws {
        let (store, _) = try makeStore()
        let oldest = try makeNote(store, title: "oldest")
        try makeNote(store, title: "middle")
        try makeNote(store, title: "newest")
        try store.togglePin(noteId: oldest.id!)
        let titles = try store.notes(matching: nil).map(\.title)
        XCTAssertEqual(titles, ["oldest", "newest", "middle"])   // pinned first, then updatedAt DESC
    }

    func testSearchMatchesTitleCaseInsensitively() throws {
        let (store, _) = try makeStore()
        try makeNote(store, title: "Meeting Notes")
        try makeNote(store, title: "Shopping")
        XCTAssertEqual(try store.notes(matching: "meeting").map(\.title), ["Meeting Notes"])
    }

    func testSearchMatchesBlockContent() throws {
        let (store, _) = try makeStore()
        let match = try makeNote(store, title: "scratch")
        try store.appendBlock(noteId: match.id!, kind: .code,
                              textContent: "func grepMe() {}", language: "swift", imageData: nil)
        try makeNote(store, title: "other")
        let found = try store.notes(matching: "grepme")
        XCTAssertEqual(found.map(\.title), ["scratch"])   // matched via code block body, case-insensitive
    }

    func testAppendBlockAssignsContiguousOrderIndexes() throws {
        let (store, _) = try makeStore()
        let note = try store.createNote(title: "n")
        try store.appendBlock(noteId: note.id!, kind: .text, textContent: "a", language: "", imageData: nil)
        try store.appendBlock(noteId: note.id!, kind: .code, textContent: "b", language: "swift", imageData: nil)
        try store.appendBlock(noteId: note.id!, kind: .text, textContent: "c", language: "", imageData: nil)
        let blocks = try store.blocks(forNote: note.id!)
        XCTAssertEqual(blocks.map(\.orderIndex), [0, 1, 2])
        XCTAssertEqual(blocks.map(\.textContent), ["a", "b", "c"])
        XCTAssertEqual(blocks.map(\.kind), [.text, .code, .text])
    }

    func testMoveBlockReordersAndStaysContiguous() throws {
        let (store, _) = try makeStore()
        let note = try store.createNote(title: "n")
        for s in ["a", "b", "c"] {
            try store.appendBlock(noteId: note.id!, kind: .text, textContent: s, language: "", imageData: nil)
        }
        try store.moveBlock(noteId: note.id!, fromIndex: 0, toIndex: 2)
        let blocks = try store.blocks(forNote: note.id!)
        XCTAssertEqual(blocks.map(\.textContent), ["b", "c", "a"])
        XCTAssertEqual(blocks.map(\.orderIndex), [0, 1, 2])
    }

    func testDeleteBlockCompactsOrderIndexes() throws {
        let (store, _) = try makeStore()
        let note = try store.createNote(title: "n")
        var middleId: Int64 = -1
        for s in ["a", "b", "c"] {
            let block = try store.appendBlock(noteId: note.id!, kind: .text,
                                              textContent: s, language: "", imageData: nil)
            if s == "b" { middleId = block.id! }
        }
        try store.deleteBlock(id: middleId, noteId: note.id!)
        let blocks = try store.blocks(forNote: note.id!)
        XCTAssertEqual(blocks.map(\.textContent), ["a", "c"])
        XCTAssertEqual(blocks.map(\.orderIndex), [0, 1])   // re-compacted, no gap
    }

    func testDeleteNoteCascadesToBlocks() throws {
        let (store, dbQueue) = try makeStore()
        let note = try store.createNote(title: "doomed")
        try store.appendBlock(noteId: note.id!, kind: .text, textContent: "x", language: "", imageData: nil)
        try store.deleteNote(id: note.id!)
        XCTAssertTrue(try store.notes(matching: nil).isEmpty)
        let blockCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM noteBlock") ?? -1
        }
        XCTAssertEqual(blockCount, 0)   // ON DELETE CASCADE removed the blocks
    }

    func testUpdateBlockBumpsNoteUpdatedAt() throws {
        let (store, dbQueue) = try makeStore()
        let note = try store.createNote(title: "n")
        var block = try store.appendBlock(noteId: note.id!, kind: .text,
                                          textContent: "old", language: "", imageData: nil)
        // Backdate the note far into the past, then check updateBlock refreshes it.
        let epoch = Date(timeIntervalSince1970: 0)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE note SET updatedAt = ? WHERE id = ?",
                           arguments: [epoch, note.id!])
        }
        block.textContent = "new"
        try store.updateBlock(block)
        let fetched = try store.notes(matching: nil)[0]
        XCTAssertGreaterThan(fetched.updatedAt, epoch.addingTimeInterval(3600))
        XCTAssertEqual(try store.blocks(forNote: note.id!)[0].textContent, "new")
    }
}
