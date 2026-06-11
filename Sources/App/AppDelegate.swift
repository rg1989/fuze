import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    private var scrollController: ScrollEventTapController!
    private var tilingController: TilingController!
    private var clipboardController: ClipboardController!
    private var voiceController: VoiceController!
    private var downloaderController: DownloaderController!
    private var downloadsMenuItem: NSMenuItem!
    private var notificationsController: NotificationsController!
    private var clearNotificationsMenuItem: NSMenuItem!
    private var notesController: NotesController!
    private var notesMenuItem: NSMenuItem!
    private var captureController: CaptureController!
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
        // Enabled state is driven by the module switches via menuNeedsUpdate,
        // not by the responder chain.
        menu.autoenablesItems = false
        menu.delegate = self
        let pauseItem = menuItem("Pause Fuse", icon: "pause.circle",
                                 action: #selector(togglePause(_:)))
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let settingsItem = menuItem("Settings…", icon: "gearshape",
                                    action: #selector(openSettings), key: ",")
        menu.addItem(settingsItem)
        if downloaderController == nil { downloaderController = DownloaderController() }
        downloadsMenuItem = menuItem("Downloads…", icon: "arrow.down.circle",
                                     action: #selector(DownloaderController.openDownloadsWindow),
                                     key: "d")
        downloadsMenuItem.target = downloaderController
        menu.addItem(downloadsMenuItem)
        clearNotificationsMenuItem = menuItem("Clear Notifications", icon: "bell.badge",
                                              action: #selector(NotificationsController.clearNow))
        menu.addItem(clearNotificationsMenuItem)
        notesMenuItem = menuItem("Notes", icon: "note.text", action: nil)
        menu.addItem(notesMenuItem)
        screenshotsFolderMenuItem = menuItem(
            "Open Screenshots Folder", icon: "photo",
            action: #selector(CaptureController.openScreenshotsFolderFromMenu))
        menu.addItem(screenshotsFolderMenuItem)
        recordingsFolderMenuItem = menuItem(
            "Open Recordings Folder", icon: "film",
            action: #selector(CaptureController.openRecordingsFolderFromMenu))
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
        captureController.start()
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

    /// Gray out menu items whose module is switched off (General → Fused apps).
    /// The folder openers stay live regardless — they are plain Finder
    /// shortcuts, useful even while Capture itself is off.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let defaults = UserDefaults.standard
        downloadsMenuItem.isEnabled = defaults.bool(forKey: "downloads.enabled")
        clearNotificationsMenuItem.isEnabled = defaults.bool(forKey: "notifications.enabled")
        notesMenuItem.isEnabled = defaults.bool(forKey: "notes.enabled")
    }

    private func menuItem(_ title: String, icon: String,
                          action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        return item
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
