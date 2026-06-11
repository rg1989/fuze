import CoreGraphics

/// Pure geometry: maps a TileAction to a target window frame inside a screen's
/// visible frame. ALL inputs and outputs are in Cocoa (bottom-left-origin)
/// coordinates. The AX top-left flip is ScreenCoords' job, never this file's.
///
/// `gap` is an inset in points applied between the window and the edges of
/// `visibleFrame` AND between adjacent tiled windows. A half tile therefore
/// measures `side/2 − 1.5·gap`: it gives up `gap` at the outer edge plus half
/// of the shared `gap`-wide seam in the middle.
enum TileGeometry {
    static func frame(for action: TileAction,
                      visibleFrame vf: CGRect,
                      currentWindowSize: CGSize,
                      gap: CGFloat) -> CGRect {
        let g = gap
        let halfW = vf.width / 2
        let halfH = vf.height / 2
        let fullW = vf.width - 2 * g       // full span, outer gaps only
        let fullH = vf.height - 2 * g
        let halfGapW = halfW - 1.5 * g     // half span, outer gap + half the seam
        let halfGapH = halfH - 1.5 * g
        let leftX = vf.minX + g
        let rightX = vf.minX + halfW + 0.5 * g
        let bottomY = vf.minY + g
        let topY = vf.minY + halfH + 0.5 * g   // Cocoa: top = larger y

        switch action {
        case .leftHalf:
            return CGRect(x: leftX, y: bottomY, width: halfGapW, height: fullH)
        case .rightHalf:
            return CGRect(x: rightX, y: bottomY, width: halfGapW, height: fullH)
        case .topHalf:
            return CGRect(x: leftX, y: topY, width: fullW, height: halfGapH)
        case .bottomHalf:
            return CGRect(x: leftX, y: bottomY, width: fullW, height: halfGapH)
        case .topLeft:
            return CGRect(x: leftX, y: topY, width: halfGapW, height: halfGapH)
        case .topRight:
            return CGRect(x: rightX, y: topY, width: halfGapW, height: halfGapH)
        case .bottomLeft:
            return CGRect(x: leftX, y: bottomY, width: halfGapW, height: halfGapH)
        case .bottomRight:
            return CGRect(x: rightX, y: bottomY, width: halfGapW, height: halfGapH)
        case .maximize:
            return CGRect(x: leftX, y: bottomY, width: fullW, height: fullH)
        case .center, .nextDisplay:
            // Keep the window's current size, clamped to the gap-inset frame,
            // centered in the visible frame. For .nextDisplay the CALLER
            // (WindowMover) passes the NEXT screen's visibleFrame; the
            // geometry is identical to .center by design.
            let clampedW = min(currentWindowSize.width, fullW)
            let clampedH = min(currentWindowSize.height, fullH)
            return CGRect(x: vf.minX + (vf.width - clampedW) / 2,
                          y: vf.minY + (vf.height - clampedH) / 2,
                          width: clampedW,
                          height: clampedH)
        }
    }
}
