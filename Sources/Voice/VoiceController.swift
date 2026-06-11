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
            "voice.modelName": "openai_whisper-base.en",
            "voice.language": "en",
            "voice.removeFillers": true,
            ModifierHoldMonitor.defaultsKey: 0,
        ])

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            Task { @MainActor in self?.hotkeyDown() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            Task { @MainActor in self?.hotkeyUp() }
        }

        // Modifier-hold push-to-talk (e.g. Right ⌘ + Right ⌥): KeyboardShortcuts
        // can't record modifier-only combos, so a flagsChanged monitor feeds the
        // same session pipeline. Off until the user records a combo in settings.
        let monitor = ModifierHoldMonitor(
            onDown: { [weak self] in self?.hotkeyDown() },
            onUp: { [weak self] in self?.hotkeyUp() })
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

    // MARK: - Hotkey handling

    private func hotkeyDown() {
        guard PermissionsService.microphoneStatus == .authorized else {
            Log.voice.info("hotkey down without mic permission; requesting")
            PermissionsService.requestMicrophone { granted in
                Log.voice.info("microphone request resolved: \(granted)")
            }
            hud.flash("Microphone permission needed", hideAfter: 2.0)
            return // abort this attempt; the session never leaves .idle
        }
        execute(session.handle(.hotkeyDown))
    }

    private func hotkeyUp() {
        execute(session.handle(.hotkeyUp))
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
            hud.show(.recording)
        } catch {
            Log.voice.error("recorder failed to start: \(String(describing: error))")
            hud.flash("Microphone unavailable", hideAfter: 2.0)
            // (recording, transcriptionFailed) -> idle / .discardRecording
            execute(session.handle(.transcriptionFailed))
        }
    }

    private func finishRecordingAndTranscribe() {
        let samples = recorder.stop()
        // 16 kHz * 0.3 s = 4800 samples minimum.
        guard samples.count >= 4800 else {
            Log.voice.info("recording too short (\(samples.count) samples); discarding")
            hud.flash("Too short")
            execute(session.handle(.transcriptionFailed))
            return
        }

        let modelName = configuredModelName
        let language = configuredLanguage
        if case .ready(let loaded) = modelStatus, loaded == modelName {
            hud.show(.transcribing)
        } else {
            hud.show(.message("Downloading model…"))
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.prepare(modelName: modelName)
                self.hud.show(.transcribing)
                let raw = try await self.transcriber.transcribe(samples: samples, language: language)
                Log.voice.info("transcribed \(samples.count) samples -> \(raw.count) chars")
                self.deliver(raw: raw)
            } catch {
                Log.voice.error("transcription failed: \(String(describing: error))")
                self.hud.flash("Transcription failed", hideAfter: 2.0)
                self.execute(self.session.handle(.transcriptionFailed))
            }
        }
    }

    private func deliver(raw: String) {
        let removeFillers = UserDefaults.standard.bool(forKey: "voice.removeFillers")
        guard let cleaned = TranscriptPostProcessor.clean(raw, removeFillers: removeFillers) else {
            hud.flash("No speech detected")
            execute(session.handle(.transcriptionFinished))
            return
        }
        if PermissionsService.hasAccessibility {
            PasteService.paste(text: cleaned, restoreAfter: 0.6)
            hud.hide()
        } else {
            Log.voice.error("accessibility missing; cannot paste transcript")
            hud.flash("Grant Accessibility to paste", hideAfter: 2.5)
            PermissionsService.promptForAccessibility()
        }
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
