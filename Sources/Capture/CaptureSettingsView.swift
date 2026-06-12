import AppKit
import KeyboardShortcuts
import SwiftUI

struct CaptureSettingsView: View {
    @AppStorage("capture.screenshotFolderPath") private var screenshotFolderPath =
        CaptureController.defaultScreenshotFolder
    @AppStorage("capture.recordingFolderPath") private var recordingFolderPath =
        CaptureController.defaultRecordingFolder
    @AppStorage("capture.copyToClipboard") private var copyToClipboard = true
    @AppStorage("capture.showPreviewAfter") private var showPreviewAfter = true
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
                KeyboardShortcuts.Recorder("Open screenshots folder:", name: .openScreenshotsFolder)
                KeyboardShortcuts.Recorder("Open recordings folder:", name: .openRecordingsFolder)
            }
            Section {
                folderRow(title: "Screenshots folder", path: $screenshotFolderPath)
                folderRow(title: "Recordings folder", path: $recordingFolderPath)
                Picker("Screenshot format", selection: $imageFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpg")
                }
                Picker("Recording format", selection: $videoFormat) {
                    Text("MP4").tag("mp4")
                    Text("MOV").tag("mov")
                }
                Toggle("Show review window after capture", isOn: $showPreviewAfter)
                Toggle("Auto-copy to clipboard (only when review is off)",
                       isOn: $copyToClipboard)
                    .disabled(showPreviewAfter)
            } header: {
                Text("Output")
            } footer: {
                Text("The review window lets you annotate screenshots and trim recordings, then choose Delete, Delete & Copy, Save, or Save & Copy (Return = Save & Copy, Esc = Delete, ⌘S = Save). Nothing is copied to the clipboard unless you pick a Copy action. With the review window off, captures save silently — enable auto-copy to also place them on the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func folderRow(title: String, path: Binding<String>) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(path.wrappedValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") { chooseFolder(into: path) }
        }
    }

    private func chooseFolder(into path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path.wrappedValue)
        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path
        }
    }
}
