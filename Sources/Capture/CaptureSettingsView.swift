import AppKit
import KeyboardShortcuts
import SwiftUI

struct CaptureSettingsView: View {
    @AppStorage("capture.saveFolderPath") private var saveFolderPath = CaptureController.defaultSaveFolder
    @AppStorage("capture.copyToClipboard") private var copyToClipboard = true
    @AppStorage("capture.openEditorAfter") private var openEditorAfter = true
    @AppStorage("capture.imageFormat") private var imageFormat = "png"
    @AppStorage("capture.videoFormat") private var videoFormat = "mp4"

    @State private var hasScreenRecording = PermissionsService.hasScreenRecording
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !hasScreenRecording {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Recording permission required")
                                .foregroundStyle(.red)
                            Text("Screenshots and recordings need Screen Recording access. macOS also shows its own prompt on the first capture; relaunch Fuse after granting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") {
                            PermissionsService.promptForScreenRecording()
                            PermissionsService.openSystemSettings(pane: .screenRecording)
                        }
                    }
                }
            }
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Capture region:", name: .captureRegion)
                KeyboardShortcuts.Recorder("Start/stop recording:", name: .toggleRecording)
            }
            Section("Output") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Save to folder")
                        Text(saveFolderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
                Picker("Screenshot format", selection: $imageFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpg")
                }
                Picker("Recording format", selection: $videoFormat) {
                    Text("MP4").tag("mp4")
                    Text("MOV").tag("mov")
                }
                Toggle("Copy capture to clipboard", isOn: $copyToClipboard)
                Toggle("Open editor after capture", isOn: $openEditorAfter)
            }
            Section {
                Text("Copied captures land in Fuse's clipboard history automatically — every screenshot and recording shows up in the paste picker (⇧⌘V).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasScreenRecording = PermissionsService.hasScreenRecording
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            saveFolderPath = url.path
        }
    }
}
