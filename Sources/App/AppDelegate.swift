import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

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
        // FUSE:MENU-ITEMS
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Fuse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // FUSE:CONTROLLER-START
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
