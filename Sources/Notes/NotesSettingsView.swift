import AppKit
import KeyboardShortcuts
import SwiftUI

struct NotesSettingsView: View {
    @AppStorage("notes.panelPinned") private var panelPinned = false
    @State private var noteCount: Int?
    @State private var dbSize: String?
    @State private var exportResult: String?

    var body: some View {
        Form {
            Section("Quick Notes") {
                KeyboardShortcuts.Recorder("Toggle notes panel", name: .toggleNotesPanel)
                Toggle("Keep panel open when it loses focus", isOn: $panelPinned)
            }
            Section("Storage") {
                LabeledContent("Notes", value: noteCount.map(String.init) ?? "–")
                LabeledContent("Database size", value: dbSize ?? "–")
            }
            Section("Export") {
                Button("Export all notes as Markdown…") { exportAll() }
                if let exportResult {
                    Text(exportResult).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: loadInfo)
    }

    /// Read once on appear (not on a timer): note count via the shared store,
    /// file size via FileManager + ByteCountFormatter.
    private func loadInfo() {
        if let store = NoteStore.shared {
            noteCount = (try? store.notes(matching: nil))?.count
        } else {
            noteCount = nil
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: NoteStore.onDiskPath),
           let size = attrs[.size] as? Int64 {
            dbSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } else {
            dbSize = nil
        }
    }

    /// Writes one `<sanitized-title-or-Untitled>-<id>.md` per note into a
    /// user-chosen folder. Sanitizing replaces "/" and ":" with "-".
    private func exportAll() {
        guard let store = NoteStore.shared else {
            exportResult = "Notes database unavailable."
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Export"
        openPanel.message = "Choose a folder for the exported Markdown files"
        guard openPanel.runModal() == .OK, let directory = openPanel.url else { return }
        do {
            let notes = try store.notes(matching: nil)
            var written = 0
            for note in notes {
                guard let id = note.id else { continue }
                let blocks = try store.blocks(forNote: id)
                let markdown = MarkdownExporter.markdown(title: note.title, blocks: blocks)
                let base = note.title.isEmpty ? "Untitled" : note.title
                let sanitized = base
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                let url = directory.appendingPathComponent("\(sanitized)-\(id).md")
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                written += 1
            }
            exportResult = "Exported \(written) note\(written == 1 ? "" : "s")."
        } catch {
            Log.notes.error("export failed: \(error.localizedDescription)")
            exportResult = "Export failed: \(error.localizedDescription)"
        }
    }
}
