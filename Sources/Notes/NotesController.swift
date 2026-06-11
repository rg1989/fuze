import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the notes feature: store, view model, panel, and the `.toggleNotesPanel`
/// hotkey (⌃⌥M, defined in Core/HotkeyNames.swift — NEVER define new Names).
final class NotesController {
    private let model: NotesViewModel?
    private var panel: NotesPanel?
    private var escMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        UserDefaults.standard.register(defaults: ["notes.panelPinned": false])
        if let store = NoteStore.shared {
            self.model = NotesViewModel(store: store)
        } else {
            // Feature inert: menu item/hotkey remain, toggle() shows an alert.
            Log.notes.error("notes store unavailable — feature inert")
            self.model = nil
        }
    }

    func start() {
        // The ONLY hotkey this feature uses.
        KeyboardShortcuts.onKeyDown(for: .toggleNotesPanel) { [weak self] in
            self?.toggle()
        }
    }

    /// Target of the "Notes" status-bar menu item (wired in AppDelegate).
    @objc func toggleFromMenu() {
        toggle()
    }

    func toggle() {
        guard let model else {
            showStoreUnavailableAlert()
            return
        }
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel(model: model)
        }
    }

    private func showPanel(model: NotesViewModel) {
        let panel = ensurePanel(model: model)
        model.reloadAll()
        panel.centerOnMouseScreen()
        // Non-activating: NO NSApp.activate — the previous app stays active.
        panel.makeKeyAndOrderFront(nil)
        installEscMonitor()
    }

    private func hidePanel() {
        removeEscMonitor()
        panel?.orderOut(nil)
    }

    private func ensurePanel(model: NotesViewModel) -> NotesPanel {
        if let panel { return panel }
        let newPanel = NotesPanel()
        newPanel.contentView = NSHostingView(rootView: NotesPanelView(model: model))
        // Auto-hide when the panel loses key status — unless the user pinned
        // it ("notes.panelPinned", settable in the Notes settings tab).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: newPanel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !UserDefaults.standard.bool(forKey: "notes.panelPinned") {
                self.hidePanel()
            }
        }
        panel = newPanel
        return newPanel
    }

    /// Esc (keyCode 53) hides the panel while it is the key window; the event
    /// is swallowed (return nil). EVERY other event is returned untouched so
    /// all typing reaches the SwiftUI text editors.
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel,
                  panel.isKeyWindow, event.keyCode == 53 else { return event }
            self.hidePanel()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    private func showStoreUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Notes unavailable"
        alert.informativeText = "Fuse could not open its notes database. "
            + "Check Console logs (subsystem com.rgv250cc.Fuse, category notes)."
        alert.alertStyle = .warning
        alert.runModal()
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        removeEscMonitor()
    }
}
