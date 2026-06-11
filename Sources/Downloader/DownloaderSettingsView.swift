import AppKit
import SwiftUI

struct DownloaderSettingsView: View {
    @AppStorage("downloader.destinationPath") private var destinationPath = NSHomeDirectory() + "/Downloads"
    @AppStorage("downloader.qualityPreset") private var qualityPreset = "best"
    @AppStorage("downloader.maxConcurrent") private var maxConcurrent = 2
    @AppStorage("downloader.container") private var container = "mp4"

    @State private var installing = false
    @State private var installError: String?
    @State private var installedVersion: String?

    var body: some View {
        Form {
            Section("Destination") {
                LabeledContent("Save to") {
                    HStack {
                        Text(destinationPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseDestination)
                    }
                }
            }
            Section("Quality") {
                Picker("Preset", selection: $qualityPreset) {
                    Text("Best available").tag("best")
                    Text("Up to 1080p").tag("1080p")
                    Text("Up to 720p").tag("720p")
                    Text("Audio only (MP3)").tag("audio")
                }
                Picker("Video format", selection: $container) {
                    Text("MP4").tag("mp4")
                    Text("MKV").tag("mkv")
                    Text("WebM").tag("webm")
                    Text("Original (as provided)").tag("original")
                }
                Text("Remuxing into a chosen container requires ffmpeg; without it (or for Audio only), the site's original format is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Max concurrent downloads: \(maxConcurrent)",
                        value: $maxConcurrent, in: 1...4)
            }
            Section("Tools") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("yt-dlp")
                        Text(ytDlpStatusText)
                            .font(.caption)
                            .foregroundStyle(installError == nil ? Color.secondary : Color.red)
                    }
                    Spacer()
                    if installing {
                        ProgressView().controlSize(.small)
                    }
                    Button(installedVersion == nil ? "Install yt-dlp" : "Update yt-dlp",
                           action: installYtDlp)
                        .disabled(installing)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("ffmpeg")
                        if let path = ToolManager.shared.ffmpegPath() {
                            Text(path).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not found. brew install ffmpeg — without it: no 4K merging or MP3 extraction")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: ToolManager.shared.ffmpegPath() != nil
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ToolManager.shared.ffmpegPath() != nil ? .green : .yellow)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            installedVersion = await ToolManager.shared.installedVersion()
        }
    }

    private var ytDlpStatusText: String {
        if installing { return "Installing…" }
        if let installError { return installError }
        if let installedVersion { return "Installed — version \(installedVersion)" }
        return "Not installed"
    }

    private func installYtDlp() {
        installing = true
        installError = nil
        Task {
            do {
                try await ToolManager.shared.installOrUpdateYtDlp()
                installedVersion = await ToolManager.shared.installedVersion()
                if installedVersion == nil {
                    installError = "Installed file does not run — try again."
                }
            } catch {
                installError = error.localizedDescription
            }
            installing = false
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }
}
