import AppKit
import KeyboardShortcuts

/// Owns the Capture feature: screenshot + recording services, the REC HUD,
/// hotkeys, status-menu actions, and the shared output pipeline
/// (timestamped save → clipboard copy → editor/trimmer → log).
final class CaptureController {
    private let screenshots = ScreenshotService()
    private let recorder = RecordingService()
    private let hud = RecHUD()
    private var imageEditors: [ImageEditorWindowController] = []
    private var videoTrimmers: [VideoTrimmerWindowController] = []
    private var previews: [CapturePreviewWindowController] = []

    /// Set by AppDelegate so the title can swap with recording state.
    weak var recordingMenuItem: NSMenuItem?

    static let defaultScreenshotFolder = NSHomeDirectory() + "/Pictures/Fuse Screenshots"
    static let defaultRecordingFolder = NSHomeDirectory() + "/Movies/Fuse Recordings"
    static let fileURLType = NSPasteboard.PasteboardType("public.file-url")

    func start() {
        migrateLegacySaveFolder()
        UserDefaults.standard.register(defaults: [
            "capture.screenshotFolderPath": Self.defaultScreenshotFolder,
            "capture.recordingFolderPath": Self.defaultRecordingFolder,
            "capture.copyToClipboard": true,
            "capture.showPreviewAfter": true,
            "capture.imageFormat": "png",
            "capture.videoFormat": "mp4",
        ])

        recorder.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .armed:
                self.hud.showArmed(near: self.recorder.currentRegion)
            case .recording:
                self.hud.show(near: self.recorder.currentRegion)
            case .idle, .finishing:
                self.hud.hide()
            case .selectingRegion:
                break
            }
            self.refreshMenuTitle()
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
            let format = UserDefaults.standard.string(forKey: "capture.videoFormat") ?? "mp4"
            VideoRemuxer.remuxIfNeeded(url, to: format) { [weak self] finalURL in
                self?.runOutputPipeline(tempURL: finalURL, kind: .recording)
            }
        }
        hud.onStop = { [weak self] in self?.recorder.stop() }
        hud.onStart = { [weak self] in self?.recorder.startArmed() }
        hud.onCancel = { [weak self] in self?.recorder.cancelArmed() }

        // Hotkeys are automatically silenced by PauseManager via
        // KeyboardShortcuts.isEnabled — no pause handling needed here.
        KeyboardShortcuts.onKeyUp(for: .captureRegion) { [weak self] in
            self?.captureRegion()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.recorder.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .openScreenshotsFolder) { [weak self] in
            self?.openFolder(for: .screenshot)
        }
        KeyboardShortcuts.onKeyUp(for: .openRecordingsFolder) { [weak self] in
            self?.openFolder(for: .recording)
        }
    }

    /// One-time migration: a user-customized legacy single save folder seeds
    /// both per-kind folders; the untouched default (Desktop) is dropped in
    /// favor of the new dedicated folders.
    private func migrateLegacySaveFolder() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: "capture.saveFolderPath") else { return }
        if defaults.object(forKey: "capture.screenshotFolderPath") == nil {
            defaults.set(legacy, forKey: "capture.screenshotFolderPath")
        }
        if defaults.object(forKey: "capture.recordingFolderPath") == nil {
            defaults.set(legacy, forKey: "capture.recordingFolderPath")
        }
        defaults.removeObject(forKey: "capture.saveFolderPath")
    }

    // MARK: - Entry points (menu items target these)

    @objc func captureRegionFromMenu() { captureRegion() }
    @objc func toggleRecordingFromMenu() { recorder.toggle() }
    @objc func openScreenshotsFolderFromMenu() { openFolder(for: .screenshot) }
    @objc func openRecordingsFolderFromMenu() { openFolder(for: .recording) }

    private func folderPath(for kind: CaptureKind) -> String {
        let defaults = UserDefaults.standard
        switch kind {
        case .screenshot:
            return defaults.string(forKey: "capture.screenshotFolderPath") ?? Self.defaultScreenshotFolder
        case .recording:
            return defaults.string(forKey: "capture.recordingFolderPath") ?? Self.defaultRecordingFolder
        }
    }

    private func openFolder(for kind: CaptureKind) {
        let url = URL(fileURLWithPath: folderPath(for: kind), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

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
        let folder = folderPath(for: kind)
        let ext = tempURL.pathExtension.isEmpty ? nil : tempURL.pathExtension
        let dest = URL(fileURLWithPath: folder)
            .appendingPathComponent(CaptureNames.fileName(kind: kind, date: Date(), fileExtension: ext))
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

        var clipboardChangeCount: Int?
        if defaults.bool(forKey: "capture.copyToClipboard") {
            copyToClipboard(dest, kind: kind)
            // Remembered so a later Delete only clears the clipboard when
            // Fuse's copy is still the current item.
            clipboardChangeCount = NSPasteboard.general.changeCount
        }
        if defaults.bool(forKey: "capture.showPreviewAfter") {
            showPreview(for: dest, kind: kind, clipboardChangeCount: clipboardChangeCount)
        }
        Log.capture.info("capture saved: \(dest.path, privacy: .public)")
    }

    // MARK: - Post-capture preview (Keep / Delete / Edit)

    private func showPreview(for url: URL, kind: CaptureKind, clipboardChangeCount: Int?) {
        let preview = CapturePreviewWindowController(fileURL: url, kind: kind)
        preview.onKeep = { [weak preview] in
            preview?.close()
        }
        preview.onDelete = { [weak self, weak preview] in
            self?.discardCapture(at: url, kind: kind, clipboardChangeCount: clipboardChangeCount)
            preview?.close()
        }
        preview.onEdit = { [weak self, weak preview] in
            preview?.close()
            self?.openInEditor(url, kind: kind)
        }
        preview.onClose = { [weak self, weak preview] in
            self?.previews.removeAll { $0 === preview }
        }
        previews.append(preview)
        preview.show()
    }

    /// Delete semantics: file → Trash, system clipboard cleared when Fuse's
    /// copy is still current, and the item purged from clipboard history.
    private func discardCapture(at url: URL, kind: CaptureKind, clipboardChangeCount: Int?) {
        // Build history-matching representations BEFORE trashing — screenshots
        // are matched by their image bytes (the watcher stores the first
        // pasteboard item, which for screenshots is the image, not the URL).
        var representations: [(type: String, data: Data)] = [
            (Self.fileURLType.rawValue, url.dataRepresentation),
        ]
        if kind == .screenshot, let imageData = try? Data(contentsOf: url) {
            let imageType = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
                ? "public.jpeg" : "public.png"
            representations.append((imageType, imageData))
        }
        if let store = ClipboardStore.shared {
            try? store.deleteItems(withRepresentations: representations)
        }

        if let clipboardChangeCount,
           NSPasteboard.general.changeCount == clipboardChangeCount {
            NSPasteboard.general.clearContents()
        }

        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            Log.capture.info("capture discarded to Trash: \(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.capture.error("failed to trash discarded capture: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func copyToClipboard(_ url: URL, kind: CaptureKind) {
        let urlData = url.dataRepresentation
        switch kind {
        case .screenshot:
            guard let imageData = try? Data(contentsOf: url) else { return }
            let imageType: NSPasteboard.PasteboardType =
                ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
                    ? NSPasteboard.PasteboardType("public.jpeg") : .png
            // markInternal: false is LOAD-BEARING — Fuse's own clipboard
            // history must record this item (the watcher skips marked items).
            PasteService.write([[imageType: imageData], [Self.fileURLType: urlData]],
                               markInternal: false)
        case .recording:
            PasteService.write([[Self.fileURLType: urlData]], markInternal: false)
        }
    }

    private func openInEditor(_ url: URL, kind: CaptureKind) {
        switch kind {
        case .screenshot:
            guard let editor = ImageEditorWindowController(fileURL: url) else {
                NSWorkspace.shared.open(url)   // unreadable PNG — fall back
                return
            }
            editor.onClose = { [weak self, weak editor] in
                self?.imageEditors.removeAll { $0 === editor }
            }
            imageEditors.append(editor)
            editor.show()
        case .recording:
            let trimmer = VideoTrimmerWindowController(fileURL: url)
            trimmer.onClose = { [weak self, weak trimmer] in
                self?.videoTrimmers.removeAll { $0 === trimmer }
            }
            videoTrimmers.append(trimmer)
            trimmer.show()
        }
    }
}
