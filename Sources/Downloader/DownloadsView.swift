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
                    if let text = NSPasteboard.general.string(forType: .string) {
                        urlText = text
                    }
                }
                Button("Download", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)

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
                if item.state == .downloading {
                    ProgressView(value: min(max((item.progress?.percent ?? 0) / 100.0, 0), 1))
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
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
        case .queued, .fetchingMetadata, .cancelled: return .secondary
        }
    }

    private var caption: String {
        switch item.state {
        case .queued: return "Queued"
        case .fetchingMetadata: return "Fetching video info…"
        case .downloading:
            guard let p = item.progress else { return "Starting…" }
            var parts = [String(format: "%.1f%%", p.percent)]
            if !p.speed.isEmpty { parts.append(p.speed) }
            if !p.eta.isEmpty { parts.append("ETA \(p.eta)") }
            return parts.joined(separator: " · ")
        case .finished: return item.resultPath ?? "Done"
        case .failed: return item.errorMessage ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch item.state {
        case .fetchingMetadata, .downloading:
            Button("Cancel") { queue.cancel(id: item.id) }
        case .finished:
            Button("Show in Finder") { showInFinder() }
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
