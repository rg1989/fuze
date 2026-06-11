import AppKit

/// The capture-confirmation sound: any of the macOS system sounds, selectable
/// in the Clipboard settings tab.
enum CopySound {
    static let enabledKey = "clipboard.copySound"
    static let nameKey = "clipboard.copySoundName"
    static let defaultName = "Pop"

    /// All system sounds available to NSSound(named:), e.g. Basso, Glass,
    /// Hero, Morse, Ping, Pop, Purr, Submarine, Tink…
    static func availableSounds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return names
            .filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [enabledKey: true, nameKey: defaultName])
    }

    static func playIfEnabled(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: enabledKey) else { return }
        preview(defaults.string(forKey: nameKey) ?? defaultName)
    }

    static func preview(_ name: String) {
        NSSound(named: name)?.play()
    }
}
