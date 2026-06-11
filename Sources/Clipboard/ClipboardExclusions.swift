import Foundation

/// Per-app capture suppression ("never record from"). Stored as a sorted
/// string array under "clipboard.excludedApps" (master plan §6.4).
enum ClipboardExclusions {
    static let defaultsKey = "clipboard.excludedApps"

    static func current(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func isExcluded(_ bundleID: String?, in excluded: Set<String>) -> Bool {
        guard let bundleID else { return false }
        return excluded.contains(bundleID)
    }

    static func add(_ bundleID: String, defaults: UserDefaults = .standard) {
        var set = current(defaults: defaults)
        set.insert(bundleID)
        defaults.set(set.sorted(), forKey: defaultsKey)
    }

    static func remove(_ bundleID: String, defaults: UserDefaults = .standard) {
        var set = current(defaults: defaults)
        set.remove(bundleID)
        defaults.set(set.sorted(), forKey: defaultsKey)
    }
}
