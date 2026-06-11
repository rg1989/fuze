import AppKit
import SwiftUI

/// Owns the downloader feature: the shared DownloadQueue and the Downloads window.
/// Menu items in AppDelegate target the two @objc actions below.
@MainActor
final class DownloaderController: NSObject {
    let queue = DownloadQueue()
    private var downloadsWindow: NSWindow?

    func start() {
        UserDefaults.standard.register(defaults: ["downloads.enabled": true])
        // First-use flow: never auto-download the binary without user action.
        // DownloadsView shows an inline banner pointing at Settings → Downloads.
        if !ToolManager.shared.ytDlpInstalled {
            Log.downloader.info("yt-dlp not installed; user must install from Settings → Downloads")
        }
    }

    @objc func openDownloadsWindow() {
        guard UserDefaults.standard.bool(forKey: "downloads.enabled") else { return }
        if downloadsWindow == nil {
            let window = NSWindow(
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
