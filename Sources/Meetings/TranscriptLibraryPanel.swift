import AppKit

/// Floating library panel — same behavior as DownloadsPickerPanel: non-activating,
/// borderless, `.floating`, stays up when focus leaves; dismiss via Esc/close.
final class TranscriptLibraryPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: v.midX - frame.width / 2, y: v.midY - frame.height / 2))
    }
}
