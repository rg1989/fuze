import AppKit

/// Non-activating floating panel hosting the paste picker. `.nonactivatingPanel`
/// + `canBecomeKey` = keyboard focus here while the previous app STAYS frontmost.
final class PastePickerPanel: NSPanel {
    /// Called when the panel stops being key (e.g. user clicked elsewhere).
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Center on the screen currently containing the mouse pointer.
    func centerOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }
}
