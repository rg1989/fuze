# Phase 5: Push-to-Talk Voice Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use /sp-subagent-driven-development (recommended) or /sp-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `00-MASTER.md` first. Prerequisite: Phases 0–1 complete.

**Goal:** Hold ⌃⌥Space anywhere on the system → Fuse records the microphone → release the key → a local Whisper model (WhisperKit, CoreML, fully offline) transcribes → the cleaned transcript is pasted at the cursor of the frontmost app via `PasteService.paste(text:restoreAfter:)`, and the user's previous clipboard is restored. A small floating HUD shows recording/transcribing/error state. A Voice settings tab offers model choice, language, the shortcut recorder, and permission status.

**Architecture:** All new code lives in `Sources/Voice/`. Two pure, exhaustively unit-tested components carry the correctness burden: `VoiceSession` (a state machine that makes the hotkey flow re-entrancy-proof — early key release, double-press, key events during transcription) and `TranscriptPostProcessor` (cleans Whisper output, filters artifacts like `[BLANK_AUDIO]`). The OS-integration shell — `AudioRecorder` (AVAudioEngine → 16 kHz mono Float32), `Transcriber` (actor wrapping WhisperKit), `RecordingHUD` (borderless non-activating NSPanel), `VoiceController` (hotkey → session → recorder/transcriber/HUD/paste) — is verified by build checks and HUMAN-VERIFY steps. The only shared-file edits are inserts above the `AppDelegate` and `SettingsRootView` anchors from master §6.1.

**Tech Stack:** AVFoundation (`AVAudioEngine`, `AVAudioConverter`), WhisperKit 0.9.x line (SPM `from: 0.9.0` resolves to v0.18.0 — API verified: `WhisperKit(model:)` convenience init, `transcribe(audioArray:decodeOptions:) -> [TranscriptionResult]`), KeyboardShortcuts (`onKeyDown`/`onKeyUp` for `.pushToTalk`), AppKit (`NSPanel`) + SwiftUI (HUD content, settings tab), XCTest.

**Core APIs consumed (exact Phase 1 signatures — never redefine):** `PasteService.paste(text: String, restoreAfter seconds: Double)` (clipboard write → ⌘V synthesis → restore prior clipboard; requires Accessibility); `PermissionsService.microphoneStatus: AVAuthorizationStatus`; `PermissionsService.requestMicrophone(_ completion: @escaping (Bool) -> Void)`; `PermissionsService.hasAccessibility`; `PermissionsService.promptForAccessibility()`; `PermissionsService.openSystemSettings(pane:)` with `.microphone` / `.accessibility`; `Log.voice`. Hotkey: ONLY the existing `KeyboardShortcuts.Name.pushToTalk` from `Sources/Core/HotkeyNames.swift` (default ⌃⌥Space) — define NO new Name constants.

**Settings keys (master §6.4, exact strings):** `"voice.modelName"` (String, default `"openai_whisper-base.en"`), `"voice.language"` (String, default `"en"`).

**Run every command from the repo root** `/Users/rgv250cc/Documents/Projects/Fuse`.

---

### Task 5.0: Preflight — verify Phase 1 is in place and the build is green

**Files:**
- None created or modified.

- [x] **Step 1: Verify the Phase 1 Core files and the anchors exist**

```bash
ls Sources/Core
grep -n "FUSE:CONTROLLER-PROPS\|FUSE:CONTROLLER-START" Sources/App/AppDelegate.swift
grep -n "FUSE:SETTINGS_TABS" Sources/App/SettingsRootView.swift
```
Expected: `ls` lists ALL of `Log.swift`, `Permissions.swift`, `AX.swift`, `PasteService.swift`, `HotkeyNames.swift`; each grep prints at least one matching line. If anything is missing, STOP — Phases 0–1 are not complete.

- [x] **Step 2: Verify the build and tests are green before any change**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`. If red, STOP and fix the pre-existing breakage first (master §9 rule 2).

---

### Task 5.1: VoiceSession state machine (TDD)

The hotkey flow has classic re-entrancy traps: key released before the model loaded, double-tap, key-repeat while holding, presses during a running transcription. `VoiceSession` is a pure value-type state machine; the controller feeds it events and executes the commands it returns, so every race collapses into a deterministic table tested exhaustively (3 states × 4 events = 12 transitions).

**Files:**
- Create: `Sources/Voice/VoiceSession.swift`
- Test: `Tests/FuseTests/VoiceSessionTests.swift`

- [x] **Step 1: Write the failing tests — create `Tests/FuseTests/VoiceSessionTests.swift` with exactly this content**

```swift
import XCTest
@testable import Fuse

final class VoiceSessionTests: XCTestCase {
    /// Builds a session already driven into `state` via real events.
    private func makeSession(in state: VoiceState) -> VoiceSession {
        var session = VoiceSession()
        switch state {
        case .idle:
            break
        case .recording:
            _ = session.handle(.hotkeyDown)
        case .transcribing:
            _ = session.handle(.hotkeyDown)
            _ = session.handle(.hotkeyUp)
        }
        XCTAssertEqual(session.state, state, "test setup failed to reach \(state)")
        return session
    }

    func testAllTwelveTransitionsExhaustively() {
        // (start state, event, expected command, expected end state)
        let table: [(VoiceState, VoiceEvent, VoiceCommand, VoiceState)] = [
            (.idle, .hotkeyDown, .startRecording, .recording),
            (.idle, .hotkeyUp, .none, .idle),                          // stray key-up
            (.idle, .transcriptionFinished, .none, .idle),             // stale callback
            (.idle, .transcriptionFailed, .none, .idle),               // stale callback
            (.recording, .hotkeyDown, .none, .recording),              // key-repeat ignored
            (.recording, .hotkeyUp, .stopRecordingAndTranscribe, .transcribing),
            (.recording, .transcriptionFinished, .none, .recording),   // stale callback
            (.recording, .transcriptionFailed, .discardRecording, .idle), // recorder failed to start
            (.transcribing, .hotkeyDown, .none, .transcribing),        // input ignored while busy
            (.transcribing, .hotkeyUp, .none, .transcribing),          // input ignored while busy
            (.transcribing, .transcriptionFinished, .none, .idle),
            (.transcribing, .transcriptionFailed, .none, .idle),
        ]
        for (start, event, expectedCommand, expectedState) in table {
            var session = makeSession(in: start)
            let command = session.handle(event)
            XCTAssertEqual(command, expectedCommand,
                           "(\(start), \(event)) returned \(command), expected \(expectedCommand)")
            XCTAssertEqual(session.state, expectedState,
                           "(\(start), \(event)) ended in \(session.state), expected \(expectedState)")
        }
    }

    func testTwoFullDictationCyclesBackToBack() {
        var session = VoiceSession()
        XCTAssertEqual(session.handle(.hotkeyDown), .startRecording)
        XCTAssertEqual(session.handle(.hotkeyUp), .stopRecordingAndTranscribe)
        XCTAssertEqual(session.handle(.transcriptionFinished), .none)
        XCTAssertEqual(session.handle(.hotkeyDown), .startRecording)
        XCTAssertEqual(session.handle(.hotkeyUp), .stopRecordingAndTranscribe)
        XCTAssertEqual(session.handle(.transcriptionFailed), .none)
        XCTAssertEqual(session.state, .idle)
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'VoiceSession' in scope` (a compile failure is this step's "red").

- [x] **Step 3: Implement — create `Sources/Voice/VoiceSession.swift` with exactly this content**

```swift
/// Pure state machine for the push-to-talk flow. The controller feeds it events
/// and executes the returned command; all re-entrancy decisions live here,
/// unit-testable, with no OS dependencies.
enum VoiceState: Equatable {
    case idle
    case recording
    case transcribing
}

enum VoiceEvent: Equatable {
    case hotkeyDown
    case hotkeyUp
    case transcriptionFinished
    case transcriptionFailed
}

enum VoiceCommand: Equatable {
    case startRecording
    case stopRecordingAndTranscribe
    case discardRecording
    case none
}

struct VoiceSession {
    private(set) var state: VoiceState = .idle

    mutating func handle(_ event: VoiceEvent) -> VoiceCommand {
        switch (state, event) {
        // idle: only a fresh key-down does anything.
        case (.idle, .hotkeyDown):
            state = .recording
            return .startRecording
        case (.idle, .hotkeyUp),
             (.idle, .transcriptionFinished),
             (.idle, .transcriptionFailed):
            return .none

        // recording: key-up hands off to transcription; key-repeat downs are
        // ignored; a failure while recording (recorder could not start)
        // abandons the attempt and discards any captured audio.
        case (.recording, .hotkeyUp):
            state = .transcribing
            return .stopRecordingAndTranscribe
        case (.recording, .hotkeyDown),
             (.recording, .transcriptionFinished):
            return .none
        case (.recording, .transcriptionFailed):
            state = .idle
            return .discardRecording

        // transcribing: ignore key input while busy; either outcome -> idle.
        case (.transcribing, .hotkeyDown),
             (.transcribing, .hotkeyUp):
            return .none
        case (.transcribing, .transcriptionFinished),
             (.transcribing, .transcriptionFailed):
            state = .idle
            return .none
        }
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, both `VoiceSessionTests` methods passed.

- [x] **Step 5: Commit**

```bash
git add Sources/Voice/VoiceSession.swift Tests/FuseTests/VoiceSessionTests.swift
git commit -m "feat(voice): push-to-talk state machine with exhaustive transition tests"
```

---

### Task 5.2: TranscriptPostProcessor (TDD)

Whisper output needs cleanup before pasting: stray whitespace/newlines, plus non-speech annotations emitted for silence or noise — `[BLANK_AUDIO]`, `[MUSIC]`, `(upbeat music)`, `(laughs)`. If nothing remains after cleaning, nothing must be pasted.

**Files:**
- Create: `Sources/Voice/TranscriptPostProcessor.swift`
- Test: `Tests/FuseTests/TranscriptPostProcessorTests.swift`

- [x] **Step 1: Write the failing tests — create `Tests/FuseTests/TranscriptPostProcessorTests.swift` with exactly this content**

```swift
import XCTest
@testable import Fuse

final class TranscriptPostProcessorTests: XCTestCase {
    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(TranscriptPostProcessor.clean("  hello world \n"), "hello world")
    }

    func testCollapsesInternalNewlinesAndRunsToSingleSpaces() {
        XCTAssertEqual(TranscriptPostProcessor.clean("hello\nworld  again\t!"), "hello world again !")
    }

    func testBlankAudioArtifactAloneBecomesNil() {
        XCTAssertNil(TranscriptPostProcessor.clean("[BLANK_AUDIO]"))
    }

    func testParenthesizedAnnotationAloneBecomesNil() {
        XCTAssertNil(TranscriptPostProcessor.clean("(upbeat music)"))
    }

    func testArtifactInsideSpeechIsStripped() {
        XCTAssertEqual(TranscriptPostProcessor.clean("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testEmptyStringBecomesNil() {
        XCTAssertNil(TranscriptPostProcessor.clean(""))
    }

    func testPlainSentencePassesThroughUnchanged() {
        XCTAssertEqual(TranscriptPostProcessor.clean("Testing one two three."), "Testing one two three.")
    }

    func testMultipleArtifactsAreAllStripped() {
        XCTAssertEqual(
            TranscriptPostProcessor.clean("[MUSIC] hello [BLANK_AUDIO] world (applause)"),
            "hello world")
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: **BUILD FAILS** with `cannot find 'TranscriptPostProcessor' in scope`.

- [x] **Step 3: Implement — create `Sources/Voice/TranscriptPostProcessor.swift` with exactly this content**

```swift
import Foundation

/// Cleans raw Whisper output before pasting: strips [bracketed] and
/// (parenthesized) non-speech annotations, collapses whitespace runs to single
/// spaces, trims the ends, and returns nil when nothing remains.
enum TranscriptPostProcessor {
    private static let annotationPattern = #"\[[^\]]*\]|\([^)]*\)"#

    static func clean(_ raw: String) -> String? {
        let withoutAnnotations = raw.replacingOccurrences(
            of: annotationPattern,
            with: " ",
            options: .regularExpression)
        let collapsed = withoutAnnotations.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, all 8 `TranscriptPostProcessorTests` passed, earlier tests still green.

- [x] **Step 5: Commit**

```bash
git add Sources/Voice/TranscriptPostProcessor.swift Tests/FuseTests/TranscriptPostProcessorTests.swift
git commit -m "feat(voice): transcript post-processor stripping whisper artifacts"
```

---

### Task 5.3: AudioRecorder, Transcriber, RecordingHUD

Three OS-integration pieces with no unit tests (live microphone, model download, on-screen panel); correctness is covered by Task 5.4's HUMAN-VERIFY. Key facts:

- **AudioRecorder:** WhisperKit expects 16 kHz mono Float32; the input device delivers something else (typically 48 kHz), so every tap buffer goes through `AVAudioConverter`. The converter's input block must supply each buffer exactly once per `convert` call, then report `.noDataNow` — the `fed` flag implements this; removing it causes hangs or duplicated audio.
- **Transcriber:** API verified against the resolved package version (v0.18.0, the latest 0.x that `from: 0.9.0` resolves to): `WhisperKit(model:)` is a non-deprecated convenience init; `transcribe(audioArray:decodeOptions:)` returns `[TranscriptionResult]`, each with `.text`; `DecodingOptions()` has a settable `language` member. First `prepare` downloads CoreML weights from Hugging Face repo `argmaxinc/whisperkit-coreml` (folder names match our model names exactly) — minutes once, cached afterwards. Actors are re-entrant at `await` points, so the `isPreparing` flag stops concurrent prepares from downloading twice.
- **RecordingHUD:** a 220×64 borderless `NSPanel` bottom-center of the focused screen. It must never steal focus from the app being dictated into (`.nonactivatingPanel`, `orderFrontRegardless`, never `makeKeyAndOrderFront`) and is mouse-transparent (`ignoresMouseEvents = true`).

**Files:**
- Create: `Sources/Voice/AudioRecorder.swift`
- Create: `Sources/Voice/Transcriber.swift`
- Create: `Sources/Voice/RecordingHUD.swift`

- [x] **Step 1: Create `Sources/Voice/AudioRecorder.swift` with exactly this content**

```swift
import AVFoundation

enum VoiceError: Error {
    case noInputDevice
    case converterSetupFailed
    case modelNotReady
}

/// Captures microphone audio via AVAudioEngine, converting on the fly to
/// 16 kHz mono Float32. The tap callback runs on an audio thread; all
/// sample-buffer access is funneled through `samplesQueue`.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let samplesQueue = DispatchQueue(label: "com.rgv250cc.fuse.voice.samples")

    func start() throws {
        samplesQueue.sync { samples.removeAll() }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw VoiceError.noInputDevice }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000,
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceError.converterSetupFailed
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = 16000.0 / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: out, error: &convError) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard convError == nil, let channel = out.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
            self.samplesQueue.async { self.samples.append(contentsOf: chunk) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the engine and returns all captured 16 kHz mono samples.
    /// Safe to call even if start() failed or was never called.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        return samplesQueue.sync { samples }
    }
}
```

- [x] **Step 2: Create `Sources/Voice/Transcriber.swift` with exactly this content**

```swift
import Foundation
import WhisperKit

/// Owns the WhisperKit pipeline. First prepare(modelName:) downloads the CoreML
/// model from Hugging Face (argmaxinc/whisperkit-coreml); cached on disk after.
actor Transcriber {
    private var whisperKit: WhisperKit?
    private(set) var loadedModelName: String?
    private var isPreparing = false

    /// Idempotent: no-op if the requested model is already loaded; reloads when
    /// the name changed. If another prepare is in flight (actor re-entrancy at
    /// await points), waits for it instead of downloading twice.
    func prepare(modelName: String) async throws {
        if whisperKit != nil, loadedModelName == modelName { return }
        while isPreparing {
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2 s
        }
        // Re-check: the in-flight prepare we waited on may have loaded our model.
        if whisperKit != nil, loadedModelName == modelName { return }
        isPreparing = true
        defer { isPreparing = false }
        whisperKit = nil
        loadedModelName = nil
        let kit = try await WhisperKit(model: modelName)
        whisperKit = kit
        loadedModelName = modelName
    }

    /// Transcribes 16 kHz mono Float32 samples. `language` is a two-letter code
    /// ("en", "de", …); English-only models (*.en) ignore it.
    func transcribe(samples: [Float], language: String) async throws -> String {
        guard let kit = whisperKit else { throw VoiceError.modelNotReady }
        var options = DecodingOptions()
        options.language = language
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}
```

- [x] **Step 3: Create `Sources/Voice/RecordingHUD.swift` with exactly this content**

```swift
import AppKit
import SwiftUI

/// Observable model the SwiftUI HUD view renders from.
@MainActor
final class RecordingHUDModel: ObservableObject {
    enum Display: Equatable {
        case hidden
        case recording
        case transcribing
        case message(String)
    }

    @Published var display: Display = .hidden
}

struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.display {
            case .hidden:
                EmptyView()
            case .recording:
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text("Recording…")
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            case .message(let text):
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(text)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .frame(width: 220, height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Floating, mouse-transparent, non-activating status panel shown bottom-center
/// of the screen that has keyboard focus. Never steals focus.
@MainActor
final class RecordingHUD {
    private let model = RecordingHUDModel()
    private var panel: NSPanel?
    /// Bumped on every show/flash/hide so a stale flash timer never hides a newer display.
    private var generation = 0

    /// Shows a persistent display (stays until the next show/flash/hide call).
    /// Pass .recording, .transcribing, or .message("Downloading model…").
    func show(_ display: RecordingHUDModel.Display) {
        generation += 1
        model.display = display
        present()
    }

    /// Shows a transient message and auto-hides after `seconds`.
    func flash(_ message: String, hideAfter seconds: Double = 1.2) {
        generation += 1
        let current = generation
        model.display = .message(message)
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
    }

    func hide() {
        generation += 1
        model.display = .hidden
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        newPanel.level = .statusBar
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.ignoresMouseEvents = true
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = NSHostingView(rootView: RecordingHUDView(model: model))
        panel = newPanel
        return newPanel
    }

    private func position(_ panel: NSPanel) {
        // NSScreen.main is the screen with keyboard focus — where the user is typing.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80))
    }
}
```

- [x] **Step 4: Regenerate, build, run existing tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **` (nothing instantiates these classes yet, so tests touch neither microphone nor network). If the compiler reports a signature mismatch on `WhisperKit(model:)` or `transcribe(audioArray:decodeOptions:)` (package minor-version drift), inspect `.build/SourcePackages/checkouts/WhisperKit/Sources/WhisperKit/Core/WhisperKit.swift`, adjust ONLY the call sites minimally (`try await WhisperKit(WhisperKitConfig(model: modelName))` is the equivalent config-based init), and record it under `## Deviations` at the bottom of this file (master §9 rule 6).

- [x] **Step 5: Commit**

```bash
git add Sources/Voice/AudioRecorder.swift Sources/Voice/Transcriber.swift Sources/Voice/RecordingHUD.swift
git commit -m "feat(voice): audio recorder, whisperkit transcriber and recording HUD"
```

---

### Task 5.4: VoiceController + AppDelegate wiring

The controller glues everything together: it registers `KeyboardShortcuts.onKeyDown` AND `onKeyUp` for `.pushToTalk` (the package supports both callbacks — exactly why it was chosen), feeds events into `VoiceSession`, executes the returned `VoiceCommand` against recorder/transcriber/HUD, and pastes via `PasteService.paste(text:restoreAfter:)`. It eagerly loads the Whisper model at app start (so the first dictation is not slow) and re-loads when `"voice.modelName"` changes. It is a `@MainActor ObservableObject` exposed as `VoiceController.shared` so the settings tab (Task 5.5) can observe `modelStatus`. Behavior rules baked in: microphone gate at key-down (if not authorized, request permission and abort WITHOUT feeding the session — the matching key-up then harmlessly hits `(idle, hotkeyUp) → none`); recordings under 0.3 s (`samples.count < 4800` at 16 kHz) flash "Too short" and are discarded; a nil result from `TranscriptPostProcessor.clean` flashes "No speech detected" and pastes nothing; missing Accessibility prompts instead of failing silently.

**Files:**
- Create: `Sources/Voice/VoiceController.swift`
- Modify: `Sources/App/AppDelegate.swift` (insert above the two anchors only)

- [x] **Step 1: Create `Sources/Voice/VoiceController.swift` with exactly this content**

```swift
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
        ])

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            Task { @MainActor in self?.hotkeyDown() }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            Task { @MainActor in self?.hotkeyUp() }
        }

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
        guard let cleaned = TranscriptPostProcessor.clean(raw) else {
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
```

- [x] **Step 2: Wire the controller into `Sources/App/AppDelegate.swift`**

Make exactly two insertions, each directly ABOVE its anchor comment. Touch nothing else in the file. If other phases already inserted lines above these anchors, leave those in place.

Insertion A — the property line goes above the `// FUSE:CONTROLLER-PROPS` anchor so it reads:

```swift
    private var voiceController: VoiceController!
    // FUSE:CONTROLLER-PROPS
```

Insertion B — the start call goes above the `// FUSE:CONTROLLER-START` anchor (inside `applicationDidFinishLaunching`) so it reads:

```swift
        voiceController = VoiceController.shared
        voiceController.start()
        // FUSE:CONTROLLER-START
```

- [x] **Step 3: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`. The `XCTestCase` guard at the top of `applicationDidFinishLaunching` (Phase 0) means `voiceController.start()` never runs during hosted test runs — no hotkeys or model downloads inside tests. Keep that guard intact.

- [ ] **Step 4: HUMAN-VERIFY — first dictation end-to-end**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to do ALL of the following, in order, and report what they observe:

1. **Permissions.** Open Fuse Settings → General. Confirm Accessibility is green (if not: grant it; with ad-hoc signing you may need to remove Fuse from the Accessibility list and re-add `.build/Build/Products/Debug/Fuse.app` — master §10). Microphone may still be ungranted; fine for now.
2. **Model download.** Run `log stream --predicate 'subsystem == "com.rgv250cc.Fuse" AND category == "voice"' --level debug` in Terminal. Confirm `preparing whisper model: openai_whisper-base.en` appeared at launch, followed — after up to several minutes on first run (~150 MB download) — by `whisper model ready: openai_whisper-base.en`. Wait for "ready" before continuing.
3. **Mic grant via hotkey.** Open TextEdit, click into a document, press and hold ⌃⌥Space. On the first press the macOS microphone prompt appears (the HUD may flash "Microphone permission needed"). Grant it. This first attempt is intentionally aborted.
4. **Real dictation.** Hold ⌃⌥Space: a small floating panel appears bottom-center showing a red dot and "Recording…", and TextEdit KEEPS keyboard focus. Say "testing one two three", release. The panel switches to a spinner "Transcribing…", and within ~3 s the text appears at the cursor in TextEdit (capitalization/punctuation may vary). The HUD disappears.
5. **Clipboard restore.** Copy the word `SENTINEL` (⌘C), dictate another phrase, wait one second, press ⌘V in TextEdit: `SENTINEL` pastes — dictation did not clobber the clipboard.
6. **Too short.** Tap-and-release ⌃⌥Space as fast as possible: HUD flashes "Too short", nothing is pasted.
7. **Silence.** Hold ⌃⌥Space for ~2 s in silence, release: nothing is pasted; HUD shows "Transcribing…" then flashes "No speech detected" (`[BLANK_AUDIO]` was filtered).
8. **Busy input ignored.** Dictate a long sentence; while "Transcribing…" shows, press ⌃⌥Space a few times: the presses are ignored (no second recording, no crash) and the original transcript still pastes.

Record the answers. All eight must pass before committing.

- [x] **Step 5: Commit**

```bash
git add Sources/Voice/VoiceController.swift Sources/App/AppDelegate.swift
git commit -m "feat(voice): push-to-talk controller wired to hotkey, whisper and paste"
```

---

### Task 5.5: Voice settings tab

A settings tab with: the Whisper model picker (three vetted names from `argmaxinc/whisperkit-coreml`), live model status from `VoiceController.shared.modelStatus`, a language field (ignored by `.en` models — the UI says so), `KeyboardShortcuts.Recorder` for `.pushToTalk`, microphone + Accessibility permission rows, and a test-dictation hint. Changing the picker writes `"voice.modelName"` via `@AppStorage`; the controller's `UserDefaults.didChangeNotification` observer re-prepares the model automatically — no extra wiring here.

**Files:**
- Create: `Sources/Voice/VoiceSettingsView.swift`
- Modify: `Sources/App/SettingsRootView.swift` (insert above the anchor only)

- [x] **Step 1: Create `Sources/Voice/VoiceSettingsView.swift` with exactly this content**

```swift
import KeyboardShortcuts
import SwiftUI

struct VoiceSettingsView: View {
    @AppStorage("voice.modelName") private var modelName = "openai_whisper-base.en"
    @AppStorage("voice.language") private var language = "en"
    @ObservedObject private var controller = VoiceController.shared
    @State private var micStatus = PermissionsService.microphoneStatus
    @State private var hasAccessibility = PermissionsService.hasAccessibility

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let models: [(name: String, label: String)] = [
        ("openai_whisper-base.en", "Base — English only, ~150 MB, fastest"),
        ("openai_whisper-small.en", "Small — English only, better accuracy"),
        ("openai_whisper-large-v3_turbo", "Large v3 Turbo — multilingual, best, slow first load"),
    ]

    var body: some View {
        Form {
            Section("Model") {
                Picker("Whisper model", selection: $modelName) {
                    ForEach(Self.models, id: \.name) { model in
                        Text(model.label).tag(model.name)
                    }
                }
                LabeledContent("Status") { statusView }
                TextField("Language code", text: $language)
                    .frame(maxWidth: 220)
                Text("Two-letter code, e.g. \"en\", \"de\". Ignored by English-only (.en) models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Push to talk", name: .pushToTalk)
                Text("Hold to record, release to transcribe and paste at the cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Microphone",
                    detail: "Required to record audio",
                    granted: micStatus == .authorized,
                    grant: {
                        PermissionsService.requestMicrophone { _ in }
                        PermissionsService.openSystemSettings(pane: .microphone)
                    })
                permissionRow(
                    title: "Accessibility",
                    detail: "Required to paste the transcript into other apps",
                    granted: hasAccessibility,
                    grant: {
                        PermissionsService.promptForAccessibility()
                        PermissionsService.openSystemSettings(pane: .accessibility)
                    })
            }

            Section("Test dictation") {
                Text("Click into any text field (e.g. TextEdit), hold the shortcut, speak, release. The transcript is pasted at the cursor and your previous clipboard is restored.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            micStatus = PermissionsService.microphoneStatus
            hasAccessibility = PermissionsService.hasAccessibility
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.modelStatus {
        case .notLoaded:
            Text("Not loaded").foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading / loading…")
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Text("Failed: \(message)").foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, detail: String, granted: Bool,
                               grant: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            if !granted {
                Button("Grant…", action: grant)
            }
        }
    }
}
```

- [x] **Step 2: Add the tab to `Sources/App/SettingsRootView.swift`**

Insert the two tab lines directly ABOVE the `// FUSE:SETTINGS_TABS` anchor (inside the `TabView`), touching nothing else, so it reads:

```swift
            VoiceSettingsView()
                .tabItem { Label("Voice", systemImage: "mic") }
            // FUSE:SETTINGS_TABS
```

If other phases already inserted tabs above the anchor, leave them in place and add ours directly above the anchor comment.

- [x] **Step 3: Regenerate, build, run tests**

```bash
xcodegen generate
xcodebuild -project Fuse.xcodeproj -scheme Fuse -configuration Debug -derivedDataPath .build build 2>&1 | tail -5
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

- [ ] **Step 4: HUMAN-VERIFY — settings tab and model switching**

```bash
pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app
```

Ask the human to do ALL of the following and report what they observe:

1. Open Fuse Settings from the menu-bar icon. A "Voice" tab (mic icon) exists, showing: model picker (Base selected), Status "Ready" (or briefly "Downloading / loading…" then green "Ready"), language field "en", "Push to talk" recorder showing ⌃⌥Space, both permission rows green (granted in Task 5.4).
2. Switch the picker to "Small — English only, better accuracy". Status immediately shows "Downloading / loading…" with a spinner (first switch downloads ~500 MB; minutes), then turns green "Ready".
3. While the small model downloads, hold ⌃⌥Space in TextEdit and speak: the HUD shows "Downloading model…" and the dictation completes (slowly) once the model is ready — or report what happened instead.
4. With Small Ready, dictate "the quick brown fox" into TextEdit — the transcript appears at the cursor.
5. Switch back to "Base". Status flips to "Downloading / loading…" only briefly (cached on disk) and back to "Ready". Dictation still works.
6. In the shortcut recorder, record a different shortcut (e.g. ⌃⌥D), confirm hold-to-dictate works on it, then set it back to ⌃⌥Space and confirm again.

Record the answers. All six must pass before committing.

- [x] **Step 5: Commit**

```bash
git add Sources/Voice/VoiceSettingsView.swift Sources/App/SettingsRootView.swift
git commit -m "feat(voice): voice settings tab with model picker, status and permissions"
```

---

### Task 5.6: Discard in-flight recording on global pause

Precondition: `Sources/Core/PauseManager.swift` exists (Phase 1 Task 1.7). The failure mode this prevents: pausing Fuse while physically holding the push-to-talk key disables the global key-up callback (`KeyboardShortcuts.isEnabled = false`), so `.hotkeyUp` never arrives and the recorder would run forever. Fix: on pause, discard through the state machine's existing `(recording, transcriptionFailed) → idle / .discardRecording` transition — no new states, no new commands.

**Files:**
- Modify: `Sources/Voice/VoiceController.swift`

- [x] **Step 1: Apply two precise edits to `VoiceController`**

Edit A — add a property directly below the existing `defaultsObserver` property declaration:

```swift
    private var pauseObserver: NSObjectProtocol?
```

Edit B — in `start()`, insert directly after the `defaultsObserver = NotificationCenter.default.addObserver(...)` registration block (after its closing `}`):

```swift
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
```

- [x] **Step 2: Build and run unit tests**

```bash
xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **` (the transition itself is already covered by VoiceSessionTests; this task only wires the trigger).

- [ ] **Step 3: HUMAN-VERIFY — pause while holding the hotkey**

Hold ⌃⌥Space (HUD shows "Recording…"); WITHOUT releasing, use the mouse: menu-bar icon → "Pause Fuse" → HUD flashes "Recording discarded (Fuse paused)"; now release the key → nothing is pasted, nothing transcribes. Resume → push-to-talk works normally again.

- [x] **Step 4: Commit**

```bash
git add Sources/Voice/VoiceController.swift
git commit -m "feat(voice): discard in-flight recording when Fuse is paused"
```

---

## Manual verification checklist

End-of-phase pass with the human, app freshly launched via `pkill -x Fuse; open .build/Build/Products/Debug/Fuse.app`:

- [ ] **HUMAN-VERIFY** Fresh-launch model load: the voice log stream (`log stream --predicate 'subsystem == "com.rgv250cc.Fuse" AND category == "voice"' --level debug`) shows `preparing whisper model: openai_whisper-base.en` then `whisper model ready: …`; Settings → Voice shows the same progression (spinner → green "Ready").
- [ ] **HUMAN-VERIFY** TextEdit dictation: hold ⌃⌥Space, HUD shows "● Recording…" bottom-center without stealing focus, speak "testing one two three", release, HUD shows "Transcribing…", text appears at the cursor within ~3 s, HUD disappears.
- [ ] **HUMAN-VERIFY** Clipboard restored: copy `SENTINEL`, dictate something, wait one second (restore delay is 0.6 s), ⌘V pastes `SENTINEL`.
- [ ] **HUMAN-VERIFY** Instant tap-and-release: HUD flashes "Too short", nothing pasted.
- [ ] **HUMAN-VERIFY** ~2 s of silence: nothing pasted, HUD flashes "No speech detected".
- [ ] **HUMAN-VERIFY** Hotkey presses during "Transcribing…" are ignored — no double recording, no crash, original transcript still pastes.
- [ ] **HUMAN-VERIFY** Works in a Slack message box and a browser textarea (any web form), not just TextEdit.
- [ ] **HUMAN-VERIFY** Model switch to `small.en` downloads with visible status and dictation works on it; switching back to `base.en` is fast (cached).
- [x] All unit tests green: `xcodebuild -project Fuse.xcodeproj -scheme Fuse -derivedDataPath .build test 2>&1 | tail -20` → `** TEST SUCCEEDED **` (includes 2 VoiceSessionTests methods covering all 12 transitions + 8 TranscriptPostProcessorTests).
- [x] `git log --oneline | head -6` shows the five Phase 5 commits on top.

## Risks & gotchas

- **TCC + ad-hoc signing (master §10 — WILL happen).** After a rebuild, Accessibility may silently fail while System Settings shows it granted: dictation then transcribes but never pastes (HUD flashes "Grant Accessibility to paste"). Fix: remove Fuse from the Accessibility list and re-add the current `.build/Build/Products/Debug/Fuse.app`. The Microphone grant can break the same way after re-signing.
- **WhisperKit version drift.** `project.yml` pins `from: 0.9.0`, which SPM resolves to the latest 0.x (v0.18.0 at planning time); the call sites here are verified against that version. WhisperKit 1.0 (May 2026) removes deprecated APIs and prefers `WhisperKit(WhisperKitConfig(model:))`; if the resolved version ever jumps majors, switch the init to the config form, re-check signatures in `.build/SourcePackages/checkouts/WhisperKit/`, and record it under `## Deviations`.
- **First model download is long.** ~150 MB for `base.en`, more for the others, from Hugging Face. If the network is down, `prepare` throws, Status shows "Failed: …", and dictation attempts flash "Transcription failed". Recovery: fix the network, then flip the model picker away and back (re-triggers `prepareModel()`) or relaunch.
- **`UserDefaults.didChangeNotification` fires for every defaults write app-wide.** `prepareModel()` guards with `lastRequestedModelName`, making those cheap no-ops — do not remove that guard. Likewise do not remove the `isPreparing` flag in `Transcriber`: actors are re-entrant at `await` points, and without it the eager startup load racing a hotkey-triggered load downloads the model twice.
- **AVAudioConverter input block contract.** The block must supply each input buffer exactly once per `convert` call, then report `.noDataNow` — the `fed` flag implements this; removing it hangs or duplicates audio. Sample-rate conversion may buffer a few trailing milliseconds inside the converter; the sub-50 ms tail loss is inaudible for dictation and accepted.
- **`engine.inputNode` triggers the mic TCC prompt on first touch.** That is why `hotkeyDown()` gates on `PermissionsService.microphoneStatus` BEFORE the session can issue `.startRecording` — otherwise the engine would start while macOS shows the permission dialog, recording nothing.
- **Input device changes mid-recording** (AirPods connect, USB mic unplugged) can stop `AVAudioEngine`; samples captured up to that point still return from `stop()`. Worst case: a truncated transcript, user dictates again. Acceptable for v1 — do not add device-change handling in this phase.
- **HUD must never take focus.** `.nonactivatingPanel` + `ignoresMouseEvents = true` + `orderFrontRegardless()` keeps the target app's text field focused. Do not change `level` or `styleMask`, and never call `makeKeyAndOrderFront` on the panel.
- **Hosted tests must never start the pipeline.** The `XCTestCase` guard at the top of `AppDelegate.applicationDidFinishLaunching` (Phase 0) keeps test runs from registering hotkeys or downloading models. If voice tests ever hang, check that guard first.
- **`.en` models ignore the language setting.** The settings UI says so; do not add code that errors on `language != "en"` with an English-only model — WhisperKit simply ignores the option.


## Deviations

- None. WhisperKit resolved to v0.18.0 exactly as planned; `WhisperKit(model:)` convenience init, `transcribe(audioArray:decodeOptions:) -> [TranscriptionResult]`, and `DecodingOptions.language` all verified against `.build/SourcePackages/checkouts/WhisperKit/Sources/WhisperKit/Core/WhisperKit.swift` and matched the plan's call sites. No code changes from the plan's specified content.
- All HUMAN-VERIFY steps (Task 5.4 Step 4, Task 5.5 Step 4, Task 5.6 Step 3, and the end-of-phase manual verification checklist) were skipped per agentic execution rules; they remain unticked for a human pass.