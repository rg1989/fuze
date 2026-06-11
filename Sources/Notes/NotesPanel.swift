import AppKit

/// Non-activating floating panel hosting the notes UI. `.nonactivatingPanel`
/// + `canBecomeKey` = keyboard focus here while the previous app STAYS active.
/// Show/hide rules (Esc, auto-hide on resign-key unless pinned) live in
/// NotesController, which owns this panel.
final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                   styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Fuse Notes"
        titlebarAppearsTransparent = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 560, height: 380)
    }

    /// Center on the screen currently containing the mouse pointer.
    func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.midY - frame.height / 2))
    }
}
