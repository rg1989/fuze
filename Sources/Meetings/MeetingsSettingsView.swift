import SwiftUI
import KeyboardShortcuts

/// The Meetings settings tab — mirrors DownloaderSettingsView. The master enable
/// toggle lives in the General grid (ModuleCatalog), not here.
struct MeetingsSettingsView: View {
    @AppStorage("meetings.audioSource") private var sourceRaw = AudioSourceMode.micOnly.rawValue
    @AppStorage("meetings.cleanupOnStop") private var cleanupOnStop = true
    @AppStorage("meetings.removeFillers") private var removeFillers = true

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Start / stop meeting", name: .toggleMeeting)
                Text("Starts or stops a live meeting recording from anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Default audio source") {
                Picker("Capture", selection: $sourceRaw) {
                    ForEach(AudioSourceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Meeting transcription is English-only and runs on Parakeet, fully on-device. \"Microphone + system audio\" uses Screen Recording to also hear remote participants on a video call.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("On stop") {
                Toggle("Clean up transcript (second pass)", isOn: $cleanupOnStop)
                Toggle("Remove vocal fillers (um, uh…)", isOn: $removeFillers)
                    .disabled(!cleanupOnStop)
                Text("The same second-pass cleanup used by dictation: strips non-speech annotations and, optionally, vocal fillers. Stored alongside the raw diarized transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                Text("Each meeting is saved separately. Open the library from the menu bar (Meetings…) to browse, search, and delete.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(MeetingStore.onDiskPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
