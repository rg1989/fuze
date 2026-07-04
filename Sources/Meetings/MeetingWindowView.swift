import SwiftUI

/// The live meeting window: a source picker + Record/Stop control, the finished
/// speaker-attributed messages as colored bubbles, and a live pipeline row
/// (Listening… → Transcribing…) so you can see it working in near real time.
struct MeetingWindowView: View {
    @ObservedObject var transcriber: MeetingTranscriber
    let controller: MeetingController
    @AppStorage("meetings.audioSource") private var sourceRaw = AudioSourceMode.micOnly.rawValue

    private var mode: AudioSourceMode { AudioSourceMode(rawValue: sourceRaw) ?? .micOnly }
    private var isBusy: Bool { transcriber.status == .running || transcriber.status == .loading }
    private var isLive: Bool { transcriber.status == .running || transcriber.status == .finishing }

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
            centeredStatus.frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(transcriber.lines) { line in bubble(line) }
                        activeRow.id("active").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                }
                .onChange(of: transcriber.lines.count) { _, _ in
                    withAnimation { proxy.scrollTo("active", anchor: .bottom) }
                }
                .onChange(of: transcriber.activity) { _, _ in
                    withAnimation { proxy.scrollTo("active", anchor: .bottom) }
                }
            }
        }
    }

    private func bubble(_ line: SpeakerLine) -> some View {
        let color = speakerColor(line.speakerIndex)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(line.speakerLabel).font(.caption).bold().foregroundStyle(color)
                Text("\(MeetingMarkdownExporter.timecode(line.start)) · \(durationText(line))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(line.text).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.28), lineWidth: 1))
    }

    /// The live pipeline row: what the recorder is doing right now.
    @ViewBuilder
    private var activeRow: some View {
        switch transcriber.activity {
        case .listening:
            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Listening…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var centeredStatus: some View {
        if isLive {
            activeRow
        } else {
            Text(statusHint).foregroundStyle(.secondary).font(.callout)
        }
    }

    private var statusHint: String {
        switch transcriber.status {
        case .idle: return "Pick a source and press Record. English only."
        case .failed(let m): return "Couldn't start: \(m)"
        case .loading: return "Preparing models — first run downloads them once…"
        case .running: return "Listening… speak and your words appear as messages."
        case .finishing: return "Finalizing…"
        case .saved: return "Saved to the library."
        }
    }

    private func speakerColor(_ i: Int) -> Color {
        [.blue, .green, .orange, .purple][i % 4]
    }

    /// "2.4s" — how long this message took to say.
    private func durationText(_ line: SpeakerLine) -> String {
        String(format: "%.1fs", max(0, line.end - line.start))
    }
}
