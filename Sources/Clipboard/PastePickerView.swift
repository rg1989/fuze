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

    /// The stored file URL of a "file"-kind item, for thumbnail generation.
    func fileURL(for item: ClipboardItem) -> URL? {
        guard item.kind == "file", let id = item.id,
              let reps = try? store.representations(forItem: id),
              let data = reps.first(where: { $0.type == "public.file-url" })?.data
        else { return nil }
        return URL(dataRepresentation: data, relativeTo: nil)
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
                            PickerRow(item: item, index: index, fileURL: model.fileURL(for: item))
                                .id(index)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(index == model.selectedIndex
                                            ? Color.accentColor.opacity(0.25) : Color.clear)
                                        .padding(.horizontal, 4))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectedIndex = index
                                    model.pasteSelected()
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.selectedIndex) { _, newIndex in proxy.scrollTo(newIndex) }
                }
            }
            Divider()
            Text("↩ paste · ⌘↩ pin · ⌫ delete · esc close")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(width: 460, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
    }
}

/// One clipboard row: fixed 44×44 visual box (thumbnail / favicon / colored
/// kind icon) + preview + colored kind badge. Every row is exactly the same
/// height so the list scans uniformly.
private struct PickerRow: View {
    let item: ClipboardItem
    let index: Int
    let fileURL: URL?

    @State private var visual: NSImage?

    private var style: KindStyle { KindStyle.style(for: item.kind) }
    private var isVideoFile: Bool { fileURL.map { ClipboardMedia.isVideo(path: $0.path) } ?? false }
    private var linkHost: String? { item.kind == "link" ? URL(string: item.preview)?.host : nil }
    private var kindLabel: String { isVideoFile ? "Video" : item.kind.capitalized }

    var body: some View {
        HStack(spacing: 10) {
            visualBox
            VStack(alignment: .leading, spacing: 3) {
                Text(item.preview.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(kindLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(style.tint)
                        .background(style.tint.opacity(0.16), in: Capsule())
                    if let linkHost {
                        Text(linkHost).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if index < 9 {
                        Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(height: 48)
        .task(id: item.id) { await loadVisual() }
    }

    @ViewBuilder
    private var visualBox: some View {
        ZStack(alignment: .bottomTrailing) {
            if let visual {
                Image(nsImage: visual)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style.tint.opacity(0.5), lineWidth: 1))
                if isVideoFile {
                    badge("play.fill")
                } else if item.kind == "link" {
                    badge("link")
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(style.tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: style.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(style.tint))
            }
        }
        .frame(width: 44, height: 44)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(style.tint, in: Circle())
            .offset(x: 3, y: 3)
    }

    private func loadVisual() async {
        // A stored thumbnail wins for ANY kind: capture-copied screenshots are
        // kind "file" (a file URL rides along) but the watcher thumbnailed the
        // image data — without this, those rows fall back to a generic icon.
        if let stored = item.thumbnail.flatMap(NSImage.init(data:)) {
            visual = stored
            return
        }
        switch item.kind {
        case "file":
            if let fileURL { visual = await FileThumbnailLoader.thumbnail(for: fileURL) }
        case "link":
            visual = await FaviconLoader.favicon(forLink: item.preview)
        default:
            visual = nil
        }
    }
}
