import Foundation
import KeyboardShortcuts

/// Global kill switch ("Pause Fuse" in the status-bar menu).
/// Pausing disables every KeyboardShortcuts hotkey app-wide and notifies
/// continuously-running services (scroll tap, clipboard watcher, notification
/// auto-clear timer, voice recorder) to stand down.
/// Deliberately NOT persisted: a relaunch always starts un-paused.
final class PauseManager {
    static let shared = PauseManager()
    static let pauseStateChanged = Notification.Name("com.rgv250cc.fuse.pauseStateChanged")

    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        KeyboardShortcuts.isEnabled = !paused
        NotificationCenter.default.post(name: Self.pauseStateChanged, object: self)
    }

    func toggle() {
        setPaused(!isPaused)
    }
}
