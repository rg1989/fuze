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

    /// Uniform scale that fits `imageSize` inside `availableSize` while
    /// preserving aspect ratio. Grows above 1.0 when the viewport is larger
    /// than the image so resizing the review window enlarges the canvas.
    static func fitScale(imageSize: CGSize, availableSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              availableSize.width > 0, availableSize.height > 0 else { return 1 }
        return min(availableSize.width / imageSize.width,
                   availableSize.height / imageSize.height)
    }

    /// Map a point from the on-screen (scaled) editor into image coordinates.
    static func imagePoint(fromViewPoint point: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }
}
