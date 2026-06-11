import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    private var scrollController: ScrollEventTapController!
    private var tilingController: TilingController!
    private var clipboardController: ClipboardController!
    private var voiceController: VoiceController!
    private var downloaderController: DownloaderController!
    private var notificationsController: NotificationsController!
    private var clearNotificationsMenuItem: NSMenuItem!
    private var notesController: NotesController!
    private var notesMenuItem: NSMenuItem!
    private var captureController: CaptureController!
    private var captureRegionMenuItem: NSMenuItem!
    private var recordingMenuItem: NSMenuItem!
    private var screenshotsFolderMenuItem: NSMenuItem!
    private var recordingsFolderMenuItem: NSMenuItem!
    // FUSE:CONTROLLER-PROPS

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests launch this app; never start OS hooks inside a test run.
        guard NSClassFromString("XCTestCase") == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "bolt.circle.fill",
            accessibilityDescription: "Fuse")

        let menu = NSMenu()
        let pauseItem = NSMenuItem(title: "Pause Fuse", action: #selector(togglePause(_:)), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        if downloaderController == nil { downloaderController = DownloaderController() }
        let downloadsItem = NSMenuItem(title: "Downloads…",
                                       action: #selector(DownloaderController.openDownloadsWindow),
                                       keyEquivalent: "")
        downloadsItem.target = downloaderController
        menu.addItem(downloadsItem)
        let clipboardDownloadItem = NSMenuItem(title: "Download URL from Clipboard",
                                               action: #selector(DownloaderController.downloadFromClipboard),
                                               keyEquivalent: "")
        clipboardDownloadItem.target = downloaderController
        menu.addItem(clipboardDownloadItem)
        clearNotificationsMenuItem = NSMenuItem(
            title: "Clear Notifications",
            action: #selector(NotificationsController.clearNow),
            keyEquivalent: "")
        menu.addItem(clearNotificationsMenuItem)
        notesMenuItem = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        menu.addItem(notesMenuItem)
        captureRegionMenuItem = NSMenuItem(
            title: "Capture Region",
            action: #selector(CaptureController.captureRegionFromMenu),
            keyEquivalent: "")
        menu.addItem(captureRegionMenuItem)
        recordingMenuItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(CaptureController.toggleRecordingFromMenu),
            keyEquivalent: "")
        menu.addItem(recordingMenuItem)
        screenshotsFolderMenuItem = NSMenuItem(
            title: "Open Screenshots Folder",
            action: #selector(CaptureController.openScreenshotsFolderFromMenu),
            keyEquivalent: "")
        menu.addItem(screenshotsFolderMenuItem)
        recordingsFolderMenuItem = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(CaptureController.openRecordingsFolderFromMenu),
            keyEquivalent: "")
        menu.addItem(recordingsFolderMenuItem)
        // FUSE:MENU-ITEMS
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Fuse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        scrollController = ScrollEventTapController()
        scrollController.start()
        tilingController = TilingController()
        tilingController.start()
        clipboardController = ClipboardController()
        clipboardController?.start()
        voiceController = VoiceController.shared
        voiceController.start()
        if downloaderController == nil { downloaderController = DownloaderController() }
        downloaderController.start()
        notificationsController = NotificationsController()
        notificationsController.start()
        clearNotificationsMenuItem.target = notificationsController
        notesController = NotesController()
        notesController.start()
        notesMenuItem.target = notesController
        notesMenuItem.action = #selector(NotesController.toggleFromMenu)
        captureController = CaptureController()
        captureController.recordingMenuItem = recordingMenuItem
        captureController.start()
        captureRegionMenuItem.target = captureController
        recordingMenuItem.target = captureController
        screenshotsFolderMenuItem.target = captureController
        recordingsFolderMenuItem.target = captureController
        // FUSE:CONTROLLER-START

        // One-time coexistence check: if a known overlapping utility is running
        // on the very first launch, open Settings so the General banner is seen.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "core.didRunBefore") {
            defaults.set(true, forKey: "core.didRunBefore")
            if !ConflictDetector.currentConflicts().isEmpty {
                openSettings()
            }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            window.title = "Fuse Settings"
            window.contentView = NSHostingView(rootView: SettingsRootView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        PauseManager.shared.toggle()
        let paused = PauseManager.shared.isPaused
        sender.state = paused ? .on : .off
        sender.title = paused ? "Paused — click to resume" : "Pause Fuse"
        statusItem.button?.appearsDisabled = paused
    }
}
