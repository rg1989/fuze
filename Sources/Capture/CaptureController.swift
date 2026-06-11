import AppKit
import KeyboardShortcuts

/// Owns the Capture feature: screenshot + recording services, the REC HUD,
/// hotkeys, status-menu actions, and the shared output pipeline
/// (timestamped save → clipboard copy → editor/trimmer → log).
final class CaptureController {
    private let screenshots = ScreenshotService()
    private let recorder = RecordingService()
    private let hud = RecHUD()

    /// Set by AppDelegate so the title can swap with recording state.
    weak var recordingMenuItem: NSMenuItem?

    static let defaultSaveFolder = NSHomeDirectory() + "/Desktop"
    static let fileURLType = NSPasteboard.PasteboardType("public.file-url")

    func start() {
        UserDefaults.standard.register(defaults: [
            "capture.saveFolderPath": Self.defaultSaveFolder,
            "capture.copyToClipboard": true,
            "capture.openEditorAfter": true,
        ])

        recorder.onPhaseChange = { [weak self] phase in
            if phase == .recording {
                self?.hud.show()
            } else if phase == .idle {
                self?.hud.hide()
            }
            self?.refreshMenuTitle()
        }
        recorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.hud.hide()
            self.refreshMenuTitle()
            guard let url,
                  let size = (try? FileManager.default
                      .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
                  size > 0
            else {
                Log.capture.info("recording produced no file; nothing to save")
                return
            }
            self.runOutputPipeline(tempURL: url, kind: .recording)
        }
        hud.onStop = { [weak self] in self?.recorder.stop() }

        // Hotkeys are automatically silenced by PauseManager via
        // KeyboardShortcuts.isEnabled — no pause handling needed here.
        KeyboardShortcuts.onKeyUp(for: .captureRegion) { [weak self] in
            self?.captureRegion()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.recorder.toggle()
        }
    }

    // MARK: - Entry points (menu items target these)

    @objc func captureRegionFromMenu() { captureRegion() }
    @objc func toggleRecordingFromMenu() { recorder.toggle() }

    private func captureRegion() {
        guard !screenshots.isRunning else { return }
        screenshots.captureInteractive { [weak self] url in
            guard let self, let url else { return }   // nil = user pressed Esc
            self.runOutputPipeline(tempURL: url, kind: .screenshot)
        }
    }

    private func refreshMenuTitle() {
        recordingMenuItem?.title = recorder.isRecording ? "Stop Recording" : "Start Recording"
    }

    // MARK: - Shared output pipeline

    private func runOutputPipeline(tempURL: URL, kind: CaptureKind) {
        let defaults = UserDefaults.standard
        let folder = defaults.string(forKey: "capture.saveFolderPath") ?? Self.defaultSaveFolder
        let dest = URL(fileURLWithPath: folder)
            .appendingPathComponent(CaptureNames.fileName(kind: kind, date: Date()))
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: folder), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            Log.capture.error("failed to move capture into place: \(error.localizedDescription, privacy: .public)")
            return
        }

        if defaults.bool(forKey: "capture.copyToClipboard") {
            copyToClipboard(dest, kind: kind)
        }
        if defaults.bool(forKey: "capture.openEditorAfter") {
            openInEditor(dest, kind: kind)
        }
        Log.capture.info("capture saved: \(dest.path, privacy: .public)")
    }

    private func copyToClipboard(_ url: URL, kind: CaptureKind) {
        let urlData = url.dataRepresentation
        switch kind {
        case .screenshot:
            guard let pngData = try? Data(contentsOf: url) else { return }
            // markInternal: false is LOAD-BEARING — Fuse's own clipboard
            // history must record this item (the watcher skips marked items).
            PasteService.write([[.png: pngData], [Self.fileURLType: urlData]],
                               markInternal: false)
        case .recording:
            PasteService.write([[Self.fileURLType: urlData]], markInternal: false)
        }
    }

    private func openInEditor(_ url: URL, kind: CaptureKind) {
        switch kind {
        case .screenshot:
            // Replaced in Task 10.6 with the built-in annotation editor.
            NSWorkspace.shared.open(url)
        case .recording:
            // Replaced in Task 10.7 with the built-in trimmer.
            NSWorkspace.shared.open(url)
        }
    }
}
