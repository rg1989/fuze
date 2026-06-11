import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    private var notesController: NotesController!
    private var notesMenuItem: NSMenuItem!
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
        notesMenuItem = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
        menu.addItem(notesMenuItem)
        // FUSE:MENU-ITEMS
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Fuse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        notesController = NotesController()
        notesController.start()
        notesMenuItem.target = notesController
        notesMenuItem.action = #selector(NotesController.toggleFromMenu)
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
