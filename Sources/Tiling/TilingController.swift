import AppKit
import KeyboardShortcuts

/// Registers the 11 global tiling hotkeys and routes them to WindowMover.
/// Hotkey Name constants come EXCLUSIVELY from Core/HotkeyNames.swift.
final class TilingController {
    private static let shortcutMap: [(KeyboardShortcuts.Name, TileAction)] = [
        (.tileLeftHalf, .leftHalf),
        (.tileRightHalf, .rightHalf),
        (.tileTopHalf, .topHalf),
        (.tileBottomHalf, .bottomHalf),
        (.tileTopLeft, .topLeft),
        (.tileTopRight, .topRight),
        (.tileBottomLeft, .bottomLeft),
        (.tileBottomRight, .bottomRight),
        (.tileMaximize, .maximize),
        (.tileCenter, .center),
        (.tileNextDisplay, .nextDisplay),
    ]

    func start() {
        UserDefaults.standard.register(defaults: [
            "tiling.enabled": true,
            "tiling.gap": 0.0,
        ])
        for (name, action) in Self.shortcutMap {
            KeyboardShortcuts.onKeyDown(for: name) {
                // Re-checked on every keypress: toggling the setting takes
                // effect immediately, no re-registration needed.
                guard UserDefaults.standard.bool(forKey: "tiling.enabled") else { return }
                WindowMover.apply(action)
            }
        }
        Log.tiling.info("tiling started: \(Self.shortcutMap.count) shortcuts registered")
    }
}
