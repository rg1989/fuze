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
