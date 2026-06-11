import CoreGraphics

/// The ONE place Fuse converts between Cocoa (bottom-left-origin, NSScreen)
/// and AX (top-left-origin, AXUIElement) global coordinates.
///
/// The flip is anchored by the primary screen's frame HEIGHT
/// (`NSScreen.screens[0].frame.height` — the primary always has Cocoa
/// origin (0,0)). Both functions are total and pure; rects on secondary
/// displays (negative x, y above the primary) convert correctly.
enum ScreenCoords {
    /// Cocoa rect → AX origin (the top-left corner of the window in AX space).
    static func axOrigin(ofCocoaRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX, y: primaryScreenHeight - rect.maxY)
    }

    /// AX origin + size → Cocoa rect.
    static func cocoaRect(axOrigin: CGPoint, size: CGSize, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: axOrigin.x,
               y: primaryScreenHeight - axOrigin.y - size.height,
               width: size.width,
               height: size.height)
    }
}
