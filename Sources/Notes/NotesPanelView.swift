import AppKit
import SwiftUI

// MARK: - Debouncer

/// Coalesces rapid calls (e.g. every keystroke) into one trailing call
/// `delay` seconds after the last one. Main-thread only.
final class Debouncer {
    private let delay: TimeInterval
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func call(_ action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

// MARK: - View model

/// All state for the notes panel. Owned by NotesController, injected into
/// NotesPanelView. Every store mutation goes through here.
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var blocks: [NoteBlock] = []
    @Published var selectedNoteId: Int64?
    @Published var noteTitle: String = ""
    @Published var searchText: String = "" {
        didSet { if oldValue != searchText { reloadNotes() } }
    }

    private let store: NoteStore
    private let titleDebouncer = Debouncer(delay: 0.5)
    private var blockDebouncers: [Int64: Debouncer] = [:]

    init(store: NoteStore) {
        self.store = store
    }

    // MARK: Loading

    /// Called by NotesController every time the panel is shown.
    func reloadAll() {
        reloadNotes()
    }

    func reloadNotes() {
        do {
            notes = try store.notes(matching: searchText.isEmpty ? nil : searchText)
        } catch {
            Log.notes.error("reload notes failed: \(error.localizedDescription)")
            notes = []
        }
        if selectedNoteId == nil || !notes.contains(where: { $0.id == selectedNoteId }) {
            selectedNoteId = notes.first?.id
        }
        reloadBlocks()
    }

    func selectNote(_ id: Int64?) {
        selectedNoteId = id
        reloadBlocks()
    }

    private func reloadBlocks() {
        guard let id = selectedNoteId else {
            blocks = []
            noteTitle = ""
            return
        }
        do {
            blocks = try store.blocks(forNote: id)
        } catch {
            Log.notes.error("reload blocks failed: \(error.localizedDescription)")
            blocks = []
        }
        noteTitle = notes.first(where: { $0.id == id })?.title ?? ""
    }

    // MARK: Note mutations

    /// New notes start with one empty text block, selected immediately.
    func createNote() {
        do {
            let note = try store.createNote(title: "")
            try store.appendBlock(noteId: note.id!, kind: .text,
                                  textContent: "", language: "", imageData: nil)
            searchText = ""          // clear any filter so the new note is visible
            selectedNoteId = note.id
            reloadNotes()
        } catch {
            Log.notes.error("create note failed: \(error.localizedDescription)")
        }
    }

    /// Called on every keystroke in the title field; persists 0.5 s after the
    /// last keystroke. Refreshes the sidebar WITHOUT calling reloadBlocks(),
    /// which would clobber `noteTitle` mid-edit.
    func setTitle(_ newTitle: String) {
        noteTitle = newTitle
        guard let id = selectedNoteId else { return }
        titleDebouncer.call { [weak self] in
            guard let self else { return }
            do {
                try self.store.renameNote(id: id, title: newTitle)
                self.notes = try self.store.notes(
                    matching: self.searchText.isEmpty ? nil : self.searchText)
            } catch {
                Log.notes.error("rename failed: \(error.localizedDescription)")
            }
        }
    }

    func togglePin(_ note: Note) {
        guard let id = note.id else { return }
        do {
            try store.togglePin(noteId: id)
            reloadNotes()
        } catch {
            Log.notes.error("toggle pin failed: \(error.localizedDescription)")
        }
    }

    func deleteNote(_ note: Note) {
        guard let id = note.id else { return }
        do {
            try store.deleteNote(id: id)     // cascade removes the blocks
            if selectedNoteId == id { selectedNoteId = nil }
            reloadNotes()
        } catch {
            Log.notes.error("delete note failed: \(error.localizedDescription)")
        }
    }

    // MARK: Block mutations

    func appendBlock(kind: BlockKind) {
        guard let noteId = selectedNoteId else { return }
        do {
            try store.appendBlock(noteId: noteId, kind: kind,
                                  textContent: "", language: "", imageData: nil)
            reloadBlocks()
        } catch {
            Log.notes.error("append block failed: \(error.localizedDescription)")
        }
    }

    /// Reads NSPasteboard.general and creates an image/link/text block per
    /// BlockImport's decision. Converts TIFF→PNG when only TIFF is present.
    func appendFromClipboard() {
        guard let noteId = selectedNoteId else { return }
        let pasteboard = NSPasteboard.general
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let plain = pasteboard.string(forType: .string)
        guard let kind = BlockImport.plannedBlock(types: types, plainString: plain) else { return }
        do {
            switch kind {
            case .image:
                guard let png = Self.pngData(from: pasteboard) else { return }
                try store.appendBlock(noteId: noteId, kind: .image,
                                      textContent: "", language: "", imageData: png)
            case .link:
                let trimmed = (plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try store.appendBlock(noteId: noteId, kind: .link,
                                      textContent: trimmed, language: "", imageData: nil)
            case .text:
                try store.appendBlock(noteId: noteId, kind: .text,
                                      textContent: plain ?? "", language: "", imageData: nil)
            case .code:
                break   // BlockImport never returns .code (no auto-detection)
            }
            reloadBlocks()
        } catch {
            Log.notes.error("clipboard import failed: \(error.localizedDescription)")
        }
    }

    /// PNG bytes from the pasteboard; converts TIFF via NSBitmapImageRep
    /// when only TIFF is present (e.g. some screenshot paths).
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Debounced (0.5 s, per block) autosave for content edits. The view's
    /// bindings mutate `blocks` directly; this persists the latest value.
    func scheduleSave(_ block: NoteBlock) {
        guard let blockId = block.id else { return }
        let debouncer = blockDebouncers[blockId] ?? Debouncer(delay: 0.5)
        blockDebouncers[blockId] = debouncer
        debouncer.call { [weak self] in
            guard let self,
                  let current = self.blocks.first(where: { $0.id == blockId }) else { return }
            do {
                try self.store.updateBlock(current)
            } catch {
                Log.notes.error("save block failed: \(error.localizedDescription)")
            }
        }
    }

    /// direction: -1 moves the block up, +1 moves it down.
    func moveBlock(_ block: NoteBlock, direction: Int) {
        guard let noteId = selectedNoteId,
              let from = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let to = from + direction
        guard blocks.indices.contains(to) else { return }
        do {
            try store.moveBlock(noteId: noteId, fromIndex: from, toIndex: to)
            reloadBlocks()
        } catch {
            Log.notes.error("move block failed: \(error.localizedDescription)")
        }
    }

    func deleteBlock(_ block: NoteBlock) {
        guard let noteId = selectedNoteId, let id = block.id else { return }
        blockDebouncers[id]?.cancel()
        blockDebouncers[id] = nil
        do {
            try store.deleteBlock(id: id, noteId: noteId)
            reloadBlocks()
        } catch {
            Log.notes.error("delete block failed: \(error.localizedDescription)")
        }
    }

    /// Manual text↔code conversion (BlockImport never auto-detects code).
    func convertBlock(_ block: NoteBlock, to kind: BlockKind) {
        guard let id = block.id,
              let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        var updated = blocks[index]
        updated.kind = kind
        do {
            try store.updateBlock(updated)
            reloadBlocks()
        } catch {
            Log.notes.error("convert block failed: \(error.localizedDescription)")
        }
    }

    // MARK: Copy (the headline feature)

    /// ONE helper for every per-block Copy button. markInternal: false is
    /// DELIBERATE — this is a real user copy, so the Phase 4 clipboard-history
    /// watcher SHOULD record it. (markInternal: true is reserved for Fuse's
    /// invisible write/restore plumbing.)
    func copyBlock(_ block: NoteBlock) {
        let representation: PasteService.ItemRepresentation
        switch block.kind {
        case .image:
            guard let data = block.imageData else { return }
            representation = [NSPasteboard.PasteboardType.png: data]
        case .text, .code, .link:
            representation = [.string: Data(block.textContent.utf8)]
        }
        PasteService.write([representation], to: .general, markInternal: false)
    }

    func copySelectedNoteAsMarkdown() {
        let markdown = MarkdownExporter.markdown(title: noteTitle, blocks: blocks)
        PasteService.write([[.string: Data(markdown.utf8)]], to: .general, markInternal: false)
    }
}

// MARK: - Root view

struct NotesPanelView: View {
    @ObservedObject var model: NotesViewModel
    @State private var noteToDelete: Note?
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 380)
    }

    // MARK: Left column

    private var sidebar: some View {
        VStack(spacing: 8) {
            TextField("Search notes…", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(EdgeInsets(top: 10, leading: 8, bottom: 0, trailing: 8))
            Button {
                model.createNote()
            } label: {
                Label("New Note", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            if model.notes.isEmpty && model.searchText.isEmpty {
                Spacer()
                Button("Create your first note") { model.createNote() }
                Spacer()
            } else {
                List {
                    ForEach(model.notes) { note in
                        noteRow(note)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectNote(note.id) }
                            .listRowBackground(note.id == model.selectedNoteId
                                ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contextMenu {
                                Button(note.pinned ? "Unpin" : "Pin") { model.togglePin(note) }
                                Button("Delete…", role: .destructive) {
                                    noteToDelete = note
                                    showDeleteConfirmation = true
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .confirmationDialog(
                    "Delete this note?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible,
                    presenting: noteToDelete
                ) { note in
                    Button("Delete \"\(note.title.isEmpty ? "Untitled" : note.title)\"",
                           role: .destructive) {
                        model.deleteNote(note)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("The note and all of its blocks will be removed. This cannot be undone.")
                }
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled" : note.title).lineLimit(1)
                Text(note.updatedAt, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if note.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Right column

    @ViewBuilder
    private var detail: some View {
        if model.selectedNoteId == nil {
            VStack(spacing: 12) {
                Text(model.notes.isEmpty ? "No notes yet" : "Select a note")
                    .foregroundStyle(.secondary)
                if model.notes.isEmpty {
                    Button("Create your first note") { model.createNote() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                TextField("Untitled", text: Binding(
                    get: { model.noteTitle },
                    set: { model.setTitle($0) }))
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14))
                Divider()
                ScrollView {
                    // Plain VStack (NOT LazyVStack): notes have few blocks, and
                    // lazy containers recycle TextEditors mid-edit.
                    VStack(spacing: 10) {
                        ForEach($model.blocks) { $block in
                            BlockView(block: $block, model: model)
                        }
                    }
                    .padding(12)
                }
                Divider()
                blockToolbar
            }
        }
    }

    private var blockToolbar: some View {
        HStack(spacing: 8) {
            Button("+ Text") { model.appendBlock(kind: .text) }
            Button("+ Code") { model.appendBlock(kind: .code) }
            Button("+ From Clipboard") { model.appendFromClipboard() }
            Spacer()
            Button("Copy as Markdown") { model.copySelectedNoteAsMarkdown() }
        }
        .padding(8)
    }
}

// MARK: - One block

struct BlockView: View {
    @Binding var block: NoteBlock
    @ObservedObject var model: NotesViewModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            controls
            content
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.gray.opacity(block.kind == .code ? 0.15 : 0.07)))
        .onHover { hovering = $0 }
        .onChange(of: block.textContent) { _, _ in model.scheduleSave(block) }
        .onChange(of: block.language) { _, _ in model.scheduleSave(block) }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Text(kindLabel).font(.caption2).foregroundStyle(.tertiary)
            if block.kind == .code {
                TextField("language", text: $block.language)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 120)
            }
            Spacer()
            if block.kind == .text || block.kind == .code {
                Menu {
                    Button("Text") { model.convertBlock(block, to: .text) }
                    Button("Code") { model.convertBlock(block, to: .code) }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
                .help("Convert between text and code")
            }
            Button { model.copyBlock(block) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy this block")
            Button { model.moveBlock(block, direction: -1) } label: { Image(systemName: "arrowtriangle.up.fill") }
                .buttonStyle(.borderless).help("Move up")
            Button { model.moveBlock(block, direction: 1) } label: { Image(systemName: "arrowtriangle.down.fill") }
                .buttonStyle(.borderless).help("Move down")
            Button { model.deleteBlock(block) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete block")
        }
        .opacity(hovering ? 1 : 0.35)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .text:
            TextEditor(text: $block.textContent)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
        case .code:
            TextEditor(text: $block.textContent)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
        case .image:
            if let data = block.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("Image unavailable").foregroundStyle(.secondary)
            }
        case .link:
            HStack {
                TextField("https://…", text: $block.textContent)
                    .textFieldStyle(.roundedBorder)
                if let url = URL(string: block.textContent),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private var kindLabel: String {
        switch block.kind {
        case .text: return "Text"
        case .code: return "Code"
        case .image: return "Image"
        case .link: return "Link"
        }
    }
}
