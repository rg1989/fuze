# Phase 8: Quick Notes Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–1 complete.

**Goal:** A Heynote-style quick-capture notes panel toggled by the global hotkey ⌃⌥M (`.toggleNotesPanel`). A note is an ORDERED LIST OF BLOCKS — text, code, image, or link — each rendered by its own small SwiftUI editor with a per-block Copy button (the headline feature: copy ONLY a code snippet out of a mixed note with one click). Notes persist in a GRDB/SQLite store, are searchable by title AND block content, can be pinned, exported as deterministic Markdown (single note → clipboard, all notes → `.md` files), and the panel is non-activating: it floats over any app — including full-screen apps — without stealing frontmost status.

**Architecture:** Everything lives in `Sources/Notes/`. Pure logic (`NoteStore`, `MarkdownExporter`, `BlockImport`) is TDD'd against in-memory databases and plain values. OS-integration code (the non-activating `NSPanel`, the SwiftUI editor UI, hotkey wiring) is built, then human-verified. The note model is block-based (NOT one rich `NSTextView`) because per-block copy is the headline feature, the model is fully unit-testable, and image attachments in NSTextView/RTFD are fragile. Shared files are touched ONLY at the three `// FUSE:*` anchors in `AppDelegate.swift`, the `// FUSE:SETTINGS_TABS` anchor in `SettingsRootView.swift`, plus ONE added line in `Sources/Core/Log.swift` (the missing `notes` logger).

**Tech Stack:** Swift 5.10, AppKit + SwiftUI (`NSPanel` + `NSHostingView`), GRDB 6 (`DatabaseQueue`, `DatabaseMigrator`, Codable records), KeyboardShortcuts 2.x (`.toggleNotesPanel` hotkey + recorder), XCTest.

---

## Context recap (the implementer must know this — do not skip)

Core APIs consumed (Phase 1, `Sources/Core/` — never redefine):

```swift
PasteService.ItemRepresentation        // typealias [NSPasteboard.PasteboardType: Data]
PasteService.write(_ items: [PasteService.ItemRepresentation],
                   to pasteboard: NSPasteboard = .general,
                   markInternal: Bool = true)
KeyboardShortcuts.Name.toggleNotesPanel   // default ⌃⌥M — the ONLY hotkey this phase uses
Log.notes                                 // os.Logger — DOES NOT EXIST YET; Task 8.1 adds it
```

**`markInternal` rule (critical):** every Copy button in this phase calls `PasteService.write(..., markInternal: false)`. A block copy is a DELIBERATE user copy, so Fuse's own clipboard-history watcher (Phase 4, if installed) SHOULD record it — that is a feature, not a bug. `markInternal: true` is reserved for Fuse's invisible write/restore plumbing (Phase 4/5 paste flows). Never pass `true` here.

**Hotkey rule:** use ONLY the existing constant `.toggleNotesPanel` from `Sources/Core/HotkeyNames.swift` via `KeyboardShortcuts.onKeyDown(for: .toggleNotesPanel)`. NEVER define a new `KeyboardShortcuts.Name` anywhere in this phase.

**Settings key** (master §6.4): `"notes.panelPinned"` (Bool, default `false`). Pinned = panel stays visible when it loses key status; unpinned = panel auto-hides on `NSWindow.didResignKeyNotification`.

**Database:** `~/Library/Application Support/Fuse/notes.sqlite` via `DatabaseQueue`; tests use `try DatabaseQueue()` (in-memory). Foreign keys are ON by default in GRDB — do NOT add any `PRAGMA foreign_keys` statements.

Commands used throughout (run from `/Users/rgv250cc/Documents/Projects/Fuse`):

```bash
xcodegen generate     # after EVERY file create/delete, BEFORE building
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5   # expect ** BUILD SUCCEEDED **
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20                       # expect ** TEST SUCCEEDED **
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app    # run the app
```

New files: `Sources/Notes/{NoteModels,NoteStore,MarkdownExporter,BlockImport,NotesPanel,NotesPanelView,NotesController,NotesSettingsView}.swift`; tests `Tests/FuseTests/{NoteStoreTests,MarkdownExporterTests,BlockImportTests}.swift`. Modified files: `Sources/Core/Log.swift` (one added line), `Sources/App/AppDelegate.swift` (anchor inserts only), `Sources/App/SettingsRootView.swift` (anchor insert only).

---

### Task 8.0: Preflight

**Files:** none (verification only).

- [x] **Step 1: Verify Phase 1 files, all four anchors, and the hotkey constant exist**

```bash
ls Sources/Core
grep -c "FUSE:CONTROLLER-PROPS\|FUSE:CONTROLLER-START\|FUSE:MENU-ITEMS" Sources/App/AppDelegate.swift
grep -c "FUSE:SETTINGS_TABS" Sources/App/SettingsRootView.swift
grep -n "toggleNotesPanel" Sources/Core/HotkeyNames.swift
grep -c "static let notes" Sources/Core/Log.swift; true
ls Sources/Notes 2>/dev/null || echo "Notes dir not present yet (expected)"
```

Expected:
1. `ls Sources/Core` lists all of `AX.swift HotkeyNames.swift Log.swift PasteService.swift Permissions.swift`.
2. The first grep prints `3` (all three AppDelegate anchors present).
3. The second grep prints `1` (settings anchor present).
4. The `toggleNotesPanel` grep prints the line defining `static let toggleNotesPanel = Self("toggleNotesPanel", default: .init(.m, modifiers: [.control, .option]))`.
5. The `Log.swift` grep prints `0` (the `notes` logger does not exist yet — Task 8.1 adds it; if it prints `1`, skip Task 8.1).
6. `Notes dir not present yet (expected)` — if `Sources/Notes/` already has files, STOP and ask the user whether Phase 8 was partially executed before.

If anything in items 1–4 is missing, STOP — Phases 0–1 are incomplete.

- [x] **Step 2: Verify build and tests are green before touching anything**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`. If red, STOP and fix before starting this phase.

---

### Task 8.1: Add the `notes` logger to Core

**Files:**
- Modify: `Sources/Core/Log.swift` (ONE added line — change nothing else)

Core's `Log` enum has loggers for every feature EXCEPT notes. Add exactly one line after the `downloader` line.

- [x] **Step 1: Read `Sources/Core/Log.swift`, then insert the `notes` logger**

Insert this single line directly AFTER the line containing `static let downloader`:

```swift
    static let notes = Logger(subsystem: "com.rgv250cc.Fuse", category: "notes")
```

Assuming the Phase 1 baseline file, the full updated file body is:

```swift
import os

enum Log {
    static let app = Logger(subsystem: "com.rgv250cc.Fuse", category: "app")
    static let scroll = Logger(subsystem: "com.rgv250cc.Fuse", category: "scroll")
    static let tiling = Logger(subsystem: "com.rgv250cc.Fuse", category: "tiling")
    static let clipboard = Logger(subsystem: "com.rgv250cc.Fuse", category: "clipboard")
    static let voice = Logger(subsystem: "com.rgv250cc.Fuse", category: "voice")
    static let downloader = Logger(subsystem: "com.rgv250cc.Fuse", category: "downloader")
    static let notes = Logger(subsystem: "com.rgv250cc.Fuse", category: "notes")
    static let notifications = Logger(subsystem: "com.rgv250cc.Fuse", category: "notifications")
}
```

If the on-disk file differs from this baseline (another phase may have touched it), do NOT overwrite it — only add the single `notes` line after `downloader`, preserving everything else.

- [x] **Step 2: Build, test, commit**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
git add Sources/Core/Log.swift
git commit -m "feat(core): add notes logger"
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`. (No `xcodegen generate` needed — no file was created or deleted.)

---

### Task 8.2: Note models + NoteStore (TDD)

**Files:**
- Create: `Sources/Notes/NoteModels.swift`
- Create: `Sources/Notes/NoteStore.swift`
- Test: `Tests/FuseTests/NoteStoreTests.swift`

Two tables: `note` (title, timestamps, pin flag) and `noteBlock` (ordered blocks belonging to a note; `noteId REFERENCES note(id) ON DELETE CASCADE`; index on `(noteId, orderIndex)`). `orderIndex` is ALWAYS kept contiguous `0..n-1` per note — append assigns `max+1`, move/delete rewrite the whole sequence. Every block mutation "touches" the owning note's `updatedAt` so the sidebar sorts recently-edited notes first.

- [x] **Step 1: Write the failing tests — `Tests/FuseTests/NoteStoreTests.swift`**

```swift
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
```

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: **BUILD FAILS** with `cannot find 'NoteStore' in scope` (and `cannot find type 'Note'`). A compile failure is this step's "red".

- [x] **Step 3: Write `Sources/Notes/NoteModels.swift`**

```swift
import Foundation
import GRDB

/// What a block contains. Stored in SQLite as TEXT via rawValue.
enum BlockKind: String, Codable {
    case text, code, image, link
}

/// One note: a title plus an ordered list of NoteBlock rows.
struct Note: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "note"

    var id: Int64?
    var title: String          // "" allowed; the UI shows "Untitled"
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One block of a note. Exactly one content field is meaningful per kind:
/// text/code/link use `textContent` (code also uses `language`); image uses `imageData` (PNG bytes).
struct NoteBlock: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "noteBlock"

    var id: Int64?
    var noteId: Int64          // references note.id, ON DELETE CASCADE
    var orderIndex: Int        // contiguous 0..n-1 within a note, always
    var kind: BlockKind
    var textContent: String    // text/code/link content; "" for image blocks
    var language: String       // code blocks: "swift", "bash", ...; "" otherwise
    var imageData: Data?       // PNG bytes for image blocks; nil otherwise

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

- [x] **Step 4: Write `Sources/Notes/NoteStore.swift`**

```swift
import Foundation
import GRDB

/// SQLite-backed notes store. Thread-safe: DatabaseQueue serializes access.
/// Foreign keys are ON by default in GRDB — no pragmas needed; deleting a
/// note cascades to its blocks via the schema's ON DELETE CASCADE.
final class NoteStore {
    /// App-wide instance. The controller AND the settings tab must both use this
    /// single instance — never open a second connection to the same file.
    static let shared: NoteStore? = try? NoteStore.onDisk()

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    static func onDisk() throws -> NoteStore {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Fuse", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return try NoteStore(dbQueue: DatabaseQueue(path: dir.appendingPathComponent("notes.sqlite").path))
    }

    /// Absolute path of the on-disk database file (settings tab shows its size).
    static var onDiskPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fuse/notes.sqlite").path
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "noteBlock") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("noteId", .integer).notNull().references("note", onDelete: .cascade)
                t.column("orderIndex", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("textContent", .text).notNull()
                t.column("language", .text).notNull()
                t.column("imageData", .blob)
            }
            try db.create(index: "noteBlock_noteId_orderIndex",
                          on: "noteBlock", columns: ["noteId", "orderIndex"])
        }
        return migrator
    }

    // MARK: Notes

    @discardableResult
    func createNote(title: String) throws -> Note {
        try dbQueue.write { db in
            var note = Note(id: nil, title: title, createdAt: Date(), updatedAt: Date(), pinned: false)
            try note.insert(db)
            return note
        }
    }

    /// Pinned notes first, then most recently updated. `query` (if non-empty)
    /// filters with case-insensitive LIKE over the title OR any block's
    /// textContent (LEFT JOIN + DISTINCT so multi-block matches return one row).
    func notes(matching query: String?) throws -> [Note] {
        try dbQueue.read { db in
            if let query, !query.isEmpty {
                let pattern = "%\(query)%"
                return try Note.fetchAll(db, sql: """
                    SELECT DISTINCT note.* FROM note
                    LEFT JOIN noteBlock ON noteBlock.noteId = note.id
                    WHERE note.title LIKE ? OR noteBlock.textContent LIKE ?
                    ORDER BY note.pinned DESC, note.updatedAt DESC, note.id DESC
                    """, arguments: [pattern, pattern])
            }
            return try Note
                .order(Column("pinned").desc, Column("updatedAt").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    func renameNote(id: Int64, title: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE note SET title = ?, updatedAt = ? WHERE id = ?",
                           arguments: [title, Date(), id])
        }
    }

    /// Flips the pin flag. Deliberately does NOT touch updatedAt, so pinning
    /// never reshuffles the updatedAt ordering within the pinned group.
    func togglePin(noteId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE note SET pinned = NOT pinned WHERE id = ?",
                           arguments: [noteId])
        }
    }

    func deleteNote(id: Int64) throws {
        _ = try dbQueue.write { db in try Note.deleteOne(db, key: id) }
    }

    // MARK: Blocks

    func blocks(forNote id: Int64) throws -> [NoteBlock] {
        try dbQueue.read { db in
            try NoteBlock.filter(Column("noteId") == id).order(Column("orderIndex")).fetchAll(db)
        }
    }

    /// orderIndex = current max + 1 (0 for the first block); touches note.updatedAt.
    @discardableResult
    func appendBlock(noteId: Int64, kind: BlockKind, textContent: String,
                     language: String, imageData: Data?) throws -> NoteBlock {
        try dbQueue.write { db in
            let maxIndex = try Int.fetchOne(
                db, sql: "SELECT MAX(orderIndex) FROM noteBlock WHERE noteId = ?",
                arguments: [noteId]) ?? -1
            var block = NoteBlock(id: nil, noteId: noteId, orderIndex: maxIndex + 1, kind: kind,
                                  textContent: textContent, language: language, imageData: imageData)
            try block.insert(db)
            try Self.touch(noteId: noteId, db: db)
            return block
        }
    }

    /// Saves content edits (textContent / language / kind); touches note.updatedAt.
    func updateBlock(_ block: NoteBlock) throws {
        try dbQueue.write { db in
            try block.update(db)
            try Self.touch(noteId: block.noteId, db: db)
        }
    }

    /// Moves the block at `fromIndex` to `toIndex` (indexes into the ordered
    /// block list), then rewrites orderIndex 0..n-1 contiguously.
    func moveBlock(noteId: Int64, fromIndex: Int, toIndex: Int) throws {
        try dbQueue.write { db in
            var blocks = try NoteBlock.filter(Column("noteId") == noteId)
                .order(Column("orderIndex")).fetchAll(db)
            guard blocks.indices.contains(fromIndex), blocks.indices.contains(toIndex),
                  fromIndex != toIndex else { return }
            let moved = blocks.remove(at: fromIndex)
            blocks.insert(moved, at: toIndex)
            for (index, block) in blocks.enumerated() where block.orderIndex != index {
                var updated = block
                updated.orderIndex = index
                try updated.update(db)
            }
            try Self.touch(noteId: noteId, db: db)
        }
    }

    /// Deletes one block, then re-compacts the remaining orderIndexes to 0..n-1.
    func deleteBlock(id: Int64, noteId: Int64) throws {
        try dbQueue.write { db in
            _ = try NoteBlock.deleteOne(db, key: id)
            let remaining = try NoteBlock.filter(Column("noteId") == noteId)
                .order(Column("orderIndex")).fetchAll(db)
            for (index, block) in remaining.enumerated() where block.orderIndex != index {
                var updated = block
                updated.orderIndex = index
                try updated.update(db)
            }
            try Self.touch(noteId: noteId, db: db)
        }
    }

    private static func touch(noteId: Int64, db: Database) throws {
        try db.execute(sql: "UPDATE note SET updatedAt = ? WHERE id = ?",
                       arguments: [Date(), noteId])
    }
}
```

- [x] **Step 5: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, all 9 `NoteStoreTests` passed and every pre-existing test still green. (Hosted tests launch Fuse.app, but the `XCTestCase` guard in `applicationDidFinishLaunching` keeps all controllers off during test runs.)

- [x] **Step 6: Commit**

```bash
git add Sources/Notes/NoteModels.swift Sources/Notes/NoteStore.swift Tests/FuseTests/NoteStoreTests.swift
git commit -m "feat(notes): GRDB note store with ordered blocks, search, and pinning"
```

---

### Task 8.3: MarkdownExporter (TDD)

**Files:**
- Create: `Sources/Notes/MarkdownExporter.swift`
- Test: `Tests/FuseTests/MarkdownExporterTests.swift`

Pure function, deterministic output. Rendering rules: title (if non-empty) → `# <title>`; text → verbatim; code → fenced block with the block's language after the opening fence (bare fence when language is `""`); link → `<url>` autolink form; image → the literal line `> *[image block — not exported]*`. Sections are joined by ONE blank line; the result ends with exactly ONE trailing newline. WARNING: the image placeholder contains an em dash (`—`, U+2014) — implementation and tests must match byte-for-byte; copy both from this plan.

- [x] **Step 1: Write the failing tests — `Tests/FuseTests/MarkdownExporterTests.swift`**

Expected strings are built from line arrays joined with `"\n"` — a trailing `""` element produces the single trailing newline unambiguously.

````swift
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
````

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: **BUILD FAILS** with `cannot find 'MarkdownExporter' in scope`.

- [x] **Step 3: Write `Sources/Notes/MarkdownExporter.swift`**

````swift
import Foundation

/// Deterministic Markdown rendering of a note. Pure — fully unit-tested.
enum MarkdownExporter {
    /// Title (if non-empty) becomes "# <title>". Blocks render in array order,
    /// separated by single blank lines:
    ///   text  -> content verbatim
    ///   code  -> ```<language> fence (bare ``` when language is "")
    ///   link  -> <url> autolink form
    ///   image -> "> *[image block — not exported]*" placeholder
    /// The result always ends with exactly one trailing newline.
    /// (Empty title AND zero blocks yields "\n" — deterministic, never crashes.)
    static func markdown(title: String, blocks: [NoteBlock]) -> String {
        var sections: [String] = []
        if !title.isEmpty {
            sections.append("# \(title)")
        }
        for block in blocks {
            switch block.kind {
            case .text:
                sections.append(block.textContent)
            case .code:
                sections.append("```\(block.language)\n\(block.textContent)\n```")
            case .link:
                sections.append("<\(block.textContent)>")
            case .image:
                sections.append("> *[image block — not exported]*")
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}
````

- [x] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, all 4 `MarkdownExporterTests` passed.

- [x] **Step 5: Commit**

```bash
git add Sources/Notes/MarkdownExporter.swift Tests/FuseTests/MarkdownExporterTests.swift
git commit -m "feat(notes): deterministic Markdown exporter"
```

---

### Task 8.4: BlockImport — clipboard import decision logic (TDD)

**Files:**
- Create: `Sources/Notes/BlockImport.swift`
- Test: `Tests/FuseTests/BlockImportTests.swift`

Pure decision logic for the "+ From Clipboard" button: given the pasteboard's available type strings and its plain string (if any), decide which `BlockKind` to create. Priority: **image** (`public.png` or `public.tiff` present) > **link** (string parses as an http/https URL with a host and contains no whitespace) > **text**. Returns `nil` when there is nothing usable (no image data AND no non-empty string). **Code blocks are NEVER auto-detected** — heuristics misfire; the user converts a block to code manually via the block's kind menu (Task 8.6).

- [x] **Step 1: Write the failing tests — `Tests/FuseTests/BlockImportTests.swift`**

```swift
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
```

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: **BUILD FAILS** with `cannot find 'BlockImport' in scope`.

- [x] **Step 3: Write `Sources/Notes/BlockImport.swift`**

```swift
import Foundation

/// Pure decision logic: which kind of block should "+ From Clipboard" create?
/// Inputs are plain values, so this is fully unit-testable without NSPasteboard.
/// Code blocks are NEVER auto-detected — heuristics misfire; the user converts
/// a text block to code manually in the UI.
enum BlockImport {
    /// `types` = raw NSPasteboard.PasteboardType strings currently available;
    /// `plainString` = the pasteboard's string contents, if any.
    /// Priority: image > link > text. Returns nil when nothing usable exists.
    static func plannedBlock(types: Set<String>, plainString: String?) -> BlockKind? {
        if types.contains("public.png") || types.contains("public.tiff") {
            return .image
        }
        guard let trimmed = plainString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if isHTTPURL(trimmed) { return .link }
        return .text
    }

    /// True only for http/https URLs with a non-empty host and NO whitespace.
    /// The explicit whitespace check MUST come first: on macOS 14+ URL(string:)
    /// is lenient and percent-encodes spaces instead of returning nil.
    private static func isHTTPURL(_ string: String) -> Bool {
        guard string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, all 8 `BlockImportTests` passed.

- [x] **Step 5: Commit**

```bash
git add Sources/Notes/BlockImport.swift Tests/FuseTests/BlockImportTests.swift
git commit -m "feat(notes): clipboard block-import decision logic"
```

---

### Task 8.5: NotesPanel — non-activating floating panel

**Files:**
- Create: `Sources/Notes/NotesPanel.swift`

The panel is **non-activating**: it takes keyboard focus WITHOUT activating Fuse, so the previously frontmost app stays active-looking (its name stays in the menu bar) while the user types into the notes panel — exactly like Spotlight. This cannot be unit-tested; this task is implement → build → verify later in Task 8.7's HUMAN-VERIFY.

- [x] **Step 1: Write `Sources/Notes/NotesPanel.swift`**

```swift
import AppKit

/// Non-activating floating panel hosting the notes UI. `.nonactivatingPanel`
/// + `canBecomeKey` = keyboard focus here while the previous app STAYS active.
/// Show/hide rules (Esc, auto-hide on resign-key unless pinned) live in
/// NotesController, which owns this panel.
final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                   styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Fuse Notes"
        titlebarAppearsTransparent = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 560, height: 380)
    }

    /// Center on the screen currently containing the mouse pointer.
    func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.midY - frame.height / 2))
    }
}
```

- [x] **Step 2: Regenerate, build, test, commit**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
git add Sources/Notes/NotesPanel.swift
git commit -m "feat(notes): non-activating floating notes panel"
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **` (no new tests; nothing existing may break).

---

### Task 8.6: NotesViewModel + NotesPanelView — block-based editor UI

**Files:**
- Create: `Sources/Notes/NotesPanelView.swift` (contains `Debouncer`, `NotesViewModel`, `NotesPanelView`, `BlockView` — all in this one file by design)

Layout: an `HStack`. LEFT column (~200 pt): search field, "New Note" button, list of notes (title or "Untitled", pin indicator, relative updatedAt; context menu with Pin/Unpin and Delete-with-confirmation). RIGHT column: large title field (debounced rename), scrolling list of block views, bottom toolbar with "+ Text", "+ Code", "+ From Clipboard", and "Copy as Markdown". Every block has a hover toolbar: kind label, Copy, ▲, ▼, delete, and (text/code only) a convert menu. Edits autosave after a 0.5 s debounce. All store calls go through `NotesViewModel`; every structural mutation is followed by a reload so the UI always mirrors the database. Plain `ObservableObject` (no `@MainActor` — matches the Phase 4 view-model pattern; everything runs on the main thread anyway).

- [x] **Step 1: Write `Sources/Notes/NotesPanelView.swift`**

```swift
import AppKit
import SwiftUI

// MARK: - Debouncer

/// Coalesces rapid calls (e.g. every keystroke) into one trailing call
/// `delay` seconds after the last one. Main-thread only.
final class Debouncer {
    private let delay: TimeInterval
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func call(_ action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

// MARK: - View model

/// All state for the notes panel. Owned by NotesController, injected into
/// NotesPanelView. Every store mutation goes through here.
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var blocks: [NoteBlock] = []
    @Published var selectedNoteId: Int64?
    @Published var noteTitle: String = ""
    @Published var searchText: String = "" {
        didSet { if oldValue != searchText { reloadNotes() } }
    }

    private let store: NoteStore
    private let titleDebouncer = Debouncer(delay: 0.5)
    private var blockDebouncers: [Int64: Debouncer] = [:]

    init(store: NoteStore) {
        self.store = store
    }

    // MARK: Loading

    /// Called by NotesController every time the panel is shown.
    func reloadAll() {
        reloadNotes()
    }

    func reloadNotes() {
        do {
            notes = try store.notes(matching: searchText.isEmpty ? nil : searchText)
        } catch {
            Log.notes.error("reload notes failed: \(error.localizedDescription)")
            notes = []
        }
        if selectedNoteId == nil || !notes.contains(where: { $0.id == selectedNoteId }) {
            selectedNoteId = notes.first?.id
        }
        reloadBlocks()
    }

    func selectNote(_ id: Int64?) {
        selectedNoteId = id
        reloadBlocks()
    }

    private func reloadBlocks() {
        guard let id = selectedNoteId else {
            blocks = []
            noteTitle = ""
            return
        }
        do {
            blocks = try store.blocks(forNote: id)
        } catch {
            Log.notes.error("reload blocks failed: \(error.localizedDescription)")
            blocks = []
        }
        noteTitle = notes.first(where: { $0.id == id })?.title ?? ""
    }

    // MARK: Note mutations

    /// New notes start with one empty text block, selected immediately.
    func createNote() {
        do {
            let note = try store.createNote(title: "")
            try store.appendBlock(noteId: note.id!, kind: .text,
                                  textContent: "", language: "", imageData: nil)
            searchText = ""          // clear any filter so the new note is visible
            selectedNoteId = note.id
            reloadNotes()
        } catch {
            Log.notes.error("create note failed: \(error.localizedDescription)")
        }
    }

    /// Called on every keystroke in the title field; persists 0.5 s after the
    /// last keystroke. Refreshes the sidebar WITHOUT calling reloadBlocks(),
    /// which would clobber `noteTitle` mid-edit.
    func setTitle(_ newTitle: String) {
        noteTitle = newTitle
        guard let id = selectedNoteId else { return }
        titleDebouncer.call { [weak self] in
            guard let self else { return }
            do {
                try self.store.renameNote(id: id, title: newTitle)
                self.notes = try self.store.notes(
                    matching: self.searchText.isEmpty ? nil : self.searchText)
            } catch {
                Log.notes.error("rename failed: \(error.localizedDescription)")
            }
        }
    }

    func togglePin(_ note: Note) {
        guard let id = note.id else { return }
        do {
            try store.togglePin(noteId: id)
            reloadNotes()
        } catch {
            Log.notes.error("toggle pin failed: \(error.localizedDescription)")
        }
    }

    func deleteNote(_ note: Note) {
        guard let id = note.id else { return }
        do {
            try store.deleteNote(id: id)     // cascade removes the blocks
            if selectedNoteId == id { selectedNoteId = nil }
            reloadNotes()
        } catch {
            Log.notes.error("delete note failed: \(error.localizedDescription)")
        }
    }

    // MARK: Block mutations

    func appendBlock(kind: BlockKind) {
        guard let noteId = selectedNoteId else { return }
        do {
            try store.appendBlock(noteId: noteId, kind: kind,
                                  textContent: "", language: "", imageData: nil)
            reloadBlocks()
        } catch {
            Log.notes.error("append block failed: \(error.localizedDescription)")
        }
    }

    /// Reads NSPasteboard.general and creates an image/link/text block per
    /// BlockImport's decision. Converts TIFF→PNG when only TIFF is present.
    func appendFromClipboard() {
        guard let noteId = selectedNoteId else { return }
        let pasteboard = NSPasteboard.general
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let plain = pasteboard.string(forType: .string)
        guard let kind = BlockImport.plannedBlock(types: types, plainString: plain) else { return }
        do {
            switch kind {
            case .image:
                guard let png = Self.pngData(from: pasteboard) else { return }
                try store.appendBlock(noteId: noteId, kind: .image,
                                      textContent: "", language: "", imageData: png)
            case .link:
                let trimmed = (plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try store.appendBlock(noteId: noteId, kind: .link,
                                      textContent: trimmed, language: "", imageData: nil)
            case .text:
                try store.appendBlock(noteId: noteId, kind: .text,
                                      textContent: plain ?? "", language: "", imageData: nil)
            case .code:
                break   // BlockImport never returns .code (no auto-detection)
            }
            reloadBlocks()
        } catch {
            Log.notes.error("clipboard import failed: \(error.localizedDescription)")
        }
    }

    /// PNG bytes from the pasteboard; converts TIFF via NSBitmapImageRep
    /// when only TIFF is present (e.g. some screenshot paths).
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Debounced (0.5 s, per block) autosave for content edits. The view's
    /// bindings mutate `blocks` directly; this persists the latest value.
    func scheduleSave(_ block: NoteBlock) {
        guard let blockId = block.id else { return }
        let debouncer = blockDebouncers[blockId] ?? Debouncer(delay: 0.5)
        blockDebouncers[blockId] = debouncer
        debouncer.call { [weak self] in
            guard let self,
                  let current = self.blocks.first(where: { $0.id == blockId }) else { return }
            do {
                try self.store.updateBlock(current)
            } catch {
                Log.notes.error("save block failed: \(error.localizedDescription)")
            }
        }
    }

    /// direction: -1 moves the block up, +1 moves it down.
    func moveBlock(_ block: NoteBlock, direction: Int) {
        guard let noteId = selectedNoteId,
              let from = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let to = from + direction
        guard blocks.indices.contains(to) else { return }
        do {
            try store.moveBlock(noteId: noteId, fromIndex: from, toIndex: to)
            reloadBlocks()
        } catch {
            Log.notes.error("move block failed: \(error.localizedDescription)")
        }
    }

    func deleteBlock(_ block: NoteBlock) {
        guard let noteId = selectedNoteId, let id = block.id else { return }
        blockDebouncers[id]?.cancel()
        blockDebouncers[id] = nil
        do {
            try store.deleteBlock(id: id, noteId: noteId)
            reloadBlocks()
        } catch {
            Log.notes.error("delete block failed: \(error.localizedDescription)")
        }
    }

    /// Manual text↔code conversion (BlockImport never auto-detects code).
    func convertBlock(_ block: NoteBlock, to kind: BlockKind) {
        guard let id = block.id,
              let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        var updated = blocks[index]
        updated.kind = kind
        do {
            try store.updateBlock(updated)
            reloadBlocks()
        } catch {
            Log.notes.error("convert block failed: \(error.localizedDescription)")
        }
    }

    // MARK: Copy (the headline feature)

    /// ONE helper for every per-block Copy button. markInternal: false is
    /// DELIBERATE — this is a real user copy, so the Phase 4 clipboard-history
    /// watcher SHOULD record it. (markInternal: true is reserved for Fuse's
    /// invisible write/restore plumbing.)
    func copyBlock(_ block: NoteBlock) {
        let representation: PasteService.ItemRepresentation
        switch block.kind {
        case .image:
            guard let data = block.imageData else { return }
            representation = [NSPasteboard.PasteboardType.png: data]
        case .text, .code, .link:
            representation = [.string: Data(block.textContent.utf8)]
        }
        PasteService.write([representation], to: .general, markInternal: false)
    }

    func copySelectedNoteAsMarkdown() {
        let markdown = MarkdownExporter.markdown(title: noteTitle, blocks: blocks)
        PasteService.write([[.string: Data(markdown.utf8)]], to: .general, markInternal: false)
    }
}

// MARK: - Root view

struct NotesPanelView: View {
    @ObservedObject var model: NotesViewModel
    @State private var noteToDelete: Note?
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 380)
    }

    // MARK: Left column

    private var sidebar: some View {
        VStack(spacing: 8) {
            TextField("Search notes…", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(EdgeInsets(top: 10, leading: 8, bottom: 0, trailing: 8))
            Button {
                model.createNote()
            } label: {
                Label("New Note", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            if model.notes.isEmpty && model.searchText.isEmpty {
                Spacer()
                Button("Create your first note") { model.createNote() }
                Spacer()
            } else {
                List {
                    ForEach(model.notes) { note in
                        noteRow(note)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectNote(note.id) }
                            .listRowBackground(note.id == model.selectedNoteId
                                ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contextMenu {
                                Button(note.pinned ? "Unpin" : "Pin") { model.togglePin(note) }
                                Button("Delete…", role: .destructive) {
                                    noteToDelete = note
                                    showDeleteConfirmation = true
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .confirmationDialog(
                    "Delete this note?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible,
                    presenting: noteToDelete
                ) { note in
                    Button("Delete \"\(note.title.isEmpty ? "Untitled" : note.title)\"",
                           role: .destructive) {
                        model.deleteNote(note)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("The note and all of its blocks will be removed. This cannot be undone.")
                }
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled" : note.title).lineLimit(1)
                Text(note.updatedAt, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if note.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Right column

    @ViewBuilder
    private var detail: some View {
        if model.selectedNoteId == nil {
            VStack(spacing: 12) {
                Text(model.notes.isEmpty ? "No notes yet" : "Select a note")
                    .foregroundStyle(.secondary)
                if model.notes.isEmpty {
                    Button("Create your first note") { model.createNote() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                TextField("Untitled", text: Binding(
                    get: { model.noteTitle },
                    set: { model.setTitle($0) }))
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))
                Divider()
                ScrollView {
                    // Plain VStack (NOT LazyVStack): notes have few blocks, and
                    // lazy containers recycle TextEditors mid-edit.
                    VStack(spacing: 10) {
                        ForEach($model.blocks) { $block in
                            BlockView(block: $block, model: model)
                        }
                    }
                    .padding(12)
                }
                Divider()
                blockToolbar
            }
        }
    }

    private var blockToolbar: some View {
        HStack(spacing: 8) {
            Button("+ Text") { model.appendBlock(kind: .text) }
            Button("+ Code") { model.appendBlock(kind: .code) }
            Button("+ From Clipboard") { model.appendFromClipboard() }
            Spacer()
            Button("Copy as Markdown") { model.copySelectedNoteAsMarkdown() }
        }
        .padding(8)
    }
}

// MARK: - One block

struct BlockView: View {
    @Binding var block: NoteBlock
    @ObservedObject var model: NotesViewModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            controls
            content
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.gray.opacity(block.kind == .code ? 0.15 : 0.07)))
        .onHover { hovering = $0 }
        .onChange(of: block.textContent) { _, _ in model.scheduleSave(block) }
        .onChange(of: block.language) { _, _ in model.scheduleSave(block) }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Text(kindLabel).font(.caption2).foregroundStyle(.tertiary)
            if block.kind == .code {
                TextField("language", text: $block.language)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 120)
            }
            Spacer()
            if block.kind == .text || block.kind == .code {
                Menu {
                    Button("Text") { model.convertBlock(block, to: .text) }
                    Button("Code") { model.convertBlock(block, to: .code) }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
                .help("Convert between text and code")
            }
            Button { model.copyBlock(block) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy this block")
            Button { model.moveBlock(block, direction: -1) } label: { Image(systemName: "arrowtriangle.up.fill") }
                .buttonStyle(.borderless).help("Move up")
            Button { model.moveBlock(block, direction: 1) } label: { Image(systemName: "arrowtriangle.down.fill") }
                .buttonStyle(.borderless).help("Move down")
            Button { model.deleteBlock(block) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete block")
        }
        .opacity(hovering ? 1 : 0.35)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .text:
            TextEditor(text: $block.textContent)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
        case .code:
            TextEditor(text: $block.textContent)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
        case .image:
            if let data = block.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("Image unavailable").foregroundStyle(.secondary)
            }
        case .link:
            HStack {
                TextField("https://…", text: $block.textContent)
                    .textFieldStyle(.roundedBorder)
                if let url = URL(string: block.textContent),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private var kindLabel: String {
        switch block.kind {
        case .text: return "Text"
        case .code: return "Code"
        case .image: return "Image"
        case .link: return "Link"
        }
    }
}
```

- [x] **Step 2: Regenerate, build, test, commit**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
git add Sources/Notes/NotesPanelView.swift
git commit -m "feat(notes): block-based notes editor UI with per-block copy"
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **` (no new tests; the view is not reachable until Task 8.7 wires the controller).

---

### Task 8.7: NotesController + AppDelegate wiring (anchors)

**Files:**
- Create: `Sources/Notes/NotesController.swift`
- Modify: `Sources/App/AppDelegate.swift` (anchor inserts ONLY — change nothing else)

The controller owns the store (via `NoteStore.shared`), the view model, the lazily created panel, the `.toggleNotesPanel` hotkey, the Esc key monitor, and the auto-hide-on-resign-key rule (`"notes.panelPinned"`). If the store can't open, the feature stays inert: the hotkey and menu item still exist but show an alert.

- [x] **Step 1: Write `Sources/Notes/NotesController.swift`**

```swift
import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the notes feature: store, view model, panel, and the `.toggleNotesPanel`
/// hotkey (⌃⌥M, defined in Core/HotkeyNames.swift — NEVER define new Names).
final class NotesController {
    private let model: NotesViewModel?
    private var panel: NotesPanel?
    private var escMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        UserDefaults.standard.register(defaults: ["notes.panelPinned": false])
        if let store = NoteStore.shared {
            self.model = NotesViewModel(store: store)
        } else {
            // Feature inert: menu item/hotkey remain, toggle() shows an alert.
            Log.notes.error("notes store unavailable — feature inert")
            self.model = nil
        }
    }

    func start() {
        // The ONLY hotkey this feature uses.
        KeyboardShortcuts.onKeyDown(for: .toggleNotesPanel) { [weak self] in
            self?.toggle()
        }
    }

    /// Target of the "Notes" status-bar menu item (wired in AppDelegate).
    @objc func toggleFromMenu() {
        toggle()
    }

    func toggle() {
        guard let model else {
            showStoreUnavailableAlert()
            return
        }
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel(model: model)
        }
    }

    private func showPanel(model: NotesViewModel) {
        let panel = ensurePanel(model: model)
        model.reloadAll()
        panel.centerOnMouseScreen()
        // Non-activating: NO NSApp.activate — the previous app stays active.
        panel.makeKeyAndOrderFront(nil)
        installEscMonitor()
    }

    private func hidePanel() {
        removeEscMonitor()
        panel?.orderOut(nil)
    }

    private func ensurePanel(model: NotesViewModel) -> NotesPanel {
        if let panel { return panel }
        let newPanel = NotesPanel()
        newPanel.contentView = NSHostingView(rootView: NotesPanelView(model: model))
        // Auto-hide when the panel loses key status — unless the user pinned
        // it ("notes.panelPinned", settable in the Notes settings tab).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: newPanel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !UserDefaults.standard.bool(forKey: "notes.panelPinned") {
                self.hidePanel()
            }
        }
        panel = newPanel
        return newPanel
    }

    /// Esc (keyCode 53) hides the panel while it is the key window; the event
    /// is swallowed (return nil). EVERY other event is returned untouched so
    /// all typing reaches the SwiftUI text editors.
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel,
                  panel.isKeyWindow, event.keyCode == 53 else { return event }
            self.hidePanel()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    private func showStoreUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Notes unavailable"
        alert.informativeText = "Fuse could not open its notes database. "
            + "Check Console logs (subsystem com.rgv250cc.Fuse, category notes)."
        alert.alertStyle = .warning
        alert.runModal()
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        removeEscMonitor()
    }
}
```

- [x] **Step 2: Wire into `Sources/App/AppDelegate.swift`** — three anchor edits, nothing else.

ORDERING WARNING (do not "simplify" this away): inside Phase 0's `applicationDidFinishLaunching`, the `// FUSE:MENU-ITEMS` anchor executes BEFORE `// FUSE:CONTROLLER-START`. The controller does not exist yet while the menu is being built, so a `target = notesController` assignment at MENU-ITEMS would assign nil and the menu item would stay permanently disabled. Solution (the same pattern other phases use): hold the menu item in a property at MENU-ITEMS, then assign its `target` AND `action` at CONTROLLER-START, right after constructing the controller.

Edit 1 — find the line containing exactly `// FUSE:CONTROLLER-PROPS` and insert two lines ABOVE it (keep the anchor line and everything already above it), so the file reads:

```swift
    private var notesController: NotesController!
    private var notesMenuItem: NSMenuItem!
    // FUSE:CONTROLLER-PROPS
```

Edit 2 — find the line containing exactly `// FUSE:MENU-ITEMS` and insert two lines ABOVE it (keep the anchor line), so the file reads:

```swift
        notesMenuItem = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        menu.addItem(notesMenuItem)
        // FUSE:MENU-ITEMS
```

Edit 3 — find the line containing exactly `// FUSE:CONTROLLER-START` and insert four lines ABOVE it (keep the anchor line), so the file reads:

```swift
        notesController = NotesController()
        notesController.start()
        notesMenuItem.target = notesController
        notesMenuItem.action = #selector(NotesController.toggleFromMenu)
        // FUSE:CONTROLLER-START
```

(NSMenu only enables an item once it has both a target and an action — assigning both here, after construction, is what makes the "Notes" item clickable. The `XCTestCase` guard at the top of `applicationDidFinishLaunching` keeps all of this off during hosted test runs — do not remove it.)

- [x] **Step 3: Regenerate, build, test**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — panel behavior, blocks, per-block copy, persistence**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to perform ALL of the following and report each result. STOP and debug any failure before Task 8.8.

1. **Toggle + non-activation:** focus TextEdit, press ⌃⌥M — the notes panel appears centered on the mouse's screen, and TextEdit's name STAYS in the menu bar (Fuse never becomes the active app). Pressing ⌃⌥M again hides the panel. The status-bar menu's "Notes" item does the same toggle.
2. **Full-screen:** put Safari into full screen, press ⌃⌥M — the panel appears ON TOP of the full-screen app without switching Spaces.
3. **First note:** click "Create your first note" (or "New Note"). A note appears with one empty text block. Type a title and some text into the block.
4. **Code block:** click "+ Code", type `print("hello")` into it, type `swift` into its language field.
5. **Image block:** press ⇧⌃⌘4, drag a region (screenshot lands on the clipboard), click "+ From Clipboard" — an image block appears showing the screenshot.
6. **Link block:** copy `https://example.com` (⌘C from any app), click "+ From Clipboard" — a link block appears with an "Open" button; clicking "Open" opens the browser.
7. **Per-block copy (headline feature):** click the Copy button on the CODE block, then ⌘V into TextEdit — ONLY `print("hello")` pastes (no title, no other blocks). If Phase 4 is installed: press ⇧⌘V — the snippet appears in the clipboard-history picker (the deliberate-copy `markInternal: false` cross-feature check).
8. **Reorder/delete:** ▲/▼ move a block up/down; the trash button removes a block.
9. **Esc:** with the panel key, press Esc — the panel hides; typing Esc must NOT reach the app behind.
10. **Persistence:** press ⌃⌥M — everything (title, all four blocks, order) is exactly as left. Then `pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app`, press ⌃⌥M — still all there.
11. **Auto-hide (unpinned default):** with the panel open, click any other app's window — the panel hides by itself.
12. **Search by block content:** reopen, type a word that exists only inside the code block into the search field — the note stays listed; type garbage — the list empties.
13. **Delete note:** right-click the note in the sidebar → "Delete…" — a confirmation appears naming the note; confirming removes it.

- [x] **Step 5: Commit**

```bash
git add Sources/Notes/NotesController.swift Sources/App/AppDelegate.swift
git commit -m "feat(notes): controller wiring, toggle hotkey, and status-bar menu item"
```

---

### Task 8.8: Notes settings tab — recorder, pinning, storage info, export-all

**Files:**
- Create: `Sources/Notes/NotesSettingsView.swift`
- Modify: `Sources/App/SettingsRootView.swift` (anchor insert ONLY)

- [x] **Step 1: Write `Sources/Notes/NotesSettingsView.swift`**

```swift
import AppKit
import KeyboardShortcuts
import SwiftUI

struct NotesSettingsView: View {
    @AppStorage("notes.panelPinned") private var panelPinned = false
    @State private var noteCount: Int?
    @State private var dbSize: String?
    @State private var exportResult: String?

    var body: some View {
        Form {
            Section("Quick Notes") {
                KeyboardShortcuts.Recorder("Toggle notes panel", name: .toggleNotesPanel)
                Toggle("Keep panel open when it loses focus", isOn: $panelPinned)
            }
            Section("Storage") {
                LabeledContent("Notes", value: noteCount.map(String.init) ?? "–")
                LabeledContent("Database size", value: dbSize ?? "–")
            }
            Section("Export") {
                Button("Export all notes as Markdown…") { exportAll() }
                if let exportResult {
                    Text(exportResult).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: loadInfo)
    }

    /// Read once on appear (not on a timer): note count via the shared store,
    /// file size via FileManager + ByteCountFormatter.
    private func loadInfo() {
        if let store = NoteStore.shared {
            noteCount = (try? store.notes(matching: nil))?.count
        } else {
            noteCount = nil
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: NoteStore.onDiskPath),
           let size = attrs[.size] as? Int64 {
            dbSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } else {
            dbSize = nil
        }
    }

    /// Writes one `<sanitized-title-or-Untitled>-<id>.md` per note into a
    /// user-chosen folder. Sanitizing replaces "/" and ":" with "-".
    private func exportAll() {
        guard let store = NoteStore.shared else {
            exportResult = "Notes database unavailable."
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Export"
        openPanel.message = "Choose a folder for the exported Markdown files"
        guard openPanel.runModal() == .OK, let directory = openPanel.url else { return }
        do {
            let notes = try store.notes(matching: nil)
            var written = 0
            for note in notes {
                guard let id = note.id else { continue }
                let blocks = try store.blocks(forNote: id)
                let markdown = MarkdownExporter.markdown(title: note.title, blocks: blocks)
                let base = note.title.isEmpty ? "Untitled" : note.title
                let sanitized = base
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let url = directory.appendingPathComponent("\(sanitized)-\(id).md")
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                written += 1
            }
            exportResult = "Exported \(written) note\(written == 1 ? "" : "s")."
        } catch {
            Log.notes.error("export failed: \(error.localizedDescription)")
            exportResult = "Export failed: \(error.localizedDescription)"
        }
    }
}
```

- [x] **Step 2: Wire into `Sources/App/SettingsRootView.swift`** — one anchor edit, nothing else.

Find the line containing exactly `// FUSE:SETTINGS_TABS` and insert two lines ABOVE it (keep the anchor line), so the file reads:

```swift
            NotesSettingsView()
                .tabItem { Label("Notes", systemImage: "note.text") }
            // FUSE:SETTINGS_TABS
```

- [x] **Step 3: Regenerate, build, test**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — settings tab, pinned mode, export-all**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to perform ALL of the following and report each result.

1. **Tab:** status-bar menu → Settings… → a "Notes" tab exists; it shows the ⌃⌥M recorder, the pin toggle, a note count matching reality, and a non-zero database size.
2. **Pinned mode:** turn ON "Keep panel open when it loses focus". Open the panel (⌃⌥M), click another app's window — the panel STAYS visible. Turn the toggle OFF, click away again — the panel hides.
3. **Recorder:** record a different shortcut (e.g. ⌃⌥J), confirm it toggles the panel; then record ⌃⌥M back.
4. **Export-all:** click "Export all notes as Markdown…", pick a scratch folder. The inline text reports the exported count; the folder contains one `.md` per note named `<title-or-Untitled>-<id>.md`; opening the file for the test note shows the `# title` heading, the text, a fenced ```swift code block, the `<https://…>` autolink, and the image placeholder line.
5. **Copy as Markdown:** in the panel, click "Copy as Markdown", paste into TextEdit (as plain text) — same Markdown shape as the exported file.

- [x] **Step 5: Commit**

```bash
git add Sources/Notes/NotesSettingsView.swift Sources/App/SettingsRootView.swift
git commit -m "feat(notes): settings tab with hotkey recorder, pinning, and Markdown export"
```

---

## Manual verification checklist (end of phase)

- [ ] **HUMAN-VERIFY** ⌃⌥M opens the panel over a full-screen app without switching Spaces; the previous app stays active-looking; ⌃⌥M and the "Notes" menu item both toggle it.
- [ ] **HUMAN-VERIFY** A note holds all four block kinds: typed text, a code block with language "swift", a screenshot imported via "+ From Clipboard" (⇧⌃⌘4 region first), and a link block with a working "Open" button.
- [ ] **HUMAN-VERIFY** Per-block Copy of the code block → ⌘V in TextEdit pastes ONLY the code, AND (if Phase 4 is installed) the snippet appears in the ⇧⌘V clipboard-history picker.
- [ ] **HUMAN-VERIFY** Esc hides the panel; ⌃⌥M re-opens it with everything persisted — including after `pkill -x Fuse` and relaunch.
- [ ] **HUMAN-VERIFY** Unpinned panel auto-hides when clicking another app; with "Keep panel open when it loses focus" ON it stays.
- [ ] **HUMAN-VERIFY** Search finds a note by text that exists only inside a code block.
- [ ] **HUMAN-VERIFY** "Copy as Markdown" → paste shows the fenced code block; settings "Export all notes as Markdown…" writes one `.md` file per note and reports the count inline.
- [ ] **HUMAN-VERIFY** Deleting a note asks for confirmation and removes the note with all its blocks (cascade).
- [x] All unit tests green: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20` → `** TEST SUCCEEDED **` (21 new tests: 9 NoteStore + 4 MarkdownExporter + 8 BlockImport).
- [x] `git log --oneline | head -8` shows the eight Phase 8 commits on top.

## Risks & gotchas

- **The em dash in the image placeholder.** `"> *[image block — not exported]*"` uses U+2014 in BOTH `MarkdownExporter.swift` and `MarkdownExporterTests.swift`. Retyping it as a hyphen makes the test fail with two visually near-identical strings. Copy both from this plan.
- **Lenient `URL(string:)` on macOS 14+.** Foundation now percent-encodes invalid characters instead of returning nil, so `URL(string: "https://a.com and more")` can succeed. `BlockImport.isHTTPURL` checks for whitespace BEFORE constructing the URL — keep that ordering.
- **GRDB date precision is milliseconds.** Tests that depend on `updatedAt` ordering sleep 10 ms between inserts (`makeNote` helper). Do not remove the sleeps to "speed up" tests; ordering becomes flaky.
- **Foreign keys are ON by default in GRDB.** The cascade test passes without any `PRAGMA foreign_keys` — do not add pragmas.
- **Debounced saves lose ≤0.5 s of typing if the app dies instantly.** Title and block edits persist 0.5 s after the last keystroke. A `pkill -x Fuse` within that window loses the last keystrokes — known, accepted; structural changes (add/move/delete/convert/import) write immediately.
- **Non-activating panel + resign-key re-entrancy.** Hiding the panel (Esc or toggle) makes it resign key, which fires the `didResignKeyNotification` observer, which calls `hidePanel()` again. Both `removeEscMonitor()` and `orderOut(nil)` are idempotent, so this is harmless — do not "fix" it with flags.
- **The Esc monitor checks `panel.isKeyWindow`, not `isVisible`.** This keeps Esc working normally in the Fuse settings window while a pinned panel floats unfocused. The monitor returns every non-Esc event untouched so typing reaches the SwiftUI editors.
- **`TextEditor` inside `ScrollView` nested scrolling.** Each block editor has its own scroll gesture; with `minHeight: 60` and short content this is acceptable. Do not replace the outer `ScrollView` with `List` (row recycling breaks `TextEditor` focus) and keep the inner container a plain `VStack`, not `LazyVStack`.
- **Two stores, one file — avoided by `NoteStore.shared`.** The controller and the settings tab MUST use the single shared instance (same pattern as `ClipboardStore.shared` in Phase 4). Never call `NoteStore.onDisk()` a second time at runtime.
- **MENU-ITEMS runs before CONTROLLER-START.** The "Notes" menu item is created with `action: nil` and only becomes clickable when Task 8.7 Edit 3 assigns `target` + `action` after the controller exists. If the item appears grayed out, that assignment is missing or misplaced.
- **No Accessibility permission needed for this phase.** KeyboardShortcuts uses Carbon hotkeys and the Copy buttons only write the pasteboard. If the hotkey does nothing, check for a conflicting ⌃⌥M binding in another app, not permissions.
- **Hosted unit tests launch the real app.** The `XCTestCase` guard in `applicationDidFinishLaunching` (Phase 0) keeps `NotesController` from starting during test runs. Keep it.

## Deviations

- None. All code compiled against GRDB as written in the plan (no API drift); the em dash placeholder (U+2014) was copied byte-for-byte into both `MarkdownExporter.swift` and `MarkdownExporterTests.swift` and verified via hexdump (`e2 80 94`).
- All HUMAN-VERIFY steps (Task 8.7 Step 4, Task 8.8 Step 4, and the end-of-phase manual checklist) were SKIPPED — no human available in this execution environment; the app was never launched. These remain unticked for the integrator.
