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
