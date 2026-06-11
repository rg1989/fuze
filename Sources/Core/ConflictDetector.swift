import AppKit

/// A known third-party utility whose behavior overlaps a Fuse feature.
struct AppConflict: Equatable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let fuseFeature: String
    let advice: String
}

enum ConflictDetector {
    /// Known overlapping utilities. Extend freely — unknown ids are harmless.
    /// Find any app's bundle id with:  osascript -e 'id of app "AppName"'
    static let knownConflicts: [String: (name: String, feature: String, advice: String)] = [
        "com.knollsoft.Rectangle": ("Rectangle", "Window tiling",
            "Quit Rectangle or disable Fuse tiling — both grab ⌃⌥-arrow shortcuts."),
        "com.knollsoft.Hookshot": ("Rectangle Pro", "Window tiling",
            "Quit Rectangle Pro or disable Fuse tiling."),
        "com.crowdcafe.windowmagnet": ("Magnet", "Window tiling",
            "Quit Magnet or disable Fuse tiling."),
        "com.hegenberg.BetterSnapTool": ("BetterSnapTool", "Window tiling",
            "Quit BetterSnapTool or disable Fuse tiling."),
        "com.pilotmoon.scroll-reverser": ("Scroll Reverser", "Scroll direction",
            "Quit Scroll Reverser — two inverters cancel each other out."),
        "com.caldis.Mos": ("Mos", "Scroll direction",
            "Quit Mos or disable Fuse scroll control."),
        "org.p0deje.Maccy": ("Maccy", "Clipboard history",
            "Quit Maccy — two watchers double-record every copy."),
        "com.wiheads.paste": ("Paste", "Clipboard history",
            "Quit Paste or disable Fuse clipboard history."),
        "com.charliemonroe.Downie-4": ("Downie", "Video downloads",
            "No hard conflict, but downloads are duplicated effort — pick one."),
    ]

    /// Pure core (unit-tested): which of `running` are known conflicts, sorted by bundle id.
    static func conflicts(amongBundleIDs running: Set<String>) -> [AppConflict] {
        running.intersection(knownConflicts.keys).sorted().map { bundleID in
            let info = knownConflicts[bundleID]!
            return AppConflict(bundleID: bundleID, appName: info.name,
                               fuseFeature: info.feature, advice: info.advice)
        }
    }

    static func currentConflicts() -> [AppConflict] {
        conflicts(amongBundleIDs:
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
    }
}
