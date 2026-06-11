import AppKit

/// Live adapter: locates the Notification Center process and repeatedly
/// sweeps its windows' AX trees, performing "Clear All"/"Close" actions.
/// THREADING: AX calls block (synchronous IPC). `clearAll()` MUST run off
/// the main thread — NotificationsController uses a utility-QoS queue.
final class NotificationClearer {
    /// The Notification Center UI process. If this stops matching after a
    /// macOS update, probe with:
    ///   osascript -e 'tell application "System Events" to get bundle identifier of every process whose name contains "otification"'
    /// and update this constant (record a Deviation in the plan file).
    static let notificationCenterBundleID = "com.apple.notificationcenterui"

    /// Safety cap on sweep passes per clearAll() call.
    private let maxPasses: Int
    /// Pause between passes — the Notification Center UI needs time to
    /// collapse groups and reflow after actions are performed.
    private let interPassDelay: TimeInterval

    init(maxPasses: Int = 10, interPassDelay: TimeInterval = 0.25) {
        self.maxPasses = maxPasses
        self.interPassDelay = interPassDelay
    }

    /// Sweeps until a pass performs 0 actions or maxPasses is hit.
    /// Returns the total number of clear actions performed.
    func clearAll() -> Int {
        guard PermissionsService.hasAccessibility else {
            Log.notifications.error("clearAll: Accessibility permission missing; prompting")
            DispatchQueue.main.async {
                PermissionsService.promptForAccessibility()
            }
            return 0
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == NotificationClearer.notificationCenterBundleID
        }) else {
            Log.notifications.error("clearAll: Notification Center process not found for bundle id \(NotificationClearer.notificationCenterBundleID, privacy: .public)")
            return 0
        }

        let root = AXElement.application(pid: app.processIdentifier)
        var total = 0
        for pass in 1...maxPasses {
            var performedThisPass = 0
            // root.windows is re-fetched every pass; with zero notifications
            // the window list is typically empty, so this returns instantly.
            for window in root.windows {
                performedThisPass += NotificationSweep.performSweep(root: window, maxDepth: 12)
            }
            total += performedThisPass
            Log.notifications.debug("clearAll pass \(pass): performed \(performedThisPass) action(s)")
            if performedThisPass == 0 { break }
            Thread.sleep(forTimeInterval: interPassDelay)
        }
        Log.notifications.info("clearAll finished: \(total) action(s) performed in total")
        return total
    }
}
