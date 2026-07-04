import AppKit
import SwiftUI

/// Library view-model — mirrors DownloadsPickerViewModel. Search field +
/// selectable list + the same keyCode map (esc/up/down/return/delete). Delete
/// only fires when the search field is empty.
@MainActor
final class TranscriptLibraryViewModel: ObservableObject {
    @Published var searchText = "" { didSet { reload() } }
    @Published var selectedIndex = 0
    @Published var focusRequest = 0
    @Published private(set) var items: [Meeting] = []

    let store: MeetingStore?
    var onClose: () -> Void = {}
    var onOpen: (Meeting) -> Void = { _ in }

    init(store: MeetingStore?) { self.store = store; reload() }

    func reload() {
        items = (try? store?.meetings(matching: searchText.isEmpty ? nil : searchText)) ?? []
        if selectedIndex >= items.count { selectedIndex = max(0, items.count - 1) }
    }

    func prepareForShow() { searchText = ""; selectedIndex = 0; focusRequest += 1; reload() }

    /// true = swallow the key; false = pass to the search field.
    func handle(event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: onClose(); return true                                      // esc
        case 126: if selectedIndex > 0 { selectedIndex -= 1 }; return true   // up
        case 125: if selectedIndex < items.count - 1 { selectedIndex += 1 }; return true // down
        case 36, 76: openSelected(); return true                            // return → open
        case 51: if searchText.isEmpty { deleteSelected(); return true }; return false   // delete
        default: return false
        }
    }

    func openSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        onOpen(items[selectedIndex])
    }

    func deleteSelected() {
        guard items.indices.contains(selectedIndex), let id = items[selectedIndex].id else { return }
        try? store?.deleteMeeting(id: id)
        reload()
    }
}

struct TranscriptLibraryView: View {
    @ObservedObject var model: TranscriptLibraryViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search meetings…", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 10))
            Divider()
            if model.items.isEmpty {
                Spacer()
                Text("No meetings yet").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, m in
                            MeetingRow(meeting: m)
                                .id(index)
                                .contentShape(Rectangle())
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(index == model.selectedIndex
                                              ? Color.accentColor.opacity(0.25) : Color.clear))
                                .onTapGesture { model.selectedIndex = index }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.selectedIndex) { _, i in proxy.scrollTo(i) }
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
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
    }

    private var footer: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                keyHint("↩", "open")
                keyHint("⌫", "delete")
            }
            GridRow {
                keyHint("↑↓", "select")
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

private struct MeetingRow: View {
    let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.date, style: .date)
                Text(durationText).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var durationText: String {
        let total = Int(meeting.durationSeconds.rounded())
        return String(format: "· %d:%02d", total / 60, total % 60)
    }
}
