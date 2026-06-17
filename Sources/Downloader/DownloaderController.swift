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

/// Owns the downloader feature: the shared DownloadQueue, a floating picker
/// (⇧⌘D from anywhere), and the full Downloads window (menu ⌘D).
@MainActor
final class DownloaderController: NSObject {
    let queue = DownloadQueue()
    private var downloadsWindow: NSWindow?
    private let panel = DownloadsPickerPanel()
    private let pickerModel: DownloadsPickerViewModel
    private var keyMonitor: Any?

    private static let lastUpdateCheckKey = "downloads.ytDlpLastUpdateCheck"

    override init() {
        pickerModel = DownloadsPickerViewModel(queue: queue)
        super.init()
        panel.contentView = NSHostingView(
            rootView: DownloadsPickerView(model: pickerModel, queue: queue))
        pickerModel.onClose = { [weak self] in self?.hidePicker() }
        panel.onResignKey = { [weak self] in self?.hidePicker() }
    }

    func start() {
        UserDefaults.standard.register(defaults: ["downloads.enabled": true])
        if !ToolManager.shared.ytDlpInstalled {
            Log.downloader.info("yt-dlp not installed; user must install from Settings → Downloads")
        }
        autoUpdateYtDlpIfDue()

        GlobalHotkeyTap.shared.register(.init(
            name: .openDownloads,
            isEnabled: { UserDefaults.standard.bool(forKey: "downloads.enabled") },
            onKeyDown: { [weak self] in
                Task { @MainActor in self?.togglePicker() }
            }))
    }

    /// Status-bar / File menu — toggles the floating picker (same as the global hotkey).
    @objc func togglePickerFromMenu() {
        togglePicker()
    }

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

    func togglePicker() {
        guard UserDefaults.standard.bool(forKey: "downloads.enabled") else { return }
        if panel.isVisible { hidePicker() } else { showPicker() }
    }

    private func showPicker() {
        pickerModel.prepareForShow()
        panel.centerOnMouseScreen()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private func hidePicker() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            return self.pickerModel.handle(event: event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
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
