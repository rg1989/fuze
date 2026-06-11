import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the clipboard feature: store, watcher, picker panel, and the
/// `.pastePicker` hotkey (⇧⌘V, defined in Core/HotkeyNames.swift).
final class ClipboardController {
    private let store: ClipboardStore
    private let watcher: PasteboardWatcher
    private let panel: PastePickerPanel
    private let model: PastePickerViewModel
    private var keyMonitor: Any?

    /// Returns nil only when the on-disk database can't be opened; the rest of
    /// the app keeps running without clipboard history.
    init?() {
        UserDefaults.standard.register(defaults: ["clipboard.enabled": true, "clipboard.maxItems": 500])
        guard let store = ClipboardStore.shared else {
            Log.clipboard.error("clipboard store unavailable — feature disabled")
            return nil
        }
        self.store = store
        self.watcher = PasteboardWatcher(store: store)
        self.model = PastePickerViewModel(store: store)
        self.panel = PastePickerPanel()
        panel.contentView = NSHostingView(rootView: PastePickerView(model: model))

        model.onPaste = { [weak self] item in self?.paste(item) }
        model.onClose = { [weak self] in self?.hidePicker() }
        panel.onResignKey = { [weak self] in self?.hidePicker() }

        // The ONLY hotkey this feature uses — never define new Name constants.
        KeyboardShortcuts.onKeyDown(for: .pastePicker) { [weak self] in
            self?.togglePicker()
        }
    }

    func start() { watcher.start() }

    func togglePicker() {
        if panel.isVisible { hidePicker() } else { showPicker() }
    }

    private func showPicker() {
        model.prepareForShow()
        panel.centerOnMouseScreen()
        panel.makeKeyAndOrderFront(nil)   // non-activating: previous app stays frontmost
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
            return self.model.handle(event: event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func paste(_ item: ClipboardItem) {
        guard let id = item.id else { return }
        hidePicker()
        // 80 ms lets keyboard focus settle back on the previously frontmost app
        // before PasteService writes the pasteboard and synthesizes ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [store] in
            do {
                let reps = try store.representations(forItem: id)
                guard !reps.isEmpty else { return }
                var representation: PasteService.ItemRepresentation = [:]
                for rep in reps { representation[NSPasteboard.PasteboardType(rep.type)] = rep.data }
                // Lossless paste of ALL stored representations. PasteService marks
                // the write internal, synthesizes ⌘V, and restores the previous
                // clipboard 0.6 s later; the watcher skips both internal writes.
                PasteService.paste([representation], restoreAfter: 0.6)
            } catch {
                Log.clipboard.error("paste failed: \(error.localizedDescription)")
            }
        }
    }
}
