import AppKit
import SwiftUI

/// Picker state + keyboard routing for the floating downloads panel.
@MainActor
final class DownloadsPickerViewModel: ObservableObject {
    @Published var urlText: String = ""
    @Published var selectedIndex: Int = 0
    @Published var focusRequest: Int = 0

    let queue: DownloadQueue
    var onClose: () -> Void = {}

    init(queue: DownloadQueue) { self.queue = queue }

    var displayItems: [DownloadItem] { queue.displayItems }

    func prepareForShow() {
        urlText = ""
        selectedIndex = 0
        focusRequest += 1
    }

    func submitURL() {
        guard queue.add(url: urlText) else { return }
        urlText = ""
        clampSelection()
    }

    /// true = event fully handled (monitor swallows it); false = pass to URL field.
    func handle(event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:   // esc
            onClose(); return true
        case 126:  // up
            if selectedIndex > 0 { selectedIndex -= 1 }; return true
        case 125:  // down
            if selectedIndex < displayItems.count - 1 { selectedIndex += 1 }; return true
        case 36, 76:  // return / keypad enter
            if event.modifierFlags.contains(.command) {
                submitURL()
            } else if !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                submitURL()
            } else {
                performPrimary(on: selectedIndex)
            }
            return true
        case 49:   // space — pause / resume
            togglePauseResumeSelected(); return true
        case 51:   // delete
            if urlText.isEmpty { removeSelected(); return true }
            return false
        default:
            break
        }
        if event.modifierFlags.contains(.command),
           let digit = Int(event.charactersIgnoringModifiers ?? ""),
           (1...9).contains(digit) {
            performPrimary(on: digit - 1)
            return true
        }
        return false
    }

    func performPrimary(on index: Int) {
        guard displayItems.indices.contains(index) else { return }
        let item = displayItems[index]
        switch item.state {
        case .fetchingMetadata:
            queue.cancel(id: item.id)
        case .downloading:
            queue.pause(id: item.id)
        case .paused:
            queue.resume(id: item.id)
        case .finished:
            showInFinder(item)
        case .failed, .cancelled:
            queue.retry(id: item.id)
        case .queued:
            break
        }
    }

    func togglePauseResumeSelected() {
        guard displayItems.indices.contains(selectedIndex) else { return }
        let item = displayItems[selectedIndex]
        switch item.state {
        case .downloading:
            queue.pause(id: item.id)
        case .paused:
            queue.resume(id: item.id)
        default:
            break
        }
    }

    func removeSelected() {
        guard displayItems.indices.contains(selectedIndex) else { return }
        queue.remove(id: displayItems[selectedIndex].id)
        clampSelection()
    }

    func showInFinder(_ item: DownloadItem) {
        guard let path = item.resultPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func clampSelection() {
        if selectedIndex >= displayItems.count {
            selectedIndex = max(0, displayItems.count - 1)
        }
    }
}

struct DownloadsPickerView: View {
    @ObservedObject var model: DownloadsPickerViewModel
    @ObservedObject var queue: DownloadQueue
    @FocusState private var urlFocused: Bool
    @State private var ytDlpInstalled = ToolManager.shared.ytDlpInstalled

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !ytDlpInstalled {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("yt-dlp not installed — Settings → Downloads")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.15))
            }

            TextField("Paste video URL to download…", text: $model.urlText)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .onSubmit { model.submitURL() }
                .padding(EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 10))

            Divider()

            if model.displayItems.isEmpty {
                Spacer()
                Text("No downloads yet").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(model.displayItems.enumerated()), id: \.element.id) { index, item in
                            DownloadsPickerRow(item: item, index: index)
                                .id(index)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(index == model.selectedIndex
                                            ? Color.accentColor.opacity(0.25) : Color.clear)
                                        .padding(.horizontal, 4))
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedIndex = index }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.selectedIndex) { _, newIndex in proxy.scrollTo(newIndex) }
                }
            }

            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { urlFocused = true }
        .onChange(of: model.focusRequest) { _, _ in urlFocused = true }
        .onReceive(refresh) { _ in
            ytDlpInstalled = ToolManager.shared.ytDlpInstalled
        }
    }

    /// Two aligned columns of keycap + description, grouped by purpose so the
    /// shortcuts read as a tidy table instead of one long wrapping line.
    private var footer: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                keyHint("↩", "pause / resume / retry")
                keyHint("space", "pause / resume")
            }
            GridRow {
                keyHint("⌘↩", "download URL")
                keyHint("⌘1–9", "row action")
            }
            GridRow {
                keyHint("⌫", "remove")
                keyHint("esc", "close")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(minWidth: 16)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DownloadsPickerRow: View {
    let item: DownloadItem
    let index: Int

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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.metadata?.title ?? item.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .downloading || item.state == .paused {
                    ProgressView(value: min(max((item.progress?.percent ?? 0) / 100.0, 0), 1))
                        .opacity(item.state == .paused ? 0.5 : 1)
                }
                HStack(spacing: 6) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                        .lineLimit(item.state == .failed ? 2 : 1)
                        .truncationMode(item.state == .failed ? .tail : .middle)
                    if index < 9 {
                        Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 4)
        }
        .frame(height: item.state == .downloading || item.state == .paused ? 56 : 44)
    }
}
