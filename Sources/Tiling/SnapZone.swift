import CoreGraphics

/// Pure hit-testing for drag-to-edge snapping: maps the cursor position inside
/// a screen's FRAME (not visibleFrame — the cursor pins to the hard edge) to
/// the TileAction a drop there should perform. Coordinates are Cocoa
/// (bottom-left-origin) global points.
///
/// Zone layout mirrors the tile managers Fuse replaces:
///   left/right edge → half, except the top/bottom `cornerFraction` of the
///                     edge which suggests the adjacent quarter
///   top edge        → maximize, except the outer `cornerFraction` which
///                     suggests the adjacent top quarter
///   bottom edge     → nothing (the Dock lives there)
enum SnapZone {
    static let edgeThreshold: CGFloat = 10
    static let cornerFraction: CGFloat = 0.25

    static func action(for point: CGPoint, in screenFrame: CGRect,
                       threshold: CGFloat = SnapZone.edgeThreshold) -> TileAction? {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let vertical = (point.y - screenFrame.minY) / screenFrame.height   // 0 bottom … 1 top
        let horizontal = (point.x - screenFrame.minX) / screenFrame.width  // 0 left … 1 right

        if point.x - screenFrame.minX <= threshold {                       // left edge
            if vertical >= 1 - cornerFraction { return .topLeft }
            if vertical <= cornerFraction { return .bottomLeft }
            return .leftHalf
        }
        if screenFrame.maxX - point.x <= threshold {                       // right edge
            if vertical >= 1 - cornerFraction { return .topRight }
            if vertical <= cornerFraction { return .bottomRight }
            return .rightHalf
        }
        if screenFrame.maxY - point.y <= threshold {                       // top edge
            if horizontal <= cornerFraction { return .topLeft }
            if horizontal >= 1 - cornerFraction { return .topRight }
            return .maximize
        }
        return nil
    }
}
