import Foundation
import GRDB

/// Parent record: one saved meeting. Mirrors `Note` (GRDB conformances + rowID
/// capture in didInsert).
struct Meeting: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "meeting"
    var id: Int64?
    var title: String
    var date: Date               // when the meeting happened
    var createdAt: Date          // when the row was saved
    var durationSeconds: Double
    var cleanedText: String?     // optional 2nd-pass cleaned transcript

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Child record: one speaker-attributed transcript line, ordered within a meeting.
struct MeetingSegment: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "meetingSegment"
    var id: Int64?
    var meetingId: Int64         // references meeting.id, ON DELETE CASCADE
    var orderIndex: Int          // contiguous 0..n-1
    var speakerId: String        // "Speaker 1", ...
    var text: String
    var startSeconds: Double
    var endSeconds: Double

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

enum MeetingTitle {
    static func `default`(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Meeting · \(f.string(from: date))"
    }
}
