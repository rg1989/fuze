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
