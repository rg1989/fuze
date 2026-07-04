import Foundation
import GRDB

/// SQLite-backed meeting-transcript store. Method-for-method mirror of
/// `NoteStore`: same `Application Support/Fuse/` directory, new file
/// `meetings.sqlite`, parent/child schema with ON DELETE CASCADE, and the
/// DISTINCT LEFT-JOIN LIKE content search. DatabaseQueue serializes access.
final class MeetingStore {
    /// App-wide instance. The controller AND the settings tab must both use this
    /// single instance — never open a second connection to the same file.
    static let shared: MeetingStore? = try? MeetingStore.onDisk()

    private let dbQueue: DatabaseQueue

    /// Also used by tests with an in-memory `DatabaseQueue()`.
    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    static func onDisk() throws -> MeetingStore {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Fuse", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return try MeetingStore(dbQueue: DatabaseQueue(
            path: dir.appendingPathComponent("meetings.sqlite").path))
    }

    /// Absolute path of the on-disk database file (settings tab shows it).
    static var onDiskPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fuse/meetings.sqlite").path
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("cleanedText", .text)
            }
            try db.create(table: "meetingSegment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .integer).notNull().references("meeting", onDelete: .cascade)
                t.column("orderIndex", .integer).notNull()
                t.column("speakerId", .text).notNull()
                t.column("text", .text).notNull()
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
            }
            try db.create(index: "meetingSegment_meetingId_orderIndex",
                          on: "meetingSegment", columns: ["meetingId", "orderIndex"])
        }
        return migrator
    }

    @discardableResult
    func saveMeeting(title: String, date: Date, durationSeconds: Double, cleanedText: String?,
                     segments: [(speakerId: String, text: String, start: Double, end: Double)]) throws -> Meeting {
        try dbQueue.write { db in
            var meeting = Meeting(id: nil, title: title, date: date, createdAt: Date(),
                                  durationSeconds: durationSeconds, cleanedText: cleanedText)
            try meeting.insert(db)
            let mid = meeting.id!
            for (i, s) in segments.enumerated() {
                var seg = MeetingSegment(id: nil, meetingId: mid, orderIndex: i,
                                         speakerId: s.speakerId, text: s.text,
                                         startSeconds: s.start, endSeconds: s.end)
                try seg.insert(db)
            }
            return meeting
        }
    }

    /// Most recent first. `query` (if non-empty) filters with case-insensitive
    /// LIKE over the title OR any segment's text.
    func meetings(matching query: String?) throws -> [Meeting] {
        try dbQueue.read { db in
            if let query, !query.isEmpty {
                let pattern = "%\(query)%"
                return try Meeting.fetchAll(db, sql: """
                    SELECT DISTINCT meeting.* FROM meeting
                    LEFT JOIN meetingSegment ON meetingSegment.meetingId = meeting.id
                    WHERE meeting.title LIKE ? OR meetingSegment.text LIKE ?
                    ORDER BY meeting.date DESC, meeting.id DESC
                    """, arguments: [pattern, pattern])
            }
            return try Meeting.order(Column("date").desc, Column("id").desc).fetchAll(db)
        }
    }

    func segments(forMeeting id: Int64) throws -> [MeetingSegment] {
        try dbQueue.read { db in
            try MeetingSegment.filter(Column("meetingId") == id)
                .order(Column("orderIndex")).fetchAll(db)
        }
    }

    func deleteMeeting(id: Int64) throws {
        _ = try dbQueue.write { db in try Meeting.deleteOne(db, key: id) }
    }

    /// Renders a meeting to a markdown transcript string ("[Speaker N] text").
    func export(meetingID: Int64) throws -> String {
        let (m, segs): (Meeting, [MeetingSegment]) = try dbQueue.read { db in
            guard let m = try Meeting.fetchOne(db, key: meetingID) else {
                throw DatabaseError(message: "meeting \(meetingID) not found")
            }
            return (m, try MeetingSegment.filter(Column("meetingId") == meetingID)
                .order(Column("orderIndex")).fetchAll(db))
        }
        return MeetingMarkdownExporter.transcript(title: m.title, segments: segs)
    }
}
