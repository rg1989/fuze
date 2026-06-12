import CoreMedia

/// Pure slider math shared by the recording review window.
/// Fractional start/end (0…1) of a clip → CMTimeRange. nil when duration is
/// non-positive or the clamped range is empty.
enum TrimMath {
    static func trimRange(start: Double, end: Double, duration: Double) -> CMTimeRange? {
        guard duration > 0 else { return nil }
        let s = min(max(start, 0), 1)
        let e = min(max(end, 0), 1)
        guard e > s else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: s * duration, preferredTimescale: 600),
            end: CMTime(seconds: e * duration, preferredTimescale: 600))
    }

    /// True when the slider range is effectively the whole clip — Save can
    /// skip the export entirely.
    static func isNoOp(start: Double, end: Double, epsilon: Double = 0.001) -> Bool {
        start <= epsilon && end >= 1 - epsilon
    }
}
