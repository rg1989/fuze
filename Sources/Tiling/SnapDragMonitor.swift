import AppKit

/// Watches global window drags and offers edge snapping with a live preview:
/// drag a window so the cursor touches a screen edge and a translucent overlay
/// previews the tile (halves on edges, quarters near corners, maximize on
/// top); releasing the mouse applies it.
///
/// Window-drag detection: on left-mouse-down remember the location; on the
/// first drag beyond a small slop resolve the AX window under that point and
/// remember its frame. The drag counts as a WINDOW drag only once that
/// window's origin has moved while its size stayed constant — which rules out
/// text selections (nothing moves) and resizes (size changes).
final class SnapDragMonitor {
    private var monitors: [Any] = []
    private var mouseDownLocation: CGPoint?
    private var windowResolved = false
    private var draggedWindow: AXElement?
    private var initialWindowOrigin: CGPoint?   // AX top-left coords
    private var initialWindowSize: CGSize?
    private var dragConfirmed = false
    private var lastProbe: TimeInterval = 0
    private var activeAction: TileAction?
    private var activeScreen: NSScreen?
    private let overlay = SnapPreviewOverlay()

    private var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "tiling.enabled")
            && defaults.bool(forKey: "tiling.snapDrag")
            && !PauseManager.shared.isPaused
            && PermissionsService.hasAccessibility
    }

    func start() {
        guard monitors.isEmpty else { return }
        let add = { (mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) in
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
                self.monitors.append(monitor)
            }
        }
        add(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] _ in self?.mouseDragged() }
        add(.leftMouseUp) { [weak self] _ in self?.mouseUp() }
        Log.tiling.info("snap-drag monitor started")
    }

    private func mouseDown() {
        reset()
        mouseDownLocation = NSEvent.mouseLocation
    }

    private func mouseDragged() {
        guard let downLocation = mouseDownLocation, isEnabled else { return }
        let mouse = NSEvent.mouseLocation

        if !windowResolved {
            // Ignore sub-slop jitter so plain clicks never trigger AX work.
            guard hypot(mouse.x - downLocation.x, mouse.y - downLocation.y) > 4 else { return }
            windowResolved = true
            let window = AXElement.window(atCocoaPoint: downLocation)
            draggedWindow = window
            initialWindowOrigin = window?.position
            initialWindowSize = window?.size
        }
        guard let window = draggedWindow,
              let origin0 = initialWindowOrigin,
              let size0 = initialWindowSize else { return }

        if !dragConfirmed {
            // Probe at most every 50 ms — AX reads on every event are wasteful
            // for drags that never turn out to be window drags.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastProbe > 0.05 else { return }
            lastProbe = now
            guard let position = window.position, let size = window.size else {
                draggedWindow = nil
                return
            }
            if abs(size.width - size0.width) > 1 || abs(size.height - size0.height) > 1 {
                draggedWindow = nil   // it's a resize, not a move — stop considering
                return
            }
            guard abs(position.x - origin0.x) > 2 || abs(position.y - origin0.y) > 2 else { return }
            dragConfirmed = true
        }
        updateZone(mouse: mouse)
    }

    private func mouseUp() {
        defer { reset() }
        guard dragConfirmed, let action = activeAction, let screen = activeScreen,
              let window = draggedWindow else { return }
        Log.tiling.info("snap-drag applying \(action.rawValue, privacy: .public)")
        WindowMover.apply(action, to: window, on: screen)
    }

    private func updateZone(mouse: CGPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let action = screen.flatMap { SnapZone.action(for: mouse, in: $0.frame) }
        guard action != activeAction || screen != activeScreen else { return }
        activeAction = action
        activeScreen = screen
        if let action, let screen {
            let gap = CGFloat(UserDefaults.standard.double(forKey: "tiling.gap"))
            let frame = TileGeometry.frame(for: action,
                                           visibleFrame: screen.visibleFrame,
                                           currentWindowSize: initialWindowSize ?? .zero,
                                           gap: gap)
            overlay.show(frame: frame)
        } else {
            overlay.hide()
        }
    }

    private func reset() {
        mouseDownLocation = nil
        windowResolved = false
        draggedWindow = nil
        initialWindowOrigin = nil
        initialWindowSize = nil
        dragConfirmed = false
        activeAction = nil
        activeScreen = nil
        overlay.hide()
    }
}

private extension AXElement {
    /// Window under a global Cocoa (bottom-left-origin) point. The AX hit test
    /// wants top-left coordinates; same flip convention as ScreenCoords.
    static func window(atCocoaPoint point: CGPoint) -> AXElement? {
        guard let primary = NSScreen.screens.first else { return nil }
        let topLeft = CGPoint(x: point.x, y: primary.frame.height - point.y)
        return element(atTopLeftPoint: topLeft)?.containingWindow
    }
}
