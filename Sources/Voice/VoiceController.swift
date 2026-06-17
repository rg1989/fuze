import AppKit
import KeyboardShortcuts

/// Owns the push-to-talk pipeline:
/// hotkey edges -> VoiceSession (pure state machine) -> VoiceCommand execution
/// against AudioRecorder / Transcriber / RecordingHUD / PasteService.
@MainActor
final class VoiceController: ObservableObject {
    static let shared = VoiceController()

    enum ModelStatus: Equatable {
        case notLoaded
        case downloading
        case ready(String)
        case failed(String)
    }

    @Published private(set) var modelStatus: ModelStatus = .notLoaded

    private var session = VoiceSession()
    private var transcriptionGeneration = 0
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hud = RecordingHUD()
    private var lastRequestedModelName: String?
    private var defaultsObserver: NSObjectProtocol?
    private var pauseObserver: NSObjectProtocol?
    private var modifierMonitor: ModifierHoldMonitor?

    private init() {}

    private var configuredModelName: String {
        UserDefaults.standard.string(forKey: "voice.modelName") ?? "openai_whisper-base.en"
    }

    private var configuredLanguage: String {
        UserDefaults.standard.string(forKey: "voice.language") ?? "en"
    }

    func start() {
        UserDefaults.standard.register(defaults: [
            "voice.enabled": true,
            "voice.modelName": "openai_whisper-base.en",
            "voice.language": "en",
            "voice.removeFillers": true,
            "voice.activationMode": "hold",
            VoiceSounds.startKey: "Pop",
            VoiceSounds.stopKey: "Tink",
            VoiceSounds.finishKey: "Glass",
            VoiceSounds.noSpeechKey: "Basso",
            ModifierHoldMonitor.defaultsKey: 0,
        ])

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            Task { @MainActor in self?.triggerDown() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            Task { @MainActor in self?.triggerUp() }
        }

        // Modifier-hold push-to-talk (e.g. Right ⌘ + Right ⌥): KeyboardShortcuts
        // can't record modifier-only combos, so a flagsChanged monitor feeds the
        // same session pipeline. Off until the user records a combo in settings.
        let monitor = ModifierHoldMonitor(
            onDown: { [weak self] in self?.triggerDown() },
            onUp: { [weak self] in self?.triggerUp() })
        monitor.start()
        modifierMonitor = monitor

        // Eager model load so the first dictation is not slow.
        prepareModel()

        // Re-prepare when "voice.modelName" changes in settings.
        // prepareModel() is a no-op unless the name actually changed.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.prepareModel() }
        }

        // Pausing mid-recording: the key-up callback is globally disabled while
        // paused, so it can never arrive — discard via the state machine instead
        // of leaving the recorder running.
        pauseObserver = NotificationCenter.default.addObserver(
            forName: PauseManager.pauseStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      PauseManager.shared.isPaused,
                      self.session.state == .recording else { return }
                Log.voice.info("paused mid-recording; discarding")
                self.hud.flash("Recording discarded (Fuse paused)", hideAfter: 2.0)
                // (recording, transcriptionFailed) → idle / .discardRecording
                self.execute(self.session.handle(.transcriptionFailed))
            }
        }
    }

    // MARK: - Trigger handling (hold or toggle mode, see ActivationMapper)

    private func triggerDown() {
        // Master switch (General → Fused apps). A hold already in flight is
        // unaffected: triggerUp stays open so the session can finish cleanly.
        guard UserDefaults.standard.bool(forKey: "voice.enabled") else { return }
        guard let event = ActivationMapper.event(forDownIn: session.state,
                                                 mode: ActivationMode.current()) else { return }
        if event == .hotkeyDown {
            guard PermissionsService.microphoneStatus == .authorized else {
                Log.voice.info("trigger down without mic permission; requesting")
                PermissionsService.requestMicrophone { granted in
                    Log.voice.info("microphone request resolved: \(granted)")
                }
                hud.flash("Microphone permission needed", hideAfter: 2.0)
                return // abort this attempt; the session never leaves .idle
            }
        }
        execute(session.handle(event))
    }

    private func triggerUp() {
        guard let event = ActivationMapper.event(forUpIn: ActivationMode.current()) else { return }
        execute(session.handle(event))
    }

    private func execute(_ command: VoiceCommand) {
        switch command {
        case .none:
            break
        case .startRecording:
            beginRecording()
        case .stopRecordingAndTranscribe:
            finishRecordingAndTranscribe()
        case .discardRecording:
            _ = recorder.stop() // discard samples; HUD handled by the failure site
        }
    }

    // MARK: - Command implementations

    private func beginRecording() {
        do {
            try recorder.start()
            VoiceSounds.playStarted()
            hud.show(.recording)
        } catch {
            Log.voice.error("recorder failed to start: \(String(describing: error))")
            hud.flash("Microphone unavailable", hideAfter: 2.0)
            // (recording, transcriptionFailed) -> idle / .discardRecording
            execute(session.handle(.transcriptionFailed))
        }
    }

    private func rejectEmptyRecording(reason: String) {
        VoiceSounds.playNoSpeech()
        hud.flash(reason, hideAfter: 2.0)
        execute(session.handle(.transcriptionFinished))
    }

    private func finishRecordingAndTranscribe() {
        let samples = recorder.stop()
        // 16 kHz * 0.3 s = 4800 samples minimum.
        guard samples.count >= 4800 else {
            Log.voice.info("recording too short (\(samples.count) samples); discarding")
            hud.flash("Too short", hideAfter: 2.0)
            execute(session.handle(.transcriptionFailed))
            return
        }
        if AudioSilence.isEffectivelySilent(samples) {
            Log.voice.info("recording silent (\(samples.count) samples); skipping transcription")
            rejectEmptyRecording(reason: "No speech detected")
            return
        }
        VoiceSounds.playStopped()   // valid take captured — stopped listening

        let modelName = configuredModelName
        let language = configuredLanguage
        if case .ready(let loaded) = modelStatus, loaded == modelName {
            hud.show(.transcribing)
        } else {
            hud.show(.message("Preparing model — first use can take minutes…"))
        }

        // Generation token: the watchdog can orphan a hung worker, and a stale
        // worker finishing late must not paste into a newer session.
        transcriptionGeneration += 1
        let generation = transcriptionGeneration

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.prepare(modelName: modelName)
                guard generation == self.transcriptionGeneration else { return }
                self.hud.show(.transcribing)
                let raw = try await self.transcriber.transcribe(samples: samples, language: language)
                guard generation == self.transcriptionGeneration else { return }
                Log.voice.info("transcribed \(samples.count) samples -> \(raw.count) chars")
                self.deliver(raw: raw)
            } catch {
                guard generation == self.transcriptionGeneration else { return }
                Log.voice.error("transcription failed: \(String(describing: error))")
                self.hud.flash("Transcription failed", hideAfter: 2.0)
                self.execute(self.session.handle(.transcriptionFailed))
            }
        }

        // Watchdog: large models can hang (or spend many minutes on first-run
        // CoreML compilation). After 5 minutes, free the session so the user
        // isn't stuck in .transcribing forever; the orphaned worker is ignored.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            guard let self,
                  generation == self.transcriptionGeneration,
                  self.session.state == .transcribing else { return }
            self.transcriptionGeneration += 1
            Log.voice.error("transcription watchdog fired after 300 s (model: \(modelName, privacy: .public))")
            self.hud.flash("Transcription timed out — try a smaller model", hideAfter: 3.0)
            self.execute(self.session.handle(.transcriptionFailed))
        }
    }

    private func deliver(raw: String) {
        let removeFillers = UserDefaults.standard.bool(forKey: "voice.removeFillers")
        guard let cleaned = TranscriptPostProcessor.clean(raw, removeFillers: removeFillers) else {
            rejectEmptyRecording(reason: "No speech detected")
            return
        }
        // Always keep the transcript on the clipboard so it's never lost, then
        // paste it at the cursor when Accessibility allows.
        if PermissionsService.hasAccessibility {
            PasteService.pasteKeepingOnClipboard(text: cleaned)
            hud.hide()
        } else {
            PasteService.copyToClipboard(text: cleaned)
            Log.voice.error("accessibility missing; transcript copied to clipboard, not pasted")
            hud.flash("Copied to clipboard — grant Accessibility to auto-paste", hideAfter: 2.5)
            PermissionsService.promptForAccessibility()
        }
        VoiceSounds.playFinished()
        execute(session.handle(.transcriptionFinished))
    }

    // MARK: - Model preparation

    private func prepareModel() {
        let modelName = configuredModelName
        guard modelName != lastRequestedModelName else { return }
        lastRequestedModelName = modelName
        modelStatus = .downloading
        Log.voice.info("preparing whisper model: \(modelName)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.prepare(modelName: modelName)
                // Settings may have changed mid-download; only publish if still current.
                if self.lastRequestedModelName == modelName {
                    self.modelStatus = .ready(modelName)
                    Log.voice.info("whisper model ready: \(modelName)")
                }
            } catch {
                Log.voice.error("model load failed: \(String(describing: error))")
                if self.lastRequestedModelName == modelName {
                    self.modelStatus = .failed(String(describing: error))
                }
            }
        }
    }
}
