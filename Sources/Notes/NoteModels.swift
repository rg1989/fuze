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
