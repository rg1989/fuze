import AppKit

/// Result of a region-selection session, in Cocoa (bottom-left-origin)
/// GLOBAL screen coordinates. RecordingService converts to top-left for
/// screencapture via CaptureGeometry.topLeftRect.
enum RegionPickResult: Equatable {
    case region(CGRect)
    case fullScreen
    case cancelled
}

/// Borderless windows refuse key status by default; we need ESC/Return.
private final class RegionPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionPickerView: NSView {
    var onResult: ((RegionPickResult) -> Void)?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selectionRect: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        let rect = CaptureGeometry.normalizedRect(from: a, to: b)
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let rect = selectionRect {
            // Punch a clear hole for the selection (window is non-opaque).
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1
            outline.stroke()
        } else {
            let hint = "Drag to select a region   ·   Return records the entire screen   ·   Esc cancels"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2),
                      withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect, rect.width >= 8, rect.height >= 8,
              let window else {
            // Too small to be a deliberate selection — keep picking.
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
            return
        }
        // View coords + window origin = Cocoa global screen coords
        // (the window's frame equals the screen's frame).
        let screenRect = CGRect(x: rect.minX + window.frame.minX,
                                y: rect.minY + window.frame.minY,
                                width: rect.width,
                                height: rect.height)
        onResult?(.region(screenRect))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:        // Esc
            onResult?(.cancelled)
        case 36, 76:    // Return / keypad Enter — entire screen
            onResult?(.fullScreen)
        default:
            super.keyDown(with: event)
        }
    }
}

/// Presents the selection overlay on the screen containing the mouse.
/// Lifetime: owned by RecordingService; the window is retained until a
/// result is delivered, then torn down.
final class RegionPicker {
    private var window: RegionPickerWindow?

    var isPresenting: Bool { window != nil }

    func present(completion: @escaping (RegionPickResult) -> Void) {
        guard window == nil else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let window = RegionPickerWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        let view = RegionPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onResult = { [weak self] result in
            self?.dismiss()
            completion(result)
        }
        window.contentView = view
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
