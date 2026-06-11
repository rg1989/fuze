# Phase 4: Smart Clipboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–1 complete.

**Goal:** A Maccy/Paste-class clipboard history: a polling pasteboard watcher persists everything the user copies (text, RTF, HTML, images, file references, links) losslessly into a GRDB/SQLite store with previews, thumbnails, dedupe, pinning, and pruning; a ⇧⌘V non-activating picker panel lets the user search and re-paste any item into the frontmost app via `PasteService`, restoring the previous clipboard afterwards; a Clipboard settings tab controls it all.

**Architecture:** Everything lives in `Sources/Clipboard/`. Pure logic (`ClipboardStore`, `CaptureClassifier`, thumbnail scaling) is TDD'd against in-memory databases and plain values. OS-integration code (`PasteboardWatcher` polling `NSPasteboard.general`, the `NSPanel` picker, hotkey wiring) is built, then human-verified. Shared files are touched ONLY at the two `// FUSE:CONTROLLER-*` anchors in `AppDelegate.swift` and the `// FUSE:SETTINGS_TABS` anchor in `SettingsRootView.swift`.

**Tech Stack:** Swift 5.10, AppKit + SwiftUI, GRDB 6 (`DatabaseQueue`, `DatabaseMigrator`, Codable records), CryptoKit (SHA-256 hashing), KeyboardShortcuts 2.x (`.pastePicker` hotkey + recorder), XCTest.

---

## Context recap (the implementer must know this — do not skip)

Core APIs consumed (Phase 1, `Sources/Core/` — never redefine):

```swift
PasteService.fuseInternalMarker        // NSPasteboard.PasteboardType("com.rgv250cc.fuse.internal")
PasteService.ItemRepresentation        // typealias [NSPasteboard.PasteboardType: Data]
PasteService.paste(_ items: [PasteService.ItemRepresentation], restoreAfter seconds: Double)
PasteService.snapshot(of pasteboard: NSPasteboard) -> [PasteService.ItemRepresentation]
PermissionsService.hasAccessibility / .promptForAccessibility() / .openSystemSettings(pane: .accessibility)
Log.clipboard                          // os.Logger for this feature
KeyboardShortcuts.Name.pastePicker     // default ⇧⌘V — the ONLY hotkey this phase uses
```

Everything Fuse writes to the general pasteboard (paste-writes AND restore-writes) carries `fuseInternalMarker`. **Our watcher MUST skip pasteboard contents carrying that type**, or Fuse captures its own writes in an infinite loop. NEVER define a new `KeyboardShortcuts.Name` — use only `.pastePicker`.

Settings keys (master §6.4): `"clipboard.enabled"` (Bool, default true), `"clipboard.maxItems"` (Int, default 500). Database: `~/Library/Application Support/Fuse/clipboard.sqlite`; tests use `try DatabaseQueue()` (in-memory).

Commands used throughout (run from `/Users/rgv250cc/Documents/Projects/Fuse`):

```bash
xcodegen generate     # after EVERY file create/delete, BEFORE building
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5   # expect ** BUILD SUCCEEDED **
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20                       # expect ** TEST SUCCEEDED **
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app    # run the app
```

New files: `Sources/Clipboard/{ClipboardItem,ClipboardStore,PasteboardWatcher,ClipboardController,PastePickerPanel,PastePickerView,ClipboardSettingsView}.swift`, tests `Tests/FuseTests/{ClipboardStoreTests,PasteboardCaptureTests}.swift`.

---

### Task 4.0: Preflight

**Files:** none (verification only).

- [ ] **Step 1: Verify Phase 1 files and anchors exist**

```bash
ls Sources/Core
grep -c "FUSE:CONTROLLER-PROPS\|FUSE:CONTROLLER-START" Sources/App/AppDelegate.swift
grep -c "FUSE:SETTINGS_TABS" Sources/App/SettingsRootView.swift
```
Expected: `ls` lists all of `AX.swift HotkeyNames.swift Log.swift PasteService.swift Permissions.swift`; the greps print `2` and `1`. If anything is missing, STOP — Phases 0–1 are incomplete.

- [ ] **Step 2: Verify build and tests are green before touching anything**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`. If red, STOP and fix before starting this phase.

---

### Task 4.1: Data model + ClipboardStore (TDD)

**Files:**
- Create: `Sources/Clipboard/ClipboardItem.swift`
- Create: `Sources/Clipboard/ClipboardStore.swift`
- Test: `Tests/FuseTests/ClipboardStoreTests.swift`

Two tables: `clipboardItem` (one row per distinct copied thing; UNIQUE `contentHash` for dedupe) and `itemRepresentation` (every raw pasteboard representation, so a paste is lossless — ALL stored representations get re-written).

- [ ] **Step 1: Write the failing tests — `Tests/FuseTests/ClipboardStoreTests.swift`**

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'ClipboardStore' in scope` (compile failure is this step's "red").

- [ ] **Step 3: Write `Sources/Clipboard/ClipboardItem.swift`**

```swift
import Foundation
import GRDB

/// One captured clipboard entry. `preview` is what the picker shows; the
/// lossless raw payload lives in the `itemRepresentation` table.
struct ClipboardItem: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clipboardItem"
    var id: Int64?
    var createdAt: Date
    var kind: String          // "text" | "link" | "image" | "file" | "rtf" | "other"
    var preview: String       // first 200 chars / URL / file names / "Image WxH"
    var thumbnail: Data?      // ≤200 px PNG for images, else nil
    var sourceApp: String?    // frontmost app bundle id at capture time
    var contentHash: String   // SHA-256 over all representations (UNIQUE)
    var pinned: Bool

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One raw pasteboard representation (UTI string + bytes) of a ClipboardItem.
/// Named ...Record to avoid confusion with PasteService.ItemRepresentation.
struct ItemRepresentationRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "itemRepresentation"
    var id: Int64?
    var itemId: Int64         // references clipboardItem.id, ON DELETE CASCADE
    var type: String          // raw NSPasteboard.PasteboardType string
    var data: Data

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

- [ ] **Step 4: Write `Sources/Clipboard/ClipboardStore.swift`**

```swift
import CryptoKit
import Foundation
import GRDB

/// SQLite-backed clipboard history. Thread-safe: DatabaseQueue serializes access.
final class ClipboardStore {
    /// App-wide instance. The controller AND the settings tab must both use this
    /// single instance — never open a second connection to the same file.
    static let shared: ClipboardStore? = try? ClipboardStore.onDisk()

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    static func onDisk() throws -> ClipboardStore {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Fuse", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ClipboardStore(dbQueue: DatabaseQueue(path: dir.appendingPathComponent("clipboard.sqlite").path))
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clipboardItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("preview", .text).notNull()
                t.column("thumbnail", .blob)
                t.column("sourceApp", .text)
                t.column("contentHash", .text).notNull().unique()   // unique() creates the index
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "itemRepresentation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("itemId", .integer).notNull().references("clipboardItem", onDelete: .cascade).indexed()
                t.column("type", .text).notNull()
                t.column("data", .blob).notNull()
            }
        }
        return migrator
    }

    /// SHA-256 over (typeUTF8 + data) of every representation, sorted by type
    /// string, so the hash is independent of representation order.
    static func hash(representations: [(type: String, data: Data)]) -> String {
        var hasher = SHA256()
        for rep in representations.sorted(by: { $0.type < $1.type }) {
            hasher.update(data: Data(rep.type.utf8))
            hasher.update(data: rep.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// If `contentHash` already exists: bump that row's createdAt to now
    /// (bubbles to top) and return the existing id — no duplicate row.
    @discardableResult
    func save(kind: String, preview: String, thumbnail: Data?, sourceApp: String?,
              contentHash: String, representations: [(type: String, data: Data)]) throws -> Int64 {
        try dbQueue.write { db in
            if var existing = try ClipboardItem.filter(Column("contentHash") == contentHash).fetchOne(db) {
                existing.createdAt = Date()
                try existing.update(db)
                return existing.id!
            }
            var item = ClipboardItem(id: nil, createdAt: Date(), kind: kind, preview: preview,
                                     thumbnail: thumbnail, sourceApp: sourceApp,
                                     contentHash: contentHash, pinned: false)
            try item.insert(db)
            for rep in representations {
                var record = ItemRepresentationRecord(id: nil, itemId: item.id!, type: rep.type, data: rep.data)
                try record.insert(db)
            }
            return item.id!
        }
    }

    /// Newest first. `query` filters with case-insensitive LIKE on `preview`.
    func recentItems(limit: Int, matching query: String? = nil) throws -> [ClipboardItem] {
        try dbQueue.read { db in
            var request = ClipboardItem.all()
            if let query, !query.isEmpty {
                request = request.filter(sql: "preview LIKE ?", arguments: ["%\(query)%"])
            }
            return try request.order(Column("createdAt").desc, Column("id").desc).limit(limit).fetchAll(db)
        }
    }

    func representations(forItem id: Int64) throws -> [(type: String, data: Data)] {
        try dbQueue.read { db in
            try ItemRepresentationRecord.filter(Column("itemId") == id).order(Column("id"))
                .fetchAll(db).map { (type: $0.type, data: $0.data) }
        }
    }

    func togglePin(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clipboardItem SET pinned = NOT pinned WHERE id = ?", arguments: [id])
        }
    }

    func delete(id: Int64) throws {
        _ = try dbQueue.write { db in try ClipboardItem.deleteOne(db, key: id) }
    }

    func deleteAllUnpinned() throws {
        _ = try dbQueue.write { db in try ClipboardItem.filter(Column("pinned") == false).deleteAll(db) }
    }

    /// Keeps the newest `maxItems` UNPINNED items; pinned items always survive.
    func prune(keeping maxItems: Int) throws {
        try dbQueue.write { db in
            let staleIds = try Int64.fetchAll(db, sql: """
                SELECT id FROM clipboardItem WHERE pinned = 0
                ORDER BY createdAt DESC, id DESC LIMIT -1 OFFSET ?
                """, arguments: [maxItems])
            guard !staleIds.isEmpty else { return }
            _ = try ClipboardItem.filter(staleIds.contains(Column("id"))).deleteAll(db)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, all 9 `ClipboardStoreTests` passed. (Hosted tests launch Fuse.app, but the `XCTestCase` guard in `applicationDidFinishLaunching` keeps all controllers/watchers off during test runs.)

- [ ] **Step 6: Commit**

```bash
git add Sources/Clipboard/ClipboardItem.swift Sources/Clipboard/ClipboardStore.swift Tests/FuseTests/ClipboardStoreTests.swift
git commit -m "feat(clipboard): GRDB store with dedupe, search, pinning, and pruning"
```

---

### Task 4.2: Capture decision logic — CaptureClassifier (TDD)

**Files:**
- Create: `Sources/Clipboard/PasteboardWatcher.swift` (classifier only; Task 4.3 appends the watcher class to this same file)
- Test: `Tests/FuseTests/PasteboardCaptureTests.swift`

Pure functions: should a pasteboard change be captured at all, and as what (kind, preview)? Priority: file > image > rtf > link > text.

- [ ] **Step 1: Write the failing tests — `Tests/FuseTests/PasteboardCaptureTests.swift`**

```swift
import AppKit
import XCTest
@testable import Fuse

final class PasteboardCaptureTests: XCTestCase {
    private func classify(_ types: Set<String>, _ s: String? = nil,
                          files: [URL] = [], px: CGSize? = nil) -> (kind: String, preview: String) {
        CaptureClassifier.classify(types: types, plainString: s, fileURLs: files, imagePixelSize: px)
    }

    func testShouldCaptureRejectsForbiddenAndEmptyTypes() {
        XCTAssertTrue(CaptureClassifier.shouldCapture(types: ["public.utf8-plain-text", "public.html"]))
        XCTAssertFalse(CaptureClassifier.shouldCapture(types: []))
        let forbidden = ["org.nspasteboard.ConcealedType",      // password managers
                         "org.nspasteboard.TransientType",
                         "org.nspasteboard.AutoGeneratedType",
                         PasteService.fuseInternalMarker.rawValue]  // Fuse's own writes — loop guard
        for bad in forbidden {
            XCTAssertFalse(CaptureClassifier.shouldCapture(types: ["public.utf8-plain-text", bad]), bad)
        }
    }

    func testClassifyFileBeatsEverythingAndJoinsNames() {
        let one = classify(["public.file-url", "public.png", "public.utf8-plain-text"], "/tmp/a.png",
                           files: [URL(fileURLWithPath: "/tmp/a.png")], px: CGSize(width: 9, height: 9))
        XCTAssertEqual(one.kind, "file")
        XCTAssertEqual(one.preview, "a.png")
        let two = classify(["public.file-url"],
                           files: [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")])
        XCTAssertEqual(two.preview, "a.txt, b.txt")
    }

    func testClassifyImageWithAndWithoutPixelSize() {
        let sized = classify(["public.png", "public.tiff"], px: CGSize(width: 800, height: 600))
        XCTAssertEqual(sized.kind, "image")
        XCTAssertEqual(sized.preview, "Image 800x600")
        let unsized = classify(["public.tiff"])
        XCTAssertEqual(unsized.kind, "image")
        XCTAssertEqual(unsized.preview, "Image")
    }

    func testClassifyRTFUsesPlainStringPreview() {
        let result = classify(["public.rtf", "public.utf8-plain-text"], "styled words")
        XCTAssertEqual(result.kind, "rtf")
        XCTAssertEqual(result.preview, "styled words")
    }

    func testClassifyLinkRequiresHttpSchemeAndHost() {
        let https = classify(["public.utf8-plain-text"], "https://example.com/page?x=1")
        XCTAssertEqual(https.kind, "link")
        XCTAssertEqual(https.preview, "https://example.com/page?x=1")
        let padded = classify(["public.utf8-plain-text"], "  http://example.com\n")
        XCTAssertEqual(padded.kind, "link")
        XCTAssertEqual(padded.preview, "http://example.com")   // preview is the trimmed URL
    }

    func testClassifyNonLinksFallBackToText() {
        XCTAssertEqual(classify(["public.utf8-plain-text"], "ftp://example.com/file").kind, "text")
        XCTAssertEqual(classify(["public.utf8-plain-text"], "see https://example.com for details").kind, "text")
        XCTAssertEqual(classify(["public.utf8-plain-text"], "plain words").kind, "text")
    }

    func testClassifyTextTruncatesPreviewTo200Chars() {
        let result = classify(["public.utf8-plain-text"], String(repeating: "x", count: 500))
        XCTAssertEqual(result.kind, "text")
        XCTAssertEqual(result.preview.count, 200)
    }

    func testClassifyUnknownTypesFallBackToOther() {
        let result = classify(["com.example.custom"])
        XCTAssertEqual(result.kind, "other")
        XCTAssertEqual(result.preview, "com.example.custom")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'CaptureClassifier' in scope`.

- [ ] **Step 3: Write `Sources/Clipboard/PasteboardWatcher.swift`** (classifier only at this point)

```swift
import AppKit

/// Pure decision logic: should a pasteboard change be captured, and as what?
/// No NSPasteboard access in here — fully unit-tested in PasteboardCaptureTests.
enum CaptureClassifier {
    /// Type strings whose presence means "never capture". First three are the
    /// nspasteboard.org conventions (password managers, transient content);
    /// the last is Fuse's own marker — skipping it prevents an infinite capture
    /// loop when PasteService writes or restores the clipboard.
    static let forbiddenTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        PasteService.fuseInternalMarker.rawValue,   // "com.rgv250cc.fuse.internal"
    ]

    /// Types present on the pasteboard -> should we capture at all?
    static func shouldCapture(types: Set<String>) -> Bool {
        guard !types.isEmpty else { return false }
        return types.isDisjoint(with: forbiddenTypes)
    }

    /// Map available types + plain string to (kind, preview).
    /// Priority: file > image > rtf > link > text.
    static func classify(types: Set<String>, plainString: String?, fileURLs: [URL],
                         imagePixelSize: CGSize?) -> (kind: String, preview: String) {
        if !fileURLs.isEmpty {
            let names = fileURLs.map(\.lastPathComponent).joined(separator: ", ")
            return ("file", String(names.prefix(200)))
        }
        if types.contains("public.png") || types.contains("public.tiff") {
            if let size = imagePixelSize {
                return ("image", "Image \(Int(size.width))x\(Int(size.height))")
            }
            return ("image", "Image")
        }
        if types.contains("public.rtf") {
            return ("rtf", String((plainString ?? "RTF text").prefix(200)))
        }
        if let plainString {
            let trimmed = plainString.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLink(trimmed) { return ("link", String(trimmed.prefix(200))) }
            return ("text", String(plainString.prefix(200)))
        }
        return ("other", types.sorted().first ?? "unknown")
    }

    /// A "link" is a single token that parses as an http/https URL with a host.
    private static func isLink(_ s: String) -> Bool {
        guard !s.isEmpty,
              s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return false }
        return true
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, all 8 `PasteboardCaptureTests` passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clipboard/PasteboardWatcher.swift Tests/FuseTests/PasteboardCaptureTests.swift
git commit -m "feat(clipboard): pure capture classifier for pasteboard contents"
```

---

### Task 4.3: PasteboardWatcher (polling, allowlist, thumbnails)

**Files:**
- Modify: `Sources/Clipboard/PasteboardWatcher.swift` (append the watcher class; keep `CaptureClassifier` from Task 4.2 unchanged at the top)
- Modify: `Tests/FuseTests/PasteboardCaptureTests.swift` (add one thumbnail test)

macOS has **no** pasteboard-change notification. Polling `NSPasteboard.general.changeCount` on a 0.3 s timer is the standard technique (Maccy et al.). The thumbnail scaler is unit-tested; the live capture path is human-verified in Task 4.5 once the controller wires it up.

- [ ] **Step 1: Add the failing thumbnail test** — inside the `final class PasteboardCaptureTests` body in `Tests/FuseTests/PasteboardCaptureTests.swift`, immediately before the class's closing brace, add:

```swift
    func testThumbnailScalesLongestSideTo200AndNeverUpscales() throws {
        func solidImage(_ w: CGFloat, _ h: CGFloat) -> NSImage {
            let image = NSImage(size: NSSize(width: w, height: h))
            image.lockFocus()
            NSColor.systemRed.setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            image.unlockFocus()
            return image
        }
        let big = try XCTUnwrap(NSImage(data: XCTUnwrap(
            PasteboardWatcher.thumbnailPNG(from: solidImage(400, 100), maxSide: 200))))
        XCTAssertEqual(big.size.width, 200, accuracy: 2)
        XCTAssertEqual(big.size.height, 50, accuracy: 2)
        let small = try XCTUnwrap(NSImage(data: XCTUnwrap(
            PasteboardWatcher.thumbnailPNG(from: solidImage(80, 60), maxSide: 200))))
        XCTAssertEqual(small.size.width, 80, accuracy: 2)   // no upscaling
        XCTAssertEqual(small.size.height, 60, accuracy: 2)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'PasteboardWatcher' in scope`.

- [ ] **Step 3: Append the watcher class** to the END of `Sources/Clipboard/PasteboardWatcher.swift`, after the closing brace of `CaptureClassifier` (change nothing above it):

```swift

/// Polls NSPasteboard.general every 0.3 s and persists changes to ClipboardStore.
/// Respects the "clipboard.enabled" UserDefaults key. start()/stop() control it.
final class PasteboardWatcher {
    /// Bounded allowlist of representation types we persist (plus the item's
    /// own first — highest-fidelity — type, added per capture).
    static let allowedTypes: Set<String> = [
        "public.utf8-plain-text", "public.rtf", "public.html",
        "public.png", "public.tiff", "public.file-url",
    ]
    static let maxItemBytes = 10 * 1024 * 1024   // skip items above 10 MB total

    private let store: ClipboardStore
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int

    init(store: ClipboardStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount   // never capture pre-existing content
        let t = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 0.1
        timer = t
        Log.clipboard.info("pasteboard watcher started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard UserDefaults.standard.bool(forKey: "clipboard.enabled") else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        capture()
    }

    private func capture() {
        let typeStrings = Set((pasteboard.types ?? []).map(\.rawValue))
        guard CaptureClassifier.shouldCapture(types: typeStrings) else {
            Log.clipboard.debug("skipping pasteboard change (concealed/transient/internal)")
            return
        }
        guard let firstItem = pasteboard.pasteboardItems?.first else { return }

        // Representations from the first pasteboard item, bounded by the allowlist
        // plus that item's first (highest-fidelity) type. Skip oversized items.
        var wanted = Self.allowedTypes
        if let firstType = firstItem.types.first { wanted.insert(firstType.rawValue) }
        var representations: [(type: String, data: Data)] = []
        var totalBytes = 0
        for type in firstItem.types where wanted.contains(type.rawValue) {
            guard let data = firstItem.data(forType: type) else { continue }
            totalBytes += data.count
            representations.append((type: type.rawValue, data: data))
        }
        guard !representations.isEmpty else { return }
        guard totalBytes <= Self.maxItemBytes else {
            Log.clipboard.info("skipping oversized clipboard item (\(totalBytes) bytes)")
            return
        }

        let plainString = pasteboard.string(forType: .string)
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var imagePixelSize: CGSize?
        var thumbnail: Data?
        if typeStrings.contains("public.png") || typeStrings.contains("public.tiff") {
            let imageData = firstItem.data(forType: NSPasteboard.PasteboardType("public.png"))
                ?? firstItem.data(forType: NSPasteboard.PasteboardType("public.tiff"))
            if let imageData, let image = NSImage(data: imageData) {
                if let rep = image.representations.first {
                    imagePixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                }
                thumbnail = Self.thumbnailPNG(from: image, maxSide: 200)
            }
        }

        let (kind, preview) = CaptureClassifier.classify(types: typeStrings, plainString: plainString,
                                                         fileURLs: fileURLs, imagePixelSize: imagePixelSize)
        do {
            try store.save(kind: kind, preview: preview, thumbnail: thumbnail,
                           sourceApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                           contentHash: ClipboardStore.hash(representations: representations),
                           representations: representations)
            let configured = UserDefaults.standard.integer(forKey: "clipboard.maxItems")
            try store.prune(keeping: configured > 0 ? configured : 500)
            Log.clipboard.debug("captured \(kind, privacy: .public) item")
        } catch {
            Log.clipboard.error("capture failed: \(error.localizedDescription)")
        }
    }

    /// Scale `image` so its longest side is ≤ maxSide (never upscales); PNG via
    /// NSBitmapImageRep. Returns nil for degenerate images or encoding failures.
    static func thumbnailPNG(from image: NSImage, maxSide: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: max(1, floor(size.width * scale)),
                            height: max(1, floor(size.height * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, all 9 `PasteboardCaptureTests` passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clipboard/PasteboardWatcher.swift Tests/FuseTests/PasteboardCaptureTests.swift
git commit -m "feat(clipboard): polling pasteboard watcher with allowlist, size cap, and thumbnails"
```

---

### Task 4.4: Paste picker UI — panel and SwiftUI view

**Files:**
- Create: `Sources/Clipboard/PastePickerPanel.swift`
- Create: `Sources/Clipboard/PastePickerView.swift`

The panel is **non-activating**: it takes keyboard focus WITHOUT activating Fuse, so the previously frontmost app stays frontmost and receives the synthesized ⌘V. That is the entire trick that makes paste-into-other-app work.

- [ ] **Step 1: Write `Sources/Clipboard/PastePickerPanel.swift`**

```swift
import AppKit

/// Non-activating floating panel hosting the paste picker. `.nonactivatingPanel`
/// + `canBecomeKey` = keyboard focus here while the previous app STAYS frontmost.
final class PastePickerPanel: NSPanel {
    /// Called when the panel stops being key (e.g. user clicked elsewhere).
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Center on the screen currently containing the mouse pointer.
    func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }
}
```

- [ ] **Step 2: Write `Sources/Clipboard/PastePickerView.swift`**

```swift
import AppKit
import SwiftUI

/// Picker state + behavior. The controller installs an NSEvent local monitor
/// while the panel is visible and forwards keyDown events to handle(event:);
/// unhandled events fall through to the search field.
final class PastePickerViewModel: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var query: String = "" { didSet { reload() } }
    @Published var selectedIndex: Int = 0
    /// Incremented on each show; the view refocuses the search field on change.
    @Published var focusRequest: Int = 0

    private let store: ClipboardStore
    var onPaste: (ClipboardItem) -> Void = { _ in }   // set by ClipboardController
    var onClose: () -> Void = {}                      // set by ClipboardController

    init(store: ClipboardStore) { self.store = store }

    func reload() {
        do {
            items = try store.recentItems(limit: 100, matching: query.isEmpty ? nil : query)
        } catch {
            Log.clipboard.error("picker reload failed: \(error.localizedDescription)")
            items = []
        }
        if selectedIndex >= items.count { selectedIndex = max(0, items.count - 1) }
    }

    func prepareForShow() {
        query = ""          // didSet triggers reload()
        selectedIndex = 0
        focusRequest += 1
    }

    /// true = event fully handled (monitor swallows it); false = pass to search field.
    func handle(event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:   // esc
            onClose(); return true
        case 126:  // up arrow
            if selectedIndex > 0 { selectedIndex -= 1 }; return true
        case 125:  // down arrow
            if selectedIndex < items.count - 1 { selectedIndex += 1 }; return true
        case 36, 76:  // return / keypad enter — ⌘↩ pins, ↩ pastes
            if event.modifierFlags.contains(.command) { togglePinSelected() } else { pasteSelected() }
            return true
        case 51:   // delete: with empty query deletes the selected item
            if query.isEmpty { deleteSelected(); return true }
            return false
        default:
            break
        }
        if event.modifierFlags.contains(.command),   // ⌘1–⌘9 pastes the nth item
           let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
            pasteItem(at: digit - 1)
            return true
        }
        return false   // typed characters go to the search field
    }

    func pasteSelected() { pasteItem(at: selectedIndex) }

    func pasteItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        onPaste(items[index])
    }

    func togglePinSelected() {
        guard items.indices.contains(selectedIndex), let id = items[selectedIndex].id else { return }
        do { try store.togglePin(id: id); reload() }
        catch { Log.clipboard.error("toggle pin failed: \(error.localizedDescription)") }
    }

    func deleteSelected() {
        guard items.indices.contains(selectedIndex), let id = items[selectedIndex].id else { return }
        do { try store.delete(id: id); reload() }
        catch { Log.clipboard.error("delete failed: \(error.localizedDescription)") }
    }
}

struct PastePickerView: View {
    @ObservedObject var model: PastePickerViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search clipboard history…", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 10))
            Divider()
            if model.items.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(for: item, index: index)
                                .id(index)
                                .listRowBackground(index == model.selectedIndex
                                    ? Color.accentColor.opacity(0.25) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectedIndex = index
                                    model.pasteSelected()
                                }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: model.selectedIndex) { _, newIndex in proxy.scrollTo(newIndex) }
                }
            }
            Divider()
            Text("↩ paste · ⌘↩ pin · ⌫ delete · esc close")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(width: 420, height: 480)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
    }

    @ViewBuilder
    private func row(for item: ClipboardItem, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: item.kind)).frame(width: 18).foregroundStyle(.secondary)
            if item.kind == "image", let data = item.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 60, maxHeight: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
                HStack(spacing: 6) {
                    if index < 9 { Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary) }
                    Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "text": return "doc.plaintext"
        case "link": return "link"
        case "image": return "photo"
        case "file": return "doc"
        case "rtf": return "textformat"
        default: return "questionmark.square"
        }
    }
}
```

- [ ] **Step 3: Regenerate, build, run tests, commit**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
git add Sources/Clipboard/PastePickerPanel.swift Sources/Clipboard/PastePickerView.swift
git commit -m "feat(clipboard): non-activating paste picker panel and list UI"
```
Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **` (no new tests; nothing existing may break).

---

### Task 4.5: ClipboardController + AppDelegate wiring (anchors)

**Files:**
- Create: `Sources/Clipboard/ClipboardController.swift`
- Modify: `Sources/App/AppDelegate.swift` (anchor inserts ONLY — change nothing else)

- [ ] **Step 1: Write `Sources/Clipboard/ClipboardController.swift`**

```swift
import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the clipboard feature: store, watcher, picker panel, and the
/// `.pastePicker` hotkey (⇧⌘V, defined in Core/HotkeyNames.swift).
final class ClipboardController {
    private let store: ClipboardStore
    private let watcher: PasteboardWatcher
    private let panel: PastePickerPanel
    private let model: PastePickerViewModel
    private var keyMonitor: Any?

    /// Returns nil only when the on-disk database can't be opened; the rest of
    /// the app keeps running without clipboard history.
    init?() {
        UserDefaults.standard.register(defaults: ["clipboard.enabled": true, "clipboard.maxItems": 500])
        guard let store = ClipboardStore.shared else {
            Log.clipboard.error("clipboard store unavailable — feature disabled")
            return nil
        }
        self.store = store
        self.watcher = PasteboardWatcher(store: store)
        self.model = PastePickerViewModel(store: store)
        self.panel = PastePickerPanel()
        panel.contentView = NSHostingView(rootView: PastePickerView(model: model))

        model.onPaste = { [weak self] item in self?.paste(item) }
        model.onClose = { [weak self] in self?.hidePicker() }
        panel.onResignKey = { [weak self] in self?.hidePicker() }

        // The ONLY hotkey this feature uses — never define new Name constants.
        KeyboardShortcuts.onKeyDown(for: .pastePicker) { [weak self] in
            self?.togglePicker()
        }
    }

    func start() { watcher.start() }

    func togglePicker() {
        if panel.isVisible { hidePicker() } else { showPicker() }
    }

    private func showPicker() {
        model.prepareForShow()
        panel.centerOnMouseScreen()
        panel.makeKeyAndOrderFront(nil)   // non-activating: previous app stays frontmost
        installKeyMonitor()
    }

    private func hidePicker() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            return self.model.handle(event: event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func paste(_ item: ClipboardItem) {
        guard let id = item.id else { return }
        hidePicker()
        // 80 ms lets keyboard focus settle back on the previously frontmost app
        // before PasteService writes the pasteboard and synthesizes ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [store] in
            do {
                let reps = try store.representations(forItem: id)
                guard !reps.isEmpty else { return }
                var representation: PasteService.ItemRepresentation = [:]
                for rep in reps { representation[NSPasteboard.PasteboardType(rep.type)] = rep.data }
                // Lossless paste of ALL stored representations. PasteService marks
                // the write internal, synthesizes ⌘V, and restores the previous
                // clipboard 0.6 s later; the watcher skips both internal writes.
                PasteService.paste([representation], restoreAfter: 0.6)
            } catch {
                Log.clipboard.error("paste failed: \(error.localizedDescription)")
            }
        }
    }
}
```

- [ ] **Step 2: Wire into `Sources/App/AppDelegate.swift`** — two anchor edits, nothing else.

Edit A — find the line containing exactly `// FUSE:CONTROLLER-PROPS` and insert one line ABOVE it, so the file reads:

```swift
    private var clipboardController: ClipboardController!
    // FUSE:CONTROLLER-PROPS
```

Edit B — find the line containing exactly `// FUSE:CONTROLLER-START` (inside `applicationDidFinishLaunching`) and insert two lines ABOVE it, so the file reads:

```swift
        clipboardController = ClipboardController()
        clipboardController?.start()
        // FUSE:CONTROLLER-START
```

`ClipboardController()` is a failable initializer; the optional assignment and `?.start()` keep the app alive if the database can't open. The `XCTestCase` guard at the top of `applicationDidFinishLaunching` (Phase 0) already keeps the watcher and hotkey off during hosted test runs — do not remove it.

- [ ] **Step 3: Regenerate, build, test**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — capture, picker, paste, restore**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to perform ALL of the following and report each result. STOP and debug any failure before Task 4.6.

1. **Accessibility:** Fuse Settings → General must show Accessibility green; if red, click "Grant…" and enable Fuse. If it stays red after a rebuild, remove Fuse from the System Settings Accessibility list and re-add `.build/Build/Products/Debug/Fuse.app` (ad-hoc-signing TCC staleness, master §10).
2. **Text capture:** in TextEdit copy (⌘C) the text `hello fuse`, then run
   `sqlite3 ~/Library/Application\ Support/Fuse/clipboard.sqlite "SELECT kind, preview, sourceApp FROM clipboardItem ORDER BY createdAt DESC LIMIT 5;"`
   → expect a row `text|hello fuse|com.apple.TextEdit`.
3. **Link capture:** copy a URL from Safari's address bar → query again → `link|https://…` row on top.
4. **Image capture:** press ⇧⌃⌘4 and drag a region (screenshot to clipboard) → `image|Image WxH` row on top, and `SELECT length(thumbnail) FROM clipboardItem WHERE kind='image' ORDER BY createdAt DESC LIMIT 1;` returns a number > 0.
5. **File capture:** select a file in Finder, ⌘C → `file|<filename>` row on top.
6. **Dedupe:** copy `hello fuse` again → still exactly ONE `hello fuse` row, now back on top.
7. **Picker + paste + restore:** copy the word `RESTORE-ME`. Focus TextEdit, press ⇧⌘V — the picker appears centered on the mouse's screen WITHOUT TextEdit losing frontmost status (its name stays in the menu bar). Press ↓ a few times; type `hello` — the list filters to `hello fuse`; press ↩ — the panel closes and `hello fuse` is inserted into TextEdit. Wait ~1 s, press ⌘V — `RESTORE-ME` pastes (clipboard restored), and the history shows NO new entries from Fuse's own writes (internal-marker skip works).
8. **Keys:** reopen the picker; esc closes it; ⌘1 pastes the first item; ⌘↩ toggles the pin icon on the selected row; ⌫ (with empty search field) deletes the selected row.
9. **Concealed skip:** copy a password from a password manager (1Password/Bitwarden/Keychain Access) — it must NOT appear in history. (Skip if none installed; the unit test covers the logic.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Clipboard/ClipboardController.swift Sources/App/AppDelegate.swift
git commit -m "feat(clipboard): controller wiring, paste-picker hotkey, paste-and-restore flow"
```

---

### Task 4.6: Clipboard settings tab

**Files:**
- Create: `Sources/Clipboard/ClipboardSettingsView.swift`
- Modify: `Sources/App/SettingsRootView.swift` (anchor insert ONLY)

- [ ] **Step 1: Write `Sources/Clipboard/ClipboardSettingsView.swift`**

```swift
import KeyboardShortcuts
import SwiftUI

struct ClipboardSettingsView: View {
    @AppStorage("clipboard.enabled") private var enabled = true
    @AppStorage("clipboard.maxItems") private var maxItems = 500
    @State private var showClearConfirmation = false
    @State private var clearError: String?
    @State private var hasAccessibility = PermissionsService.hasAccessibility

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Clipboard History") {
                Toggle("Enable clipboard history", isOn: $enabled)
                Stepper(value: $maxItems, in: 100...2000, step: 100) {
                    LabeledContent("Maximum items", value: "\(maxItems)")
                }
                KeyboardShortcuts.Recorder("Open paste picker", name: .pastePicker)
            }
            Section("History") {
                Button("Clear unpinned history…", role: .destructive) { showClearConfirmation = true }
                if let clearError { Text(clearError).font(.caption).foregroundStyle(.red) }
            }
            if !hasAccessibility {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        VStack(alignment: .leading) {
                            Text("Accessibility permission missing")
                            Text("Pasting into other apps synthesizes ⌘V, which requires Accessibility.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") {
                            PermissionsService.promptForAccessibility()
                            PermissionsService.openSystemSettings(pane: .accessibility)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in hasAccessibility = PermissionsService.hasAccessibility }
        .alert("Clear unpinned history?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) { clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All unpinned clipboard items will be deleted. Pinned items are kept.")
        }
    }

    private func clearUnpinned() {
        guard let store = ClipboardStore.shared else {
            clearError = "Clipboard database is unavailable."
            return
        }
        do {
            try store.deleteAllUnpinned()
            clearError = nil
        } catch {
            clearError = "Clearing failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Add the tab in `Sources/App/SettingsRootView.swift`** — find the line containing exactly `// FUSE:SETTINGS_TABS` and insert two lines ABOVE it (other phases may have added their own tab lines nearby — leave those untouched):

```swift
            ClipboardSettingsView()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            // FUSE:SETTINGS_TABS
```

- [ ] **Step 3: Regenerate, build, test**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — settings tab behavior**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to confirm, in order:

1. Settings (menu-bar icon → Settings…) shows a **Clipboard** tab with the enable toggle, "Maximum items" stepper (steps of 100, clamped 100–2000), and the "Open paste picker" recorder showing ⇧⌘V.
2. Pin one item in the picker (⇧⌘V → select → ⌘↩), click "Clear unpinned history…" → "Clear" in the confirmation alert; reopening the picker shows ONLY the pinned item.
3. Toggle "Enable clipboard history" OFF, copy new text, open the picker — it must NOT appear. Toggle ON, copy again — it appears.
4. Record a different shortcut (e.g. ⌥⌘V) in the recorder, confirm it opens the picker, then record ⇧⌘V back.

Record the answers; debug before committing if anything fails.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clipboard/ClipboardSettingsView.swift Sources/App/SettingsRootView.swift
git commit -m "feat(clipboard): settings tab with enable toggle, max items, recorder, and clear"
```

---

### Task 4.7: Privacy exclusions + global pause compliance (TDD)

Precondition: `Sources/Core/PauseManager.swift` exists (Phase 1 Task 1.7). Two related protections: (a) the history database is plaintext SQLite, and the concealed-type skip in Task 4.2 covers password managers but NOT terminals or other apps that never mark secrets — a per-app exclusion list closes that gap; (b) while Fuse is globally paused, nothing may be recorded — including retroactively after resume.

**Files:**
- Create: `Sources/Clipboard/ClipboardExclusions.swift`
- Modify: `Sources/Clipboard/PasteboardWatcher.swift`
- Modify: `Sources/Clipboard/ClipboardSettingsView.swift`
- Test: `Tests/FuseTests/ClipboardExclusionsTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Fuse

final class ClipboardExclusionsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "FuseTests.exclusions")!
        defaults.removePersistentDomain(forName: "FuseTests.exclusions")
    }

    func testEmptyByDefault() {
        XCTAssertTrue(ClipboardExclusions.current(defaults: defaults).isEmpty)
    }

    func testAddRemoveRoundtrip() {
        ClipboardExclusions.add("com.apple.Terminal", defaults: defaults)
        ClipboardExclusions.add("com.googlecode.iterm2", defaults: defaults)
        XCTAssertEqual(ClipboardExclusions.current(defaults: defaults),
                       ["com.apple.Terminal", "com.googlecode.iterm2"])
        ClipboardExclusions.remove("com.apple.Terminal", defaults: defaults)
        XCTAssertEqual(ClipboardExclusions.current(defaults: defaults), ["com.googlecode.iterm2"])
    }

    func testIsExcluded() {
        let set: Set<String> = ["com.apple.Terminal"]
        XCTAssertTrue(ClipboardExclusions.isExcluded("com.apple.Terminal", in: set))
        XCTAssertFalse(ClipboardExclusions.isExcluded("com.apple.Safari", in: set))
        XCTAssertFalse(ClipboardExclusions.isExcluded(nil, in: set))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: compile failure, `cannot find 'ClipboardExclusions' in scope`.

- [ ] **Step 3: Write `Sources/Clipboard/ClipboardExclusions.swift`**

```swift
import Foundation

/// Per-app capture suppression ("never record from"). Stored as a sorted
/// string array under "clipboard.excludedApps" (master plan §6.4).
enum ClipboardExclusions {
    static let defaultsKey = "clipboard.excludedApps"

    static func current(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func isExcluded(_ bundleID: String?, in excluded: Set<String>) -> Bool {
        guard let bundleID else { return false }
        return excluded.contains(bundleID)
    }

    static func add(_ bundleID: String, defaults: UserDefaults = .standard) {
        var set = current(defaults: defaults)
        set.insert(bundleID)
        defaults.set(set.sorted(), forKey: defaultsKey)
    }

    static func remove(_ bundleID: String, defaults: UserDefaults = .standard) {
        var set = current(defaults: defaults)
        set.remove(bundleID)
        defaults.set(set.sorted(), forKey: defaultsKey)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Wire the watcher — three precise edits to `Sources/Clipboard/PasteboardWatcher.swift`**

Edit A — replace the entire `poll()` method with (note the swallow semantics: changes made while paused or disabled advance `lastChangeCount` WITHOUT capturing, so resuming never records stale copies):

```swift
    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        // Swallow (never capture) anything copied while paused or disabled —
        // otherwise resuming would retroactively record it.
        guard !PauseManager.shared.isPaused,
              UserDefaults.standard.bool(forKey: "clipboard.enabled") else {
            lastChangeCount = count
            return
        }
        lastChangeCount = count
        capture()
    }
```

Edit B — in `capture()`, replace the line

```swift
        guard let firstItem = pasteboard.pasteboardItems?.first else { return }
```

with:

```swift
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if ClipboardExclusions.isExcluded(sourceBundleID, in: ClipboardExclusions.current()) {
            Log.clipboard.debug("skipping capture from excluded app")
            return
        }
        guard let firstItem = pasteboard.pasteboardItems?.first else { return }
```

Edit C — further down in `capture()`, replace the save-call argument line

```swift
                           sourceApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
```

with (reuse the value read before the guard):

```swift
                           sourceApp: sourceBundleID,
```

- [ ] **Step 6: Settings UI — two precise edits to `Sources/Clipboard/ClipboardSettingsView.swift`**

Edit A — add two state properties directly below `@State private var hasAccessibility = PermissionsService.hasAccessibility`:

```swift
    @State private var excludedApps: [String] = ClipboardExclusions.current().sorted()
    @State private var selectedRunningApp: String = ""
```

Edit B — insert a new section between the closing `}` of `Section("History") { ... }` and the `if !hasAccessibility {` line:

```swift
            Section("Privacy — never record from") {
                if excludedApps.isEmpty {
                    Text("No excluded apps. Consider adding your terminal and password tools — the history database is not encrypted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(excludedApps, id: \.self) { bundleID in
                    HStack {
                        Text(appDisplayName(for: bundleID))
                        Text(bundleID).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") {
                            ClipboardExclusions.remove(bundleID)
                            excludedApps = ClipboardExclusions.current().sorted()
                        }
                    }
                }
                HStack {
                    Picker("Add running app", selection: $selectedRunningApp) {
                        Text("Choose…").tag("")
                        ForEach(runningAppChoices(), id: \.self) { bundleID in
                            Text(appDisplayName(for: bundleID)).tag(bundleID)
                        }
                    }
                    Button("Add") {
                        guard !selectedRunningApp.isEmpty else { return }
                        ClipboardExclusions.add(selectedRunningApp)
                        excludedApps = ClipboardExclusions.current().sorted()
                        selectedRunningApp = ""
                    }
                    .disabled(selectedRunningApp.isEmpty)
                }
            }
```

Edit C — add two helper methods directly below `clearUnpinned()` (and add `import AppKit` at the top of the file, above `import KeyboardShortcuts`, for `NSWorkspace`):

```swift
    private func runningAppChoices() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !excludedApps.contains($0) }
            .sorted()
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        return bundleID
    }
```

- [ ] **Step 7: Build and run all tests**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: HUMAN-VERIFY — exclusions and pause**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```
Ask the human to confirm, in order:

1. Settings → Clipboard shows "Privacy — never record from" with the empty-state hint; pick Terminal in the picker, click Add → row appears with app name + bundle id.
2. Copy text in Terminal → it does NOT appear in ⇧⌘V. Copy in Safari/TextEdit → it DOES.
3. Remove Terminal → Terminal copies record again.
4. "Pause Fuse" from the menu, copy something in TextEdit, resume → that copy is ABSENT from history (swallowed, not deferred); a fresh copy after resuming appears.

- [ ] **Step 9: Commit**

```bash
git add Sources/Clipboard/ClipboardExclusions.swift Sources/Clipboard/PasteboardWatcher.swift Sources/Clipboard/ClipboardSettingsView.swift Tests/FuseTests/ClipboardExclusionsTests.swift
git commit -m "feat(clipboard): per-app privacy exclusions and pause compliance"
```

---

## Manual verification checklist

Run end-to-end after Task 4.6 (app running from `.build/Build/Products/Debug/Fuse.app`, Accessibility granted):

- [ ] **HUMAN-VERIFY** Copy plain text, a Safari URL, a ⇧⌃⌘4 screenshot region, and a Finder file → all four appear in the picker newest-first with correct kinds, icons, and previews (text snippet, URL, "Image WxH" + thumbnail, file name).
- [ ] **HUMAN-VERIFY** With TextEdit frontmost: ⇧⌘V opens the picker without deactivating TextEdit; ↑/↓ move the highlight; typing filters; ↩ pastes the selected item into TextEdit; ~1 s later ⌘V pastes the pre-picker clipboard content (restore works); no Fuse-originated entries appear in history afterwards.
- [ ] **HUMAN-VERIFY** Copying a password from a password manager does NOT appear in history.
- [ ] **HUMAN-VERIFY** Picker search filters case-insensitively; clearing the query restores the full list.
- [ ] **HUMAN-VERIFY** Pin an item (⌘↩), then Settings → Clipboard → "Clear unpinned history": the pinned item survives, everything else is gone.
- [ ] **HUMAN-VERIFY** Quit Fuse and relaunch: history is still there (SQLite persistence).
- [ ] **HUMAN-VERIFY** Copy identical text twice → exactly one history entry, bubbled to the top.
- [ ] All unit tests green: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20` → `** TEST SUCCEEDED **`.
- [ ] `git log --oneline | head -8` shows the six Phase 4 commits on top.

## Risks & gotchas

- **Self-capture loop is the #1 failure mode.** `PasteService.paste` writes the chosen item AND later restores the old clipboard — both bump `changeCount`, both carry `fuseInternalMarker`, and `CaptureClassifier.shouldCapture` must reject them. Duplicated history entries right after pasting mean the marker check broke — fix that before anything else.
- **TCC + ad-hoc signing:** after a rebuild, macOS may show Accessibility as granted while `AXIsProcessTrusted()` returns false, so the synthesized ⌘V silently does nothing (picker closes, nothing pastes). Remove Fuse from the Accessibility list and re-add the current build. Suspect this FIRST when pasting stops working (master §10).
- **Non-activating panel focus:** if the search field ignores keystrokes, check `canBecomeKey == true` and `.nonactivatingPanel` in the styleMask. Never "fix" focus with `NSApp.activate` — that steals frontmost status from the target app and breaks the synthesized ⌘V.
- **Polling granularity:** 0.3 s polling can miss pasteboard states that exist for less time than that (rare). Accepted; macOS offers no change notification. Don't shrink the interval — `data(forType:)` isn't free.
- **Restore race:** with `restoreAfter: 0.6`, a target app that reads the pasteboard unusually late could read the restored content instead. The knob is the argument in `ClipboardController.paste`; do not change the `PasteService` default.
- **Multi-item copies:** copying several files stores representations from the FIRST pasteboard item only (the preview names all files). Pasting such an entry pastes one item. Documented limitation of this phase.
- **GRDB Date precision is milliseconds**, hence the 10 ms sleeps between test saves and the `id DESC` tiebreak in ordering. Real captures are ≥ 0.3 s apart, so it never matters in production.
- **Search uses SQL LIKE:** `%` and `_` typed in the search field act as wildcards. Harmless, accepted.
- **One SQLite connection:** controller and settings tab share `ClipboardStore.shared`. Never call `ClipboardStore.onDisk()` a second time from feature code — two connections on the same file can hit `SQLITE_BUSY`.
- **10 MB cap:** huge copies are skipped entirely and logged. Watch with `log stream --predicate 'subsystem == "com.rgv250cc.Fuse" AND category == "clipboard"' --level debug` whenever a copy "didn't show up".
