import AppKit
import KeyboardShortcuts
import SwiftUI

/// Closes on Esc: cancelOperation(_:) reaches the window when no view in the
/// responder chain claims the key — standard utility-window behavior.
final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

/// Owns the downloader feature: the shared DownloadQueue and the Downloads window.
/// Menu items in AppDelegate target the two @objc actions below.
@MainActor
final class DownloaderController: NSObject {
    let queue = DownloadQueue()
    private var downloadsWindow: NSWindow?

    private static let lastUpdateCheckKey = "downloads.ytDlpLastUpdateCheck"

    func start() {
        UserDefaults.standard.register(defaults: ["downloads.enabled": true])
        // First-use flow: never auto-download the binary without user action.
        // DownloadsView shows an inline banner pointing at Settings → Downloads.
        if !ToolManager.shared.ytDlpInstalled {
            Log.downloader.info("yt-dlp not installed; user must install from Settings → Downloads")
        }
        autoUpdateYtDlpIfDue()

        // Global hotkey: open the Downloads window from anywhere, even when
        // Fuse isn't the active app (the ⌘D menu item only works when it is).
        KeyboardShortcuts.onKeyUp(for: .openDownloads) { [weak self] in
            self?.openDownloadsWindow()
        }
    }

    /// Keep an already-installed yt-dlp current so the downloader supports the
    /// widest range of sites over time (yt-dlp ships site fixes almost daily).
    /// Throttled to once per day; background, non-blocking, best-effort.
    private func autoUpdateYtDlpIfDue() {
        guard UserDefaults.standard.bool(forKey: "downloads.enabled"),
              ToolManager.shared.ytDlpInstalled else { return }
        let defaults = UserDefaults.standard
        let lastCheck = defaults.object(forKey: Self.lastUpdateCheckKey) as? Date
        guard ToolManager.shouldCheckForUpdate(
            now: Date(), lastCheck: lastCheck,
            minInterval: ToolManager.autoUpdateInterval) else { return }
        defaults.set(Date(), forKey: Self.lastUpdateCheckKey)
        Task.detached(priority: .background) {
            await ToolManager.shared.autoUpdateIfNeeded()
        }
    }

    @objc func openDownloadsWindow() {
        guard UserDefaults.standard.bool(forKey: "downloads.enabled") else { return }
        if downloadsWindow == nil {
            let window = EscClosableWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Fuse Downloads"
            window.contentView = NSHostingView(rootView: DownloadsView(queue: queue))
            window.isReleasedWhenClosed = false
            window.center()
            downloadsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        downloadsWindow?.makeKeyAndOrderFront(nil)
    }
}
