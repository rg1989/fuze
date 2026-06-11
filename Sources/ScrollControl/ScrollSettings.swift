import Foundation

/// Immutable snapshot of the four scroll-related UserDefaults values
/// (master plan §6.4). The event-tap hot path reads a cached snapshot instead
/// of UserDefaults, and the pure ScrollTransformer takes a snapshot parameter
/// so it is fully unit-testable.
struct ScrollSettings: Equatable {
    var enabled: Bool
    var reverseTrackpad: Bool
    var reverseMouse: Bool
    var reverseHorizontal: Bool

    /// Read current values. Keys that have never been written fall back to the
    /// master-plan defaults: enabled/reverseTrackpad/reverseMouse = true,
    /// reverseHorizontal = false. The `object(forKey:) == nil` check is
    /// load-bearing: `bool(forKey:)` alone returns false for missing keys.
    static func current(defaults: UserDefaults = .standard) -> ScrollSettings {
        ScrollSettings(
            enabled: bool("scroll.enabled", default: true, in: defaults),
            reverseTrackpad: bool("scroll.reverseTrackpad", default: true, in: defaults),
            reverseMouse: bool("scroll.reverseMouse", default: true, in: defaults),
            reverseHorizontal: bool("scroll.reverseHorizontal", default: false, in: defaults))
    }

    /// Seed the registration domain so @AppStorage in ScrollSettingsView and
    /// `current(defaults:)` agree before the user ever opens the Scroll tab.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "scroll.enabled": true,
            "scroll.reverseTrackpad": true,
            "scroll.reverseMouse": true,
            "scroll.reverseHorizontal": false,
        ])
    }

    private static func bool(_ key: String, default fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
