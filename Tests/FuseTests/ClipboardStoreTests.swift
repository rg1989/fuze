import XCTest
import GRDB
@testable import Fuse

final class ClipboardStoreTests: XCTestCase {
    private func makeStore() throws -> ClipboardStore { try ClipboardStore(dbQueue: DatabaseQueue()) }

    private func textReps(_ s: String) -> [(type: String, data: Data)] {
        [(type: "public.utf8-plain-text", data: Data(s.utf8))]
    }

    /// Saves a text item, then sleeps 10 ms so createdAt values (millisecond
    /// precision in GRDB's date encoding) are strictly ordered between saves.
    @discardableResult
    private func saveText(_ store: ClipboardStore, _ s: String, pinned: Bool = false) throws -> Int64 {
        let reps = textReps(s)
        let id = try store.save(kind: "text", preview: s, thumbnail: nil, sourceApp: "com.test.app",
                                contentHash: ClipboardStore.hash(representations: reps), representations: reps)
        if pinned { try store.togglePin(id: id) }
        Thread.sleep(forTimeInterval: 0.01)
        return id
    }

    func testHashIsOrderIndependentStableAndContentSensitive() {
        let a: [(type: String, data: Data)] = [
            (type: "public.utf8-plain-text", data: Data("hello".utf8)),
            (type: "public.html", data: Data("<b>hello</b>".utf8)),
        ]
        let b: [(type: String, data: Data)] = [a[1], a[0]]   // permuted input order
        XCTAssertEqual(ClipboardStore.hash(representations: a), ClipboardStore.hash(representations: b))
        XCTAssertEqual(ClipboardStore.hash(representations: a).count, 64)   // hex SHA-256
        XCTAssertNotEqual(ClipboardStore.hash(representations: textReps("one")),
                          ClipboardStore.hash(representations: textReps("two")))
    }

    func testSaveInsertsAndRecentItemsReturnsNewestFirstWithLimit() throws {
        let store = try makeStore()
        try saveText(store, "first"); try saveText(store, "second"); try saveText(store, "third")
        let items = try store.recentItems(limit: 10)
        XCTAssertEqual(items.map(\.preview), ["third", "second", "first"])
        XCTAssertEqual(items[0].kind, "text")
        XCTAssertEqual(items[0].sourceApp, "com.test.app")
        XCTAssertFalse(items[0].pinned)
        XCTAssertEqual(try store.recentItems(limit: 2).count, 2)
    }

    func testSaveDuplicateHashBubblesToTopWithoutNewRow() throws {
        let store = try makeStore()
        let firstId = try saveText(store, "alpha")
        try saveText(store, "beta")
        let againId = try saveText(store, "alpha")   // identical content => identical hash
        let items = try store.recentItems(limit: 10)
        XCTAssertEqual(againId, firstId)             // existing id returned, no duplicate row
        XCTAssertEqual(items.map(\.preview), ["alpha", "beta"])
    }

    func testSearchMatchesCaseInsensitively() throws {
        let store = try makeStore()
        try saveText(store, "Hello World"); try saveText(store, "Goodbye")
        XCTAssertEqual(try store.recentItems(limit: 10, matching: "hello").map(\.preview), ["Hello World"])
    }

    func testRepresentationsRoundtripLosslessly() throws {
        let store = try makeStore()
        let reps: [(type: String, data: Data)] = [
            (type: "public.utf8-plain-text", data: Data("hi".utf8)),
            (type: "public.html", data: Data("<i>hi</i>".utf8)),
        ]
        let id = try store.save(kind: "text", preview: "hi", thumbnail: nil, sourceApp: nil,
                                contentHash: ClipboardStore.hash(representations: reps), representations: reps)
        let loaded = try store.representations(forItem: id)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: loaded.map { ($0.type, $0.data) }),
                       ["public.utf8-plain-text": Data("hi".utf8), "public.html": Data("<i>hi</i>".utf8)])
    }

    func testTogglePinFlipsFlag() throws {
        let store = try makeStore()
        let id = try saveText(store, "pin me")
        try store.togglePin(id: id)
        XCTAssertTrue(try store.recentItems(limit: 10)[0].pinned)
        try store.togglePin(id: id)
        XCTAssertFalse(try store.recentItems(limit: 10)[0].pinned)
    }

    func testDeleteRemovesItemAndRepresentationsCascade() throws {
        let store = try makeStore()
        let id = try saveText(store, "doomed")
        try store.delete(id: id)
        XCTAssertTrue(try store.recentItems(limit: 10).isEmpty)
        XCTAssertTrue(try store.representations(forItem: id).isEmpty)   // ON DELETE CASCADE
    }

    func testDeleteAllUnpinnedKeepsPinnedItems() throws {
        let store = try makeStore()
        try saveText(store, "keep", pinned: true)
        try saveText(store, "drop1"); try saveText(store, "drop2")
        try store.deleteAllUnpinned()
        XCTAssertEqual(try store.recentItems(limit: 10).map(\.preview), ["keep"])
    }

    func testPruneDeletesOldestUnpinnedAndKeepsPinned() throws {
        let store = try makeStore()
        try saveText(store, "A-oldest", pinned: true)   // pinned: must survive any prune
        try saveText(store, "B"); try saveText(store, "C"); try saveText(store, "D"); try saveText(store, "E-newest")
        try store.prune(keeping: 2)                     // keep 2 newest UNPINNED: E, D
        XCTAssertEqual(try store.recentItems(limit: 10).map(\.preview), ["E-newest", "D", "A-oldest"])
    }
}
