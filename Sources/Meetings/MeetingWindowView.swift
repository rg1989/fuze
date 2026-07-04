import SwiftUI

/// The live meeting window: a source picker + Record/Stop control, then an
/// auto-scrolling list of SpeakerLines (confirmed solid, volatile/tentative
/// greyed). Binds to MeetingTranscriber.$lines.
struct MeetingWindowView: View {
    @ObservedObject var transcriber: MeetingTranscriber
    let controller: MeetingController
    @AppStorage("meetings.audioSource") private var sourceRaw = AudioSourceMode.micOnly.rawValue

    private var mode: AudioSourceMode { AudioSourceMode(rawValue: sourceRaw) ?? .micOnly }
    private var isBusy: Bool { transcriber.status == .running || transcriber.status == .loading }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $sourceRaw) {
                    ForEach(AudioSourceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize().disabled(isBusy)
                Spacer()
                transport
            }
            .padding(12)
            Divider()
            transcript
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    @ViewBuilder
    private var transport: some View {
        switch transcriber.status {
        case .idle, .failed:
            Button("Record") { controller.beginSession(mode: mode) }
                .keyboardShortcut(.return)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing models…").font(.caption).foregroundStyle(.secondary)
            }
        case .running:
            Button("Stop & Save") { Task { await controller.stopRecording(discard: false) } }
                .keyboardShortcut(.return)
        case .finishing:
            ProgressView().controlSize(.small)
        case .saved:
            HStack(spacing: 8) {
                Label("Saved to library", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                Button("New Meeting") { controller.openMeetingWindow() }
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if transcriber.lines.isEmpty {
            Spacer()
            Text(statusHint).foregroundStyle(.secondary).font(.callout)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(transcriber.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.speakerLabel).font(.caption).bold()
                                    .foregroundStyle(speakerColor(line.speakerIndex))
                                Text(line.text)
                                    .foregroundStyle(line.isFinal ? .primary : .secondary)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: transcriber.lines.count) { _, _ in
                    if let last = transcriber.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var statusHint: String {
        switch transcriber.status {
        case .idle: return "Pick a source and press Record. English only."
        case .failed(let m): return "Couldn't start: \(m)"
        case .loading: return "Preparing models — first run downloads them once…"
        case .running: return "Listening… speech appears here with speaker labels."
        case .finishing: return "Finalizing…"
        case .saved: return "Saved to the library."
        }
    }

    private func speakerColor(_ i: Int) -> Color {
        [.blue, .green, .orange, .purple][i % 4]
    }
}
