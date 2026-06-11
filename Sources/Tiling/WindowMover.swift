import AppKit

/// Applies a TileAction to the frontmost window via the Accessibility API.
/// All geometry is computed by TileGeometry (Cocoa coordinates) and converted
/// to AX coordinates by ScreenCoords — this file never does its own math.
enum WindowMover {
    /// The focused window of the frontmost app, or nil if there is none
    /// (e.g. Finder with no windows, or Accessibility not granted).
    static func frontmostWindow() -> AXElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXElement.application(pid: app.processIdentifier).focusedWindow
    }

    /// The screen containing (most of) the window: convert the window's AX
    /// position/size to a Cocoa rect, then pick the NSScreen whose frame has
    /// the largest intersection area. Falls back to the main screen.
    static func screen(containing window: AXElement) -> NSScreen {
        let fallback = NSScreen.main ?? NSScreen.screens[0]
        guard let primary = NSScreen.screens.first,
              let axPosition = window.position,
              let axSize = window.size else { return fallback }
        let cocoa = ScreenCoords.cocoaRect(axOrigin: axPosition,
                                           size: axSize,
                                           primaryScreenHeight: primary.frame.height)
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for candidate in NSScreen.screens {
            let overlap = candidate.frame.intersection(cocoa)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = candidate
            }
        }
        return best ?? fallback
    }

    /// Compute and apply the target frame for `action` on the frontmost window.
    static func apply(_ action: TileAction) {
        guard PermissionsService.hasAccessibility else {
            Log.tiling.warning("tile \(action.rawValue, privacy: .public): Accessibility not granted; prompting")
            PermissionsService.promptForAccessibility()
            return
        }
        guard let window = frontmostWindow() else {
            Log.tiling.warning("tile \(action.rawValue, privacy: .public): no focused window")
            return
        }
        guard let primary = NSScreen.screens.first else {
            Log.tiling.error("tile \(action.rawValue, privacy: .public): no screens attached")
            return
        }
        let primaryHeight = primary.frame.height
        let currentSize = window.size ?? .zero
        let gap = CGFloat(UserDefaults.standard.double(forKey: "tiling.gap"))

        // For .nextDisplay: pick the NEXT screen in NSScreen.screens cyclically,
        // then center the window (size kept, clamped) on that screen. Geometrically
        // identical to .center on the next screen's visibleFrame.
        let targetScreen: NSScreen
        let geometryAction: TileAction
        if action == .nextDisplay {
            let screens = NSScreen.screens
            let current = screen(containing: window)
            let index = screens.firstIndex(of: current) ?? 0
            targetScreen = screens[(index + 1) % screens.count]
            geometryAction = .center
        } else {
            targetScreen = screen(containing: window)
            geometryAction = action
        }

        let cocoaFrame = TileGeometry.frame(for: geometryAction,
                                            visibleFrame: targetScreen.visibleFrame,
                                            currentWindowSize: currentSize,
                                            gap: gap)
        let axOrigin = ScreenCoords.axOrigin(ofCocoaRect: cocoaFrame,
                                             primaryScreenHeight: primaryHeight)

        // Clamp-resistant apply order: setPosition → setSize → setPosition.
        // Apps like Terminal snap their size to character-cell multiples; if the
        // size is set first the window can drift away from the target origin.
        // Re-asserting the position after the resize pins the corner.
        if !window.setPosition(axOrigin) {
            Log.tiling.error("tile \(action.rawValue, privacy: .public): first setPosition failed")
        }
        if !window.setSize(cocoaFrame.size) {
            Log.tiling.error("tile \(action.rawValue, privacy: .public): setSize failed")
        }
        if !window.setPosition(axOrigin) {
            Log.tiling.error("tile \(action.rawValue, privacy: .public): second setPosition failed")
        }
    }
}
