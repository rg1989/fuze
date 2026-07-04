import AppKit
import SwiftUI

/// Drives the right-side "Extracted Text" panel in the screenshot review window.
@MainActor
final class TextExtractModel: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var isRunning = false
    @Published private(set) var markdown = ""

    /// Runs Vision OCR on `image` and opens the panel with the result. Re-running
    /// (button pressed again) re-extracts the current image.
    func run(on image: NSImage) {
        isOpen = true
        isRunning = true
        markdown = ""
        Task {
            let md = await TextExtractor.markdown(from: image)
            self.markdown = md.trimmingCharacters(in: .whitespacesAndNewlines)
            self.isRunning = false
        }
    }

    func close() { isOpen = false }

    func copyToClipboard() {
        guard !markdown.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
}

/// The right side panel: the extracted markdown (selectable, monospaced so it
/// reads as copy-ready source), with Copy and Close controls.
struct TextExtractSidePanel: View {
    @ObservedObject var model: TextExtractModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Extracted Text", systemImage: "text.viewfinder")
                    .font(.headline)
                Spacer()
                Button { model.copyToClipboard() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy markdown")
                    .disabled(model.markdown.isEmpty)
                Button { model.close() } label: { Image(systemName: "xmark") }
                    .help("Close")
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()

            if model.isRunning {
                Spacer()
                ProgressView("Extracting text…").controlSize(.small)
                Spacer()
            } else if model.markdown.isEmpty {
                Spacer()
                Text("No text found.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    Text(model.markdown)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
