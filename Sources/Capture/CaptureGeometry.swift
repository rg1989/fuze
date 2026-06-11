import CoreGraphics

/// Pure rect helpers shared by the region picker and the image editor.
enum CaptureGeometry {
    /// Rect spanned by a drag in ANY direction (standard CGRect has negative
    /// width/height semantics we never want downstream).
    static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(b.x - a.x),
               height: abs(b.y - a.y))
    }

    /// Cocoa (bottom-left-origin) global rect → top-left-origin global rect,
    /// as `screencapture -R<x,y,w,h>` expects. Same flip convention as
    /// Tiling's ScreenCoords: anchored on the PRIMARY screen's frame height
    /// (NSScreen.screens[0] always has Cocoa origin (0,0)).
    static func topLeftRect(fromCocoaRect rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }
}
