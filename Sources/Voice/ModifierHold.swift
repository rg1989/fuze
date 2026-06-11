import AppKit

/// A combination of SIDE-SPECIFIC modifier keys (e.g. Right ⌘ + Right ⌥)
/// plus the fn/Globe key, expressed as the device-dependent bits that macOS
/// preserves in `NSEvent.modifierFlags.rawValue`. KeyboardShortcuts cannot
/// record modifier-only hotkeys, so modifier-hold push-to-talk goes through
/// this instead.
struct ModifierCombo: Equatable {
    var rawMask: UInt

    static let off = ModifierCombo(rawMask: 0)

    /// Carbon NX_DEVICE* device-dependent flag bits + NSEvent's fn bit.
    static let bits: [(mask: UInt, label: String)] = [
        (0x0001, "Left ⌃"), (0x2000, "Right ⌃"),
        (0x0002, "Left ⇧"), (0x0004, "Right ⇧"),
        (0x0020, "Left ⌥"), (0x0040, "Right ⌥"),
        (0x0008, "Left ⌘"), (0x0010, "Right ⌘"),
        (0x0080_0000, "fn"),
    ]

    static let interestMask: UInt = bits.reduce(0) { $0 | $1.mask }

    var isOff: Bool { rawMask == 0 }

    var displayString: String {
        let parts = Self.bits.filter { rawMask & $0.mask != 0 }.map(\.label)
        return parts.isEmpty ? "Off" : parts.joined(separator: " + ")
    }

    /// The side-specific modifier bits currently pressed, per an event's raw flags.
    static func pressed(inFlags raw: UInt) -> UInt { raw & interestMask }
}

/// Pure edge detector: feed it every flags-changed raw value; it reports when
/// the configured combo becomes fully held (.down) or stops being held (.up).
/// Extra modifiers beyond the combo are tolerated (subset match).
struct ModifierHoldDetector {
    enum Edge: Equatable { case down, up }

    let combo: ModifierCombo
    private(set) var isHeld = false

    mutating func process(rawFlags: UInt) -> Edge? {
        guard !combo.isOff else { return nil }
        let satisfied = (ModifierCombo.pressed(inFlags: rawFlags) & combo.rawMask) == combo.rawMask
        if satisfied && !isHeld {
            isHeld = true
            return .down
        }
        if !satisfied && isHeld {
            isHeld = false
            return .up
        }
        return nil
    }
}

/// OS shell: global + local flagsChanged monitors feeding the detector.
/// The global monitor needs Accessibility (already a Fuse requirement); it
/// covers other apps being frontmost, the local one covers Fuse itself —
/// macOS never delivers the same event to both, so edges can't double-fire.
@MainActor
final class ModifierHoldMonitor {
    static let defaultsKey = "voice.modifierPTTMask"

    private var detector: ModifierHoldDetector
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private let onDown: () -> Void
    private let onUp: () -> Void

    init(onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.onDown = onDown
        self.onUp = onUp
        self.detector = ModifierHoldDetector(combo: Self.configuredCombo())
    }

    static func configuredCombo(defaults: UserDefaults = .standard) -> ModifierCombo {
        ModifierCombo(rawMask: UInt(bitPattern: defaults.integer(forKey: defaultsKey)))
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let raw = event.modifierFlags.rawValue
            Task { @MainActor in self?.handle(rawFlags: raw) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let raw = event.modifierFlags.rawValue
            Task { @MainActor in self?.handle(rawFlags: raw) }
            return event
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadComboIfChanged() }
        }
    }

    private func reloadComboIfChanged() {
        let combo = Self.configuredCombo()
        guard combo != detector.combo else { return }
        if detector.isHeld { onUp() }   // never strand a held recording
        detector = ModifierHoldDetector(combo: combo)
        Log.voice.info("modifier PTT combo changed: \(combo.displayString, privacy: .public)")
    }

    private func handle(rawFlags: UInt) {
        // KeyboardShortcuts.isEnabled doesn't cover NSEvent monitors; honor
        // the global pause here explicitly. A pause mid-hold is handled by
        // VoiceController's existing pause observer (discards the recording).
        guard !PauseManager.shared.isPaused else { return }
        switch detector.process(rawFlags: rawFlags) {
        case .down: onDown()
        case .up: onUp()
        case nil: break
        }
    }
}
