import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Voice (Phase 5) — hold to talk
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.control, .option]))

    // Clipboard (Phase 4)
    static let pastePicker = Self("pastePicker", default: .init(.v, modifiers: [.command, .shift]))

    // Notifications (Phase 7)
    static let clearNotifications = Self("clearNotifications", default: .init(.delete, modifiers: [.control, .option]))

    // Downloader (Phase 6) — open the downloads picker from anywhere
    static let openDownloads = Self("openDownloads", default: .init(.d, modifiers: [.command, .shift]))

    // Notes (Phase 8)
    static let toggleNotesPanel = Self("toggleNotesPanel", default: .init(.m, modifiers: [.control, .option]))

    // Tiling (Phase 3)
    static let tileLeftHalf = Self("tileLeftHalf", default: .init(.leftArrow, modifiers: [.control, .option]))
    static let tileRightHalf = Self("tileRightHalf", default: .init(.rightArrow, modifiers: [.control, .option]))
    static let tileTopHalf = Self("tileTopHalf", default: .init(.upArrow, modifiers: [.control, .option]))
    static let tileBottomHalf = Self("tileBottomHalf", default: .init(.downArrow, modifiers: [.control, .option]))
    static let tileTopLeft = Self("tileTopLeft", default: .init(.one, modifiers: [.control, .option]))
    static let tileTopRight = Self("tileTopRight", default: .init(.two, modifiers: [.control, .option]))
    static let tileBottomLeft = Self("tileBottomLeft", default: .init(.three, modifiers: [.control, .option]))
    static let tileBottomRight = Self("tileBottomRight", default: .init(.four, modifiers: [.control, .option]))
    static let tileMaximize = Self("tileMaximize", default: .init(.return, modifiers: [.control, .option]))
    static let tileCenter = Self("tileCenter", default: .init(.c, modifiers: [.control, .option]))
    static let tileNextDisplay = Self("tileNextDisplay", default: .init(.n, modifiers: [.control, .option]))

    // Capture (Phase 10)
    static let captureRegion = Self("captureRegion", default: .init(.s, modifiers: [.control, .option]))
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.control, .option]))
    // No defaults: folder-openers are menu items first, shortcuts opt-in.
    static let openScreenshotsFolder = Self("openScreenshotsFolder")
    static let openRecordingsFolder = Self("openRecordingsFolder")

    /// One-time fixups for shortcuts whose default changed AFTER an earlier
    /// release already persisted the old default. KeyboardShortcuts only writes
    /// a default when none is stored, so a changed default is otherwise ignored
    /// forever — even across reinstalls. Each fixup resets the stored value ONLY
    /// when it still equals the superseded default (never clobbers a user's own
    /// choice), then records a flag so it runs once.
    @MainActor
    static func migrateChangedDefaults() {
        let defaults = UserDefaults.standard

        // openDownloads: ⌃⌥D (original) → ⇧⌘D (current).
        let flag = "core.shortcutMigration.openDownloadsCmdShiftD"
        if !defaults.bool(forKey: flag) {
            let supersededDefault = KeyboardShortcuts.Shortcut(.d, modifiers: [.control, .option])
            let newDefault = KeyboardShortcuts.Shortcut(.d, modifiers: [.command, .shift])
            let current = Self.openDownloads.shortcut
            if current == nil || current == supersededDefault {
                Self.openDownloads.shortcut = newDefault
            }
            defaults.set(true, forKey: flag)
        }
    }
}
