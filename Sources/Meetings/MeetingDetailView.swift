import AppKit
import SwiftUI

/// Read-only view of a saved meeting: the diarized transcript plus a Copy button
/// that puts the markdown export on the clipboard.
struct MeetingDetailView: View {
    let meeting: Meeting
    let store: MeetingStore?
    @State private var segments: [MeetingSegment] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.headline)
                    Text(meeting.date, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy transcript") { copyTranscript() }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { seg in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(seg.speakerId).font(.caption).bold()
                                    .foregroundStyle(speakerColor(seg.speakerId))
                                Text("\(MeetingMarkdownExporter.timecode(seg.startSeconds)) · \(String(format: "%.1fs", max(0, seg.endSeconds - seg.startSeconds)))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(seg.text).textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let cleaned = meeting.cleanedText, !cleaned.isEmpty {
                Divider()
                DisclosureGroup("Cleaned transcript") {
                    Text(cleaned).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { segments = (try? store?.segments(forMeeting: meeting.id ?? -1)) ?? [] }
    }

    private func copyTranscript() {
        let md = MeetingMarkdownExporter.transcript(title: meeting.title, segments: segments)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    private func speakerColor(_ label: String) -> Color {
        // Derive a stable color from the trailing speaker number.
        let n = Int(label.split(separator: " ").last ?? "1") ?? 1
        return [.blue, .green, .orange, .purple][(n - 1) % 4]
    }
}
