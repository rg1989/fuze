import AppKit
import KeyboardShortcuts

/// Matches a key-down CGEvent against a KeyboardShortcuts combo.
enum HotkeyEventMatch {
    static func modifierFlags(from event: CGEvent) -> NSEvent.ModifierFlags {
        var mods = NSEvent.ModifierFlags()
        let flags = event.flags
        if flags.contains(.maskCommand) { mods.insert(.command) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        if flags.contains(.maskControl) { mods.insert(.control) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        return mods
    }

    static func matches(_ event: CGEvent, shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == shortcut.carbonKeyCode else { return false }
        return modifierFlags(from: event) == shortcut.modifiers
    }
}

/// One session-level event tap that intercepts configured Fuse shortcuts before
/// the frontmost app. Carbon handlers remain registered as a no-conflict fallback.
final class GlobalHotkeyTap {
    static let shared = GlobalHotkeyTap()

    struct Registration {
        let name: KeyboardShortcuts.Name
        let isEnabled: () -> Bool
        let onKeyDown: () -> Void
    }

    private var registrations: [Registration] = []
    private var cachedShortcuts: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionRetryTimer: Timer?
    private var pauseObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var carbonRegistered = Set<KeyboardShortcuts.Name>()

    private init() {}

    func register(_ registration: Registration) {
        registrations.append(registration)
        refreshShortcutCache()
        registerCarbonFallback(for: registration.name)
        updateTapMode()
    }

    func start() {
        pauseObserver = NotificationCenter.default.addObserver(
            forName: PauseManager.pauseStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.updateTapMode() }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshShortcutCache()
            self?.reregisterCarbonFallbacks()
        }

        updateTapMode()
    }

    // MARK: - Tap lifecycle

    private func updateTapMode() {
        if PauseManager.shared.isPaused || !PermissionsService.hasAccessibility {
            removeTap()
            if !PauseManager.shared.isPaused && !PermissionsService.hasAccessibility {
                schedulePermissionRetry()
            }
            return
        }
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        installTapIfNeeded()
    }

    private func installTapIfNeeded() {
        guard machPort == nil else { return }
        let keyDown = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let disabled = CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: keyDown | disabled,
            callback: globalHotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.app.error("global hotkey tap unavailable — using Carbon fallback only")
            schedulePermissionRetry()
            return
        }
        machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.app.info("global hotkey tap installed (\(self.registrations.count) shortcuts)")
    }

    private func removeTap() {
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        machPort = nil
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, PermissionsService.hasAccessibility else { return }
            self.permissionRetryTimer?.invalidate()
            self.permissionRetryTimer = nil
            self.updateTapMode()
        }
    }

    // MARK: - Carbon fallback (no conflict with frontmost app)

    private func registerCarbonFallback(for name: KeyboardShortcuts.Name) {
        guard !carbonRegistered.contains(name) else { return }
        carbonRegistered.insert(name)
        KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
            guard let self else { return }
            self.fireCarbon(name: name)
        }
    }

    private func reregisterCarbonFallbacks() {
        for name in carbonRegistered {
            KeyboardShortcuts.removeHandler(for: name)
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                guard let self else { return }
                self.fireCarbon(name: name)
            }
        }
    }

    private func fireCarbon(name: KeyboardShortcuts.Name) {
        guard KeyboardShortcuts.isEnabled, !PauseManager.shared.isPaused else { return }
        guard let registration = registrations.first(where: { $0.name == name }),
              registration.isEnabled() else { return }
        registration.onKeyDown()
    }

    private func refreshShortcutCache() {
        cachedShortcuts = Dictionary(uniqueKeysWithValues:
            registrations.compactMap { reg in
                guard let shortcut = KeyboardShortcuts.getShortcut(for: reg.name) else { return nil }
                return (reg.name, shortcut)
            })
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort {
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        guard KeyboardShortcuts.isEnabled, !PauseManager.shared.isPaused else {
            return Unmanaged.passUnretained(event)
        }

        for registration in registrations {
            guard registration.isEnabled(),
                  let shortcut = cachedShortcuts[registration.name],
                  HotkeyEventMatch.matches(event, shortcut: shortcut)
            else { continue }

            DispatchQueue.main.async { registration.onKeyDown() }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

private func globalHotkeyTapCallback(proxy: CGEventTapProxy,
                                     type: CGEventType,
                                     event: CGEvent,
                                     userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<GlobalHotkeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
