import AppKit
import KeyboardShortcuts

/// Owns the clear-notifications hotkey, the status-bar menu action, the
/// optional auto-clear timer, and the background queue all sweeps run on.
/// NSObject subclass: NSMenuItem target/action requires ObjC messaging.
final class NotificationsController: NSObject {
    static let autoClearEnabledKey = "notifications.autoClearEnabled"
    static let autoClearIntervalKey = "notifications.autoClearIntervalMinutes"

    private let clearer = NotificationClearer()
    /// AX calls block; every sweep runs here, never on the main thread.
    private let queue = DispatchQueue(label: "com.rgv250cc.Fuse.notifications", qos: .utility)
    private var autoClearTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?

    /// Call once from applicationDidFinishLaunching (after its XCTestCase
    /// guard, so hotkeys/timers never start inside hosted test runs).
    func start() {
        UserDefaults.standard.register(defaults: [
            "notifications.enabled": true,
            Self.autoClearEnabledKey: false,
            Self.autoClearIntervalKey: 30,
        ])

        KeyboardShortcuts.onKeyDown(for: .clearNotifications) { [weak self] in
            self?.clearNow()
        }

        rebuildAutoClearTimer()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            self?.rebuildAutoClearTimer()
        }

        Log.notifications.info("NotificationsController started")
    }

    /// Hotkey, menu item, and auto-clear timer all funnel through here.
    /// Main-thread safe: the AX work is dispatched to the utility queue.
    @objc func clearNow() {
        // Master switch (General → Fused apps): hotkey, menu item, and the
        // auto-clear timer all funnel through here.
        guard UserDefaults.standard.bool(forKey: "notifications.enabled") else { return }
        queue.async { [clearer] in
            let performed = clearer.clearAll()
            Log.notifications.info("clearNow: \(performed) clear action(s) performed")
        }
    }

    // MARK: - Auto-clear timer

    private var isAutoClearEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoClearEnabledKey)
    }

    private var autoClearIntervalMinutes: Int {
        min(240, max(5, UserDefaults.standard.integer(forKey: Self.autoClearIntervalKey)))
    }

    /// Runs on the main queue. UserDefaults.didChangeNotification fires for
    /// ANY default change, so this early-returns unless the effective timer
    /// configuration actually changed.
    private func rebuildAutoClearTimer() {
        let wanted: TimeInterval? = isAutoClearEnabled ? TimeInterval(autoClearIntervalMinutes * 60) : nil
        let current: TimeInterval? = autoClearTimer.map { $0.timeInterval }
        guard wanted != current else { return }

        autoClearTimer?.invalidate()
        autoClearTimer = nil

        guard let interval = wanted else {
            Log.notifications.info("auto-clear disabled")
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard !PauseManager.shared.isPaused else { return }   // pause = no automation
            self?.clearNow()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        autoClearTimer = timer
        Log.notifications.info("auto-clear enabled, every \(Int(interval / 60)) min")
    }

    deinit {
        autoClearTimer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }
}
