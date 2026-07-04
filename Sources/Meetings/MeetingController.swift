import AppKit
import KeyboardShortcuts
import SwiftUI

/// Owns the Meetings feature — mirrors DownloaderController. Holds the store, the
/// floating transcript-library panel, the live meeting window, the record flow,
/// and the hotkey/menu bridges. `EscClosableWindow` is reused from
/// DownloaderController.swift (same module).
@MainActor
final class MeetingController: NSObject {
    private let store = MeetingStore.shared
    private let panel = TranscriptLibraryPanel()
    private let libraryModel: TranscriptLibraryViewModel
    private var meetingWindow: NSWindow?
    private var detailWindow: NSWindow?
    private var keyMonitor: Any?
    private var pauseObserver: NSObjectProtocol?

    // Live session. `hub != nil` ⇔ recording. `isStarting`/`isStopping` guard the
    // async gaps in begin/stop so a rapid double-trigger can't start two engines
    // or save twice.
    private var hub: MeetingAudioHub?
    private var transcriber: MeetingTranscriber?
    private var sessionMode: AudioSourceMode = .micOnly
    private var sessionStart = Date()
    private var isStarting = false
    private var isStopping = false

    private var isRecording: Bool { hub != nil }
    private var isBusy: Bool { isRecording || isStarting }

    override init() {
        libraryModel = TranscriptLibraryViewModel(store: store)
        super.init()
        panel.contentView = NSHostingView(rootView: TranscriptLibraryView(model: libraryModel))
        libraryModel.onClose = { [weak self] in self?.hideLibrary() }
        libraryModel.onOpen = { [weak self] meeting in self?.openTranscript(meeting) }
    }

    func start() {
        UserDefaults.standard.register(defaults: [
            "meetings.enabled": true,
            "meetings.audioSource": AudioSourceMode.micOnly.rawValue,
            "meetings.cleanupOnStop": true,
            "meetings.removeFillers": true,
        ])
        GlobalHotkeyTap.shared.register(.init(
            name: .toggleMeeting,
            isEnabled: { UserDefaults.standard.bool(forKey: "meetings.enabled") },
            onKeyDown: { [weak self] in Task { @MainActor in self?.toggleRecording() } }))

        // Recording is meaningless while Fuse is paused — stop and discard.
        pauseObserver = NotificationCenter.default.addObserver(
            forName: PauseManager.pauseStateChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, PauseManager.shared.isPaused, self.isRecording else { return }
                await self.stopRecording(discard: true)
            }
        }
    }

    // MARK: Menu bridges
    @objc func openLibraryFromMenu() { toggleLibrary() }
    @objc func toggleRecordingFromMenu() { toggleRecording() }

    // MARK: Library panel (mirrors DownloaderController show/hide + key monitor)
    private func toggleLibrary() {
        guard UserDefaults.standard.bool(forKey: "meetings.enabled") else { return }
        panel.isVisible ? hideLibrary() : showLibrary()
    }
    private func showLibrary() {
        libraryModel.prepareForShow()
        panel.centerOnMouseScreen()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }
    private func hideLibrary() { removeKeyMonitor(); panel.orderOut(nil) }
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isVisible else { return e }
            return self.libraryModel.handle(event: e) ? nil : e
        }
    }
    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: Record lifecycle
    private func toggleRecording() {
        guard UserDefaults.standard.bool(forKey: "meetings.enabled") else { return }
        if isRecording { Task { await stopRecording(discard: false) } } else { openMeetingWindow() }
    }

    /// Opens (or focuses) the live meeting window. When not busy, binds it to a
    /// FRESH transcriber so each meeting starts clean.
    @objc func openMeetingWindow() {
        guard UserDefaults.standard.bool(forKey: "meetings.enabled") else { return }
        if !isBusy {
            let vm = MeetingTranscriber()
            transcriber = vm
            if meetingWindow == nil {
                let w = EscClosableWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered, defer: false)
                w.title = "Fuse Meeting"
                w.isReleasedWhenClosed = false
                w.delegate = self       // intercept close-during-recording
                w.center()
                meetingWindow = w
            }
            meetingWindow?.contentView = NSHostingView(
                rootView: MeetingWindowView(transcriber: vm, controller: self))
        }
        NSApp.activate(ignoringOtherApps: true)
        meetingWindow?.makeKeyAndOrderFront(nil)
    }

    /// Called by the window's Record button once the user picks a source.
    func beginSession(mode: AudioSourceMode) {
        guard !isBusy, transcriber != nil else { return }
        isStarting = true   // set synchronously so a second trigger this turn is rejected
        UserDefaults.standard.set(mode.rawValue, forKey: "meetings.audioSource")
        sessionMode = mode
        // TCC: mic always; Screen Recording only for mic+system.
        PermissionsService.requestMicrophone { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.transcriber?.markFailed("Microphone permission denied")
                    self.isStarting = false
                    return
                }
                if mode.needsScreenRecording, !PermissionsService.hasScreenRecording {
                    PermissionsService.promptForScreenRecording()
                    PermissionsService.openSystemSettings(pane: .screenRecording)
                    self.transcriber?.markFailed("Grant Screen Recording, then press Record again")
                    self.isStarting = false
                    return   // reuses Fuse's existing grant if already held (no prompt)
                }
                await self.launch(mode: mode)
            }
        }
    }

    private func launch(mode: AudioSourceMode) async {
        defer { isStarting = false }
        guard let transcriber else { return }
        do {
            try await transcriber.load()
            guard !PauseManager.shared.isPaused else {
                await transcriber.teardown()
                transcriber.markFailed("Fuse is paused")
                return
            }
            sessionStart = Date()   // clock starts when audio starts, not at model download
            let hub = MeetingAudioHub(mode: mode)
            hub.onDegrade = { [weak self] msg in
                Task { @MainActor in self?.transcriber?.markFailed(msg) }
            }
            try await hub.start { [weak transcriber] frame in transcriber?.feed(frame) }
            try await transcriber.start()
            guard !PauseManager.shared.isPaused else {
                await hub.stop(); await transcriber.finish(); await transcriber.teardown()
                return
            }
            self.hub = hub
        } catch {
            Log.voice.error("meeting start failed: \(String(describing: error))")
            transcriber.markFailed(String(describing: error))
        }
    }

    func stopRecording(discard: Bool) async {
        guard !isStopping, let transcriber, let hub else { return }
        isStopping = true
        let dur = Date().timeIntervalSince(sessionStart)   // exclude finalization latency
        self.hub = nil                                     // close the re-entrancy window now
        await hub.stop()
        let finalLines = await transcriber.finish()
        await transcriber.teardown()
        if !discard, !finalLines.isEmpty { save(lines: finalLines, duration: dur) }
        isStopping = false
    }

    private func save(lines: [SpeakerLine], duration dur: Double) {
        let title = MeetingTitle.default(for: sessionStart)
        let segs = lines.map { (speakerId: $0.speakerLabel, text: $0.text, start: $0.start, end: $0.end) }
        var cleaned: String? = nil
        if UserDefaults.standard.bool(forKey: "meetings.cleanupOnStop") {
            let rmFill = UserDefaults.standard.bool(forKey: "meetings.removeFillers")
            // Clean each line's TEXT only — keep the timecode + "Speaker N" label
            // and the per-line newlines the whole-transcript cleaner would strip.
            cleaned = lines.map { line in
                let body = TranscriptPostProcessor.clean(line.text, removeFillers: rmFill) ?? ""
                let span = "\(MeetingMarkdownExporter.timecode(line.start))–\(MeetingMarkdownExporter.timecode(line.end))"
                return "[\(span)] \(line.speakerLabel): \(body)"
            }.joined(separator: "\n")
        }
        _ = try? store?.saveMeeting(title: title, date: sessionStart,
                                    durationSeconds: dur, cleanedText: cleaned, segments: segs)
        libraryModel.reload()
    }

    // MARK: Read-only transcript detail
    private func openTranscript(_ meeting: Meeting) {
        detailWindow?.close()   // tear down a previously-open detail window first
        let w = EscClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = meeting.title
        w.contentView = NSHostingView(rootView: MeetingDetailView(meeting: meeting, store: store))
        w.isReleasedWhenClosed = false
        w.center()
        detailWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

extension MeetingController: NSWindowDelegate {
    /// Closing the live window mid-recording must finalize + save, not silently
    /// orphan the audio engines. Defer the close until the session has stopped.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === meetingWindow, isRecording else { return true }
        Task { @MainActor in
            await stopRecording(discard: false)
            meetingWindow?.close()
        }
        return false
    }
}
