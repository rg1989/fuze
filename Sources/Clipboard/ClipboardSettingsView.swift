import KeyboardShortcuts
import SwiftUI

struct ClipboardSettingsView: View {
    @AppStorage("clipboard.enabled") private var enabled = true
    @AppStorage("clipboard.maxItems") private var maxItems = 500
    @State private var showClearConfirmation = false
    @State private var clearError: String?
    @State private var hasAccessibility = PermissionsService.hasAccessibility

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Clipboard History") {
                Toggle("Enable clipboard history", isOn: $enabled)
                Stepper(value: $maxItems, in: 100...2000, step: 100) {
                    LabeledContent("Maximum items", value: "\(maxItems)")
                }
                KeyboardShortcuts.Recorder("Open paste picker", name: .pastePicker)
            }
            Section("History") {
                Button("Clear unpinned history…", role: .destructive) { showClearConfirmation = true }
                if let clearError { Text(clearError).font(.caption).foregroundStyle(.red) }
            }
            if !hasAccessibility {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        VStack(alignment: .leading) {
                            Text("Accessibility permission missing")
                            Text("Pasting into other apps synthesizes ⌘V, which requires Accessibility.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") {
                            PermissionsService.promptForAccessibility()
                            PermissionsService.openSystemSettings(pane: .accessibility)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in hasAccessibility = PermissionsService.hasAccessibility }
        .alert("Clear unpinned history?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) { clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All unpinned clipboard items will be deleted. Pinned items are kept.")
        }
    }

    private func clearUnpinned() {
        guard let store = ClipboardStore.shared else {
            clearError = "Clipboard database is unavailable."
            return
        }
        do {
            try store.deleteAllUnpinned()
            clearError = nil
        } catch {
            clearError = "Clearing failed: \(error.localizedDescription)"
        }
    }
}
