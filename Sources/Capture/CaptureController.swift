import AppKit
import KeyboardShortcuts

/// Owns the Capture feature: screenshot + recording services, the REC HUD,
/// hotkeys, status-menu actions, and the shared output pipeline
/// (timestamped save → clipboard copy → editor/trimmer → log).
final class CaptureController {
    private let screenshots = ScreenshotService()
    private let recorder = RecordingService()
    private let hud = RecHUD()
    private var reviews: [CaptureReviewWindowController] = []
    private var historyObserver: NSObjectProtocol?

    static let defaultScreenshotFolder = NSHomeDirectory() + "/Pictures/Fuse Screenshots"
    static let defaultRecordingFolder = NSHomeDirectory() + "/Movies/Fuse Recordings"
    static let fileURLType = NSPasteboard.PasteboardType("public.file-url")

    func start() {
        migrateLegacySaveFolder()
        UserDefaults.standard.register(defaults: [
            "capture.enabled": true,
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
        }
        recorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.hud.hide()
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

        // Reclaim staged "Delete & Copy" clips: orphans on launch, then every
        // time the clipboard history evicts entries (prune, delete, clear).
        sweepStagedClips()
        historyObserver = NotificationCenter.default.addObserver(
            forName: ClipboardStore.didRemoveItems, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sweepStagedClips()
        }

        // Hotkeys are automatically silenced by PauseManager via
        // KeyboardShortcuts.isEnabled — no pause handling needed here.
        KeyboardShortcuts.onKeyUp(for: .captureRegion) { [weak self] in
            self?.captureRegion()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            guard let self else { return }
            // Master switch — but an in-flight session can always be stopped.
            guard UserDefaults.standard.bool(forKey: "capture.enabled")
                || self.recorder.phase != .idle else { return }
            self.recorder.toggle()
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
        guard UserDefaults.standard.bool(forKey: "capture.enabled") else { return }
        guard !screenshots.isRunning else { return }
        screenshots.captureInteractive { [weak self] url in
            guard let self, let url else { return }   // nil = user pressed Esc
            self.runOutputPipeline(tempURL: url, kind: .screenshot)
        }
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

        // The review window owns all clipboard decisions now — nothing is
        // copied until the user picks a Copy action. Auto-copy only applies
        // in silent mode (review window disabled).
        if defaults.bool(forKey: "capture.showPreviewAfter") {
            showReview(for: dest, kind: kind)
        } else if defaults.bool(forKey: "capture.copyToClipboard") {
            copyToClipboard(dest, kind: kind)
        }
        Log.capture.info("capture saved: \(dest.path, privacy: .public)")
    }

    // MARK: - Post-capture review (Delete / Delete & Copy / Save / Save & Copy)

    private func showReview(for url: URL, kind: CaptureKind) {
        guard let review = CaptureReviewWindowController(fileURL: url, kind: kind) else {
            return   // unreadable screenshot — already saved; nothing to review
        }
        review.onAction = { [weak self, weak review] action in
            guard let self, let review else { return }
            self.perform(action, on: url, kind: kind, review: review)
        }
        review.onClose = { [weak self, weak review] in
            self?.reviews.removeAll { $0 === review }
        }
        reviews.append(review)
        review.show()
    }

    private func perform(_ action: ReviewAction, on url: URL, kind: CaptureKind,
                         review: CaptureReviewWindowController) {
        switch kind {
        case .screenshot:
            performScreenshotAction(action, on: url, state: review.imageState)
            review.close()
        case .recording:
            performRecordingAction(action, on: url, state: review.videoState,
                                   review: review)
        }
    }

    private func performScreenshotAction(_ action: ReviewAction, on url: URL,
                                         state: ImageEditorState?) {
        // Bake annotations/crop BEFORE copying so a copied file URL points
        // at the final pixels.
        if action.keepsFile, let state, !state.isPristine {
            state.save()
        }
        if action.copiesToClipboard, let state,
           let data = state.clipboardImageData() {
            var items: [[NSPasteboard.PasteboardType: Data]] = [[.png: data]]
            if action.keepsFile {
                items.append([Self.fileURLType: url.dataRepresentation])
            }
            // markInternal: false is LOAD-BEARING — Fuse's own clipboard
            // history must record this item (the watcher skips marked items).
            PasteService.write(items, markInternal: false)
        }
        if !action.keepsFile {
            trashCapture(at: url)
        }
    }

    private func performRecordingAction(_ action: ReviewAction, on url: URL,
                                        state: VideoReviewState?,
                                        review: CaptureReviewWindowController) {
        state?.player.pause()
        let trim = state?.pendingTrim

        func finish(copying fileURL: URL?) {
            if action.copiesToClipboard, let fileURL {
                PasteService.write([[Self.fileURLType: fileURL.dataRepresentation]],
                                   markInternal: false)
            }
            review.close()
        }

        if action.keepsFile {
            if let trim {
                VideoExporter.trimInPlace(url: url, range: trim) { _ in
                    finish(copying: url)   // trim failure still keeps the original
                }
            } else {
                finish(copying: url)
            }
            return
        }

        // Delete variants.
        guard action.copiesToClipboard else {
            trashCapture(at: url)
            finish(copying: nil)
            return
        }
        // Delete & Copy: a clipboard file URL must stay readable, so the clip
        // moves to the app-managed staging folder, where it lives exactly as
        // long as its clipboard-history entry does (see ClipboardStaging).
        do {
            if let trim {
                let staged = try ClipboardStaging.reserveURL(forFileName: url.lastPathComponent)
                VideoExporter.exportTrimmed(source: url, range: trim, to: staged) { [weak self] ok in
                    self?.trashCapture(at: url)
                    finish(copying: ok ? staged : nil)
                }
            } else {
                finish(copying: try ClipboardStaging.stage(url))
            }
        } catch {
            Log.capture.error("failed to stage clip for clipboard: \(error.localizedDescription, privacy: .public)")
            finish(copying: nil)
        }
    }

    /// Staged clips live only while a clipboard-history item references them.
    private func sweepStagedClips() {
        var referenced: Set<String> = []
        if let store = ClipboardStore.shared {
            referenced = (try? store.referencedFilePaths(under: ClipboardStaging.directory)) ?? []
        }
        ClipboardStaging.sweep(referencedPaths: referenced)
    }

    private func trashCapture(at url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            Log.capture.info("capture discarded to Trash: \(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.capture.error("failed to trash capture: \(error.localizedDescription, privacy: .public)")
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

}
