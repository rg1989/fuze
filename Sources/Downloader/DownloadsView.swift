import AppKit
import SwiftUI

struct DownloadsView: View {
    @ObservedObject var queue: DownloadQueue
    @State private var urlText = ""
    @State private var ytDlpInstalled = ToolManager.shared.ytDlpInstalled

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !ytDlpInstalled {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("yt-dlp not installed — install from Settings → Downloads")
                        .font(.callout)
                    Spacer()
                }
                .padding(8)
                .background(Color.yellow.opacity(0.15))
            }

            HStack(spacing: 8) {
                TextField("Video URL (https://…)", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Paste") {
                    // A link copied from some apps lands as public.url with no
                    // plain string, so read both, then any URL object.
                    let pb = NSPasteboard.general
                    let pasted = pb.string(forType: .string)
                        ?? pb.string(forType: NSPasteboard.PasteboardType("public.url"))
                        ?? (pb.readObjects(forClasses: [NSURL.self], options: nil)?
                                .first as? URL)?.absoluteString
                    if let pasted {
                        urlText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                Button("Download", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)

            if !queue.items.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Clear completed") { queue.clearFinished() }
                        .disabled(!queue.hasFinished)
                    Button("Clear failed") { queue.clearFailed() }
                        .disabled(!queue.hasFailed)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            if queue.items.isEmpty {
                Spacer()
                Text("No downloads yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(queue.items) { item in
                    DownloadRowView(item: item, queue: queue)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .onReceive(refresh) { _ in
            ytDlpInstalled = ToolManager.shared.ytDlpInstalled
        }
    }

    private func submit() {
        if queue.add(url: urlText) {
            urlText = ""
        }
    }
}

struct DownloadRowView: View {
    let item: DownloadItem
    let queue: DownloadQueue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.metadata?.title ?? item.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .downloading || item.state == .paused {
                    ProgressView(value: min(max((item.progress?.percent ?? 0) / 100.0, 0), 1))
                        .opacity(item.state == .paused ? 0.5 : 1)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(item.state == .failed ? 4 : 2)
                    // Failed: wrap and tail-truncate so the actionable message
                    // reads cleanly. Others: middle-truncate (long file paths).
                    .truncationMode(item.state == .failed ? .tail : .middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.state == .failed ? (item.errorMessage ?? "") : "")
            }
            Spacer()
            actionButtons
        }
        .padding(.vertical, 4)
    }

    private var stateSymbol: String {
        switch item.state {
        case .queued: return "clock"
        case .fetchingMetadata: return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .finished: return .green
        case .failed: return .red
        case .downloading: return .accentColor
        case .paused: return .orange
        case .queued, .fetchingMetadata, .cancelled: return .secondary
        }
    }

    private var caption: String {
        switch item.state {
        case .queued: return "Queued"
        case .fetchingMetadata: return item.statusDetail ?? "Fetching video info…"
        case .downloading:
            guard let p = item.progress else { return item.statusDetail ?? "Starting…" }
            var parts = [String(format: "%.1f%%", p.percent)]
            if !p.speed.isEmpty { parts.append(p.speed) }
            if !p.eta.isEmpty { parts.append("ETA \(p.eta)") }
            return parts.joined(separator: " · ")
        case .paused:
            guard let p = item.progress else { return "Paused" }
            return String(format: "Paused · %.1f%%", p.percent)
        case .finished: return item.resultPath ?? "Done"
        case .failed: return item.errorMessage ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch item.state {
        case .fetchingMetadata:
            Button("Cancel") { queue.cancel(id: item.id) }
        case .downloading:
            Button("Pause") { queue.pause(id: item.id) }
            Button("Cancel") { queue.cancel(id: item.id) }
        case .paused:
            Button("Resume") { queue.resume(id: item.id) }
            Button("Cancel") { queue.cancel(id: item.id) }
        case .finished:
            Button("Show in Finder") { showInFinder() }
            Button("Remove") { queue.remove(id: item.id) }
        case .failed, .cancelled:
            Button("Retry") { queue.retry(id: item.id) }
            Button("Remove") { queue.remove(id: item.id) }
        case .queued:
            Button("Remove") { queue.remove(id: item.id) }
        }
    }

    private func showInFinder() {
        guard let path = item.resultPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
