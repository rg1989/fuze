import AppKit
import Carbon.HIToolbox

/// Writes content to a pasteboard, synthesizes ⌘V into the frontmost app,
/// and restores the previous pasteboard contents afterwards.
/// Everything Fuse writes carries `fuseInternalMarker` so the clipboard
/// watcher (Phase 4) can ignore Fuse's own writes.
enum PasteService {
    static let fuseInternalMarker = NSPasteboard.PasteboardType("com.rgv250cc.fuse.internal")

    typealias ItemRepresentation = [NSPasteboard.PasteboardType: Data]

    static func snapshot(of pasteboard: NSPasteboard = .general) -> [ItemRepresentation] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var rep: ItemRepresentation = [:]
            for type in item.types where type != fuseInternalMarker {
                if let data = item.data(forType: type) {
                    rep[type] = data
                }
            }
            return rep
        }
    }

    static func write(_ items: [ItemRepresentation],
                      to pasteboard: NSPasteboard = .general,
                      markInternal: Bool = true) {
        pasteboard.clearContents()
        let pbItems = items.enumerated().map { index, rep -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in rep {
                item.setData(data, forType: type)
            }
            if markInternal && index == 0 {
                item.setData(Data(), forType: fuseInternalMarker)
            }
            return item
        }
        pasteboard.writeObjects(pbItems)
    }

    /// Snapshot current clipboard → write `items` → ⌘V → restore snapshot after `seconds`.
    static func paste(_ items: [ItemRepresentation], restoreAfter seconds: Double = 0.6) {
        let saved = snapshot()
        write(items, markInternal: true)
        synthesizeCmdV()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            write(saved, markInternal: true)
        }
    }

    static func paste(text: String, restoreAfter seconds: Double = 0.6) {
        paste([[.string: Data(text.utf8)]], restoreAfter: seconds)
    }

    /// Paste `text` and LEAVE it on the clipboard afterwards (no restore), so a
    /// transcript is never lost if it lands somewhere that can't hold text.
    /// Written non-internal so it's recorded in Fuse's own clipboard history.
    static func pasteKeepingOnClipboard(text: String) {
        write([[.string: Data(text.utf8)]], markInternal: false)
        synthesizeCmdV()
    }

    /// Put `text` on the clipboard without pasting (no Accessibility needed).
    static func copyToClipboard(text: String) {
        write([[.string: Data(text.utf8)]], markInternal: false)
    }

    /// Requires Accessibility permission; otherwise the events are silently dropped.
    static func synthesizeCmdV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
