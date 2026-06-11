import AppKit
import SwiftUI

/// Owns the downloader feature: the shared DownloadQueue and the Downloads window.
/// Menu items in AppDelegate target the two @objc actions below.
@MainActor
final class DownloaderController: NSObject {
    let queue = DownloadQueue()
    private var downloadsWindow: NSWindow?

    func start() {
        // First-use flow: never auto-download the binary without user action.
        // DownloadsView shows an inline banner pointing at Settings → Downloads.
        if !ToolManager.shared.ytDlpInstalled {
            Log.downloader.info("yt-dlp not installed; user must install from Settings → Downloads")
        }
    }

    @objc func openDownloadsWindow() {
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

    @objc func downloadFromClipboard() {
        openDownloadsWindow()
        guard let text = NSPasteboard.general.string(forType: .string) else {
            Log.downloader.info("clipboard download requested but pasteboard has no string")
            return
        }
        if !queue.add(url: text) {
            Log.downloader.info("clipboard text is not an http(s) URL")
        }
    }
}
