import AppKit
import SwiftUI

/// Picker state + behavior. The controller installs an NSEvent local monitor
/// while the panel is visible and forwards keyDown events to handle(event:);
/// unhandled events fall through to the search field.
final class PastePickerViewModel: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var query: String = "" { didSet { reload() } }
    @Published var selectedIndex: Int = 0
    /// Incremented on each show; the view refocuses the search field on change.
    @Published var focusRequest: Int = 0

    private let store: ClipboardStore
    var onPaste: (ClipboardItem) -> Void = { _ in }   // set by ClipboardController
    var onClose: () -> Void = {}                      // set by ClipboardController

    init(store: ClipboardStore) { self.store = store }

    func reload() {
        do {
            items = try store.recentItems(limit: 100, matching: query.isEmpty ? nil : query)
        } catch {
            Log.clipboard.error("picker reload failed: \(error.localizedDescription)")
            items = []
        }
        if selectedIndex >= items.count { selectedIndex = max(0, items.count - 1) }
    }

    func prepareForShow() {
        query = ""          // didSet triggers reload()
        selectedIndex = 0
        focusRequest += 1
    }

    /// true = event fully handled (monitor swallows it); false = pass to search field.
    func handle(event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:   // esc
            onClose(); return true
        case 126:  // up arrow
            if selectedIndex > 0 { selectedIndex -= 1 }; return true
        case 125:  // down arrow
            if selectedIndex < items.count - 1 { selectedIndex += 1 }; return true
        case 36, 76:  // return / keypad enter — ⌘↩ pins, ↩ pastes
            if event.modifierFlags.contains(.command) { togglePinSelected() } else { pasteSelected() }
            return true
        case 51:   // delete: with empty query deletes the selected item
            if query.isEmpty { deleteSelected(); return true }
            return false
        default:
            break
        }
        if event.modifierFlags.contains(.command),   // ⌘1–⌘9 pastes the nth item
           let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
            pasteItem(at: digit - 1)
            return true
        }
        return false   // typed characters go to the search field
    }

    func pasteSelected() { pasteItem(at: selectedIndex) }

    func pasteItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        onPaste(items[index])
    }

    func togglePinSelected() {
        guard items.indices.contains(selectedIndex), let id = items[selectedIndex].id else { return }
        do { try store.togglePin(id: id); reload() }
        catch { Log.clipboard.error("toggle pin failed: \(error.localizedDescription)") }
    }

    func deleteSelected() {
        guard items.indices.contains(selectedIndex), let id = items[selectedIndex].id else { return }
        do { try store.delete(id: id); reload() }
        catch { Log.clipboard.error("delete failed: \(error.localizedDescription)") }
    }
}

struct PastePickerView: View {
    @ObservedObject var model: PastePickerViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search clipboard history…", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 10))
            Divider()
            if model.items.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(for: item, index: index)
                                .id(index)
                                .listRowBackground(index == model.selectedIndex
                                    ? Color.accentColor.opacity(0.25) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectedIndex = index
                                    model.pasteSelected()
                                }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: model.selectedIndex) { _, newIndex in proxy.scrollTo(newIndex) }
                }
            }
            Divider()
            Text("↩ paste · ⌘↩ pin · ⌫ delete · esc close")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(width: 420, height: 480)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
    }

    @ViewBuilder
    private func row(for item: ClipboardItem, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: item.kind)).frame(width: 18).foregroundStyle(.secondary)
            if item.kind == "image", let data = item.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 60, maxHeight: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
                HStack(spacing: 6) {
                    if index < 9 { Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary) }
                    Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for kind: String) -> String {
        switch kind {
        case "text": return "doc.plaintext"
        case "link": return "link"
        case "image": return "photo"
        case "file": return "doc"
        case "rtf": return "textformat"
        default: return "questionmark.square"
        }
    }
}
