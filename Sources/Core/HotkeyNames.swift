import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Voice (Phase 5) — hold to talk
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.control, .option]))

    // Clipboard (Phase 4)
    static let pastePicker = Self("pastePicker", default: .init(.v, modifiers: [.command, .shift]))

    // Notifications (Phase 7)
    static let clearNotifications = Self("clearNotifications", default: .init(.delete, modifiers: [.control, .option]))

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
}
