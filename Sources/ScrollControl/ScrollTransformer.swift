/// The six integer delta fields of a scroll-wheel CGEvent, as read with
/// `getIntegerValueField`. Axis 1 is vertical, axis 2 is horizontal.
/// `fixedPt` fields are 16.16 fixed-point in two's complement, so negating the
/// raw Int64 negates the value.
struct ScrollDeltas: Equatable {
    var deltaAxis1: Int64          // vertical, line-based units
    var deltaAxis2: Int64          // horizontal, line-based units
    var pointDeltaAxis1: Int64     // vertical, pixel units
    var pointDeltaAxis2: Int64     // horizontal, pixel units
    var fixedPtDeltaAxis1: Int64   // vertical, fixed-point
    var fixedPtDeltaAxis2: Int64   // horizontal, fixed-point
}

/// Device class of a scroll event. Trackpads AND Magic Mice emit continuous
/// events; classic scroll wheels emit line-based events. v1 cannot tell them
/// apart (per-device IOKit is out of scope), so `reverseTrackpad` governs both.
enum ScrollSource {
    case continuous   // trackpad & Magic Mouse
    case lineBased    // classic scroll wheel
}

/// Pure scroll-direction math. No I/O, no globals — fully unit-tested.
enum ScrollTransformer {
    /// Returns nil when the event should pass through unchanged; otherwise the
    /// rewritten deltas to copy back onto the event.
    static func transform(_ d: ScrollDeltas,
                          source: ScrollSource,
                          settings: ScrollSettings) -> ScrollDeltas? {
        guard settings.enabled else { return nil }

        let reverseThisDevice: Bool
        switch source {
        case .continuous:
            reverseThisDevice = settings.reverseTrackpad
        case .lineBased:
            reverseThisDevice = settings.reverseMouse
        }
        guard reverseThisDevice else { return nil }

        var out = d
        out.deltaAxis1 = -d.deltaAxis1
        out.pointDeltaAxis1 = -d.pointDeltaAxis1
        out.fixedPtDeltaAxis1 = -d.fixedPtDeltaAxis1
        if settings.reverseHorizontal {
            out.deltaAxis2 = -d.deltaAxis2
            out.pointDeltaAxis2 = -d.pointDeltaAxis2
            out.fixedPtDeltaAxis2 = -d.fixedPtDeltaAxis2
        }
        return out
    }
}
