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
    /// Frozen = selection confirmed; keep showing the dim + hole, stop
    /// reacting to input (the window also starts ignoring mouse events so
    /// the armed/recording HUD stays clickable underneath the cursor).
    private(set) var isFrozen = false
    /// Capsule opening punched out of the dim for the REC controls (view
    /// coords), so the Stop pill never sits under the dark layer.
    var controlsOpening: CGRect? {
        didSet { needsDisplay = true }
    }

    func freeze() {
        isFrozen = true
        needsDisplay = true
    }

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
            // Stroke fully OUTSIDE the selection so the outline can never
            // appear inside the recorded region.
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            outline.lineWidth = 2
            outline.stroke()
        } else if isFrozen {
            // Frozen full-overlay state without a rect shouldn't happen;
            // draw nothing extra.
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
        // Opening for the REC controls, punched out of the dim at exactly
        // the pill's frame: the pill's behind-window blur then samples the
        // undimmed desktop, so the glass reads as bright as the voice pill
        // instead of looking buried under the dark layer. No inset — a
        // larger hole shows a bright halo ring that reads as an artifact.
        if let opening = controlsOpening {
            let hole = opening
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(roundedRect: hole,
                         xRadius: hole.height / 2,
                         yRadius: hole.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isFrozen else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFrozen else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isFrozen else { return }
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
        guard !isFrozen else { return }
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
            switch result {
            case .region:
                // Keep the dim + clear hole on screen through the armed
                // phase (outline only once recording starts);
                // RecordingService dismisses on cancel/finish.
                self?.freezeInPlace()
            case .fullScreen, .cancelled:
                self?.dismiss()
            }
            completion(result)
        }
        window.contentView = view
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Recording started: cut a clear opening in the dim backdrop at the
    /// REC controls' frame (GLOBAL Cocoa coords) so the Stop pill is never
    /// covered by the dark layer. Pass nil to close the opening.
    func cutControlsOpening(at globalRect: CGRect?) {
        guard let window,
              let view = window.contentView as? RegionPickerView else { return }
        // View coords = global coords shifted by the window origin (the
        // window's frame equals the screen's frame).
        view.controlsOpening = globalRect?.offsetBy(dx: -window.frame.minX,
                                                    dy: -window.frame.minY)
    }

    /// Selection confirmed: stop interacting but stay visible. Mouse events
    /// pass through to whatever is underneath (including the REC HUD).
    private func freezeInPlace() {
        guard let window else { return }
        (window.contentView as? RegionPickerView)?.freeze()
        window.ignoresMouseEvents = true
        window.resignKey()
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
