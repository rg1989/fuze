import AppKit
import KeyboardShortcuts
import SwiftUI

struct VoiceSettingsView: View {
    @AppStorage("voice.modelName") private var modelName = "openai_whisper-base.en"
    @AppStorage("voice.language") private var language = "en"
    @AppStorage("voice.removeFillers") private var removeFillers = true
    @AppStorage("voice.activationMode") private var activationMode = "hold"
    @AppStorage(VoiceSounds.stopKey) private var stopSound = "Tink"
    @AppStorage(VoiceSounds.finishKey) private var finishSound = "Glass"
    @AppStorage(ModifierHoldMonitor.defaultsKey) private var modifierMask = 0
    @ObservedObject private var controller = VoiceController.shared
    @State private var micStatus = PermissionsService.microphoneStatus
    @State private var hasAccessibility = PermissionsService.hasAccessibility
    @State private var capturingModifiers = false
    @State private var captureMonitor: Any?
    @State private var capturedUnion: UInt = 0

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
                Picker("Activation", selection: $activationMode) {
                    Text("Hold to talk").tag("hold")
                    Text("Press to start, press to stop").tag("toggle")
                }
                Text(activationMode == "hold"
                     ? "Hold to record, release to transcribe and paste at the cursor."
                     : "Press once to start recording, press again to stop, transcribe, and paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hold modifiers (alternative push-to-talk)") {
                HStack {
                    Text("Modifier keys")
                    Spacer()
                    Text(capturingModifiers
                         ? "Hold the desired keys, then release…"
                         : ModifierCombo(rawMask: UInt(bitPattern: modifierMask)).displayString)
                        .foregroundStyle(capturingModifiers ? Color.accentColor : .secondary)
                    Button(capturingModifiers ? "Cancel" : "Record") {
                        capturingModifiers ? endModifierCapture() : beginModifierCapture()
                    }
                    if modifierMask != 0 && !capturingModifiers {
                        Button("Clear") { modifierMask = 0 }
                    }
                }
                Text("Modifier-only push-to-talk, e.g. Right ⌘ + Right ⌥ — hold to record, release to transcribe. Works alongside the shortcut above; keys are side-specific.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcript") {
                Toggle("Remove filler words (um, uh, erm, hmm…)", isOn: $removeFillers)
                Text("Strips standalone vocal fillers and tidies the leftover punctuation before pasting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sounds") {
                soundPicker("When recording stops", selection: $stopSound)
                soundPicker("When transcript is ready", selection: $finishSound)
                Text("Plays a sound as dictation stops listening and when the transcript is ready. The transcript is always copied to your clipboard too, so it's never lost even if it can't be pasted.")
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
                Text("Click into any text field (e.g. TextEdit), hold the shortcut, speak, release. The transcript is pasted at the cursor and also kept on your clipboard.")
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
        .onDisappear { endModifierCapture() }
    }

    // MARK: - Modifier combo capture

    private func beginModifierCapture() {
        capturedUnion = 0
        capturingModifiers = true
        // Local monitor only: the settings window is key while recording.
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let pressed = ModifierCombo.pressed(inFlags: event.modifierFlags.rawValue)
            if pressed != 0 {
                capturedUnion |= pressed
            } else if capturedUnion != 0 {
                // All keys released: commit the union as the combo.
                modifierMask = Int(bitPattern: capturedUnion)
                endModifierCapture()
            }
            return nil // swallow while capturing
        }
    }

    private func endModifierCapture() {
        if let monitor = captureMonitor {
            NSEvent.removeMonitor(monitor)
        }
        captureMonitor = nil
        capturingModifiers = false
    }

    @ViewBuilder
    private func soundPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag("None")
            ForEach(VoiceSounds.systemSoundNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .onChange(of: selection.wrappedValue) { _, new in VoiceSounds.preview(new) }
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
