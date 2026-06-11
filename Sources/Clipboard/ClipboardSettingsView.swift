import AppKit
import KeyboardShortcuts
import SwiftUI

struct ClipboardSettingsView: View {
    @AppStorage("clipboard.enabled") private var enabled = true
    @AppStorage("clipboard.maxItems") private var maxItems = 500
    @AppStorage(CopySound.enabledKey) private var copySound = true
    @AppStorage(CopySound.nameKey) private var copySoundName = CopySound.defaultName
    @State private var showClearConfirmation = false
    @State private var clearError: String?
    @State private var hasAccessibility = PermissionsService.hasAccessibility
    @State private var excludedApps: [String] = ClipboardExclusions.current().sorted()
    @State private var selectedRunningApp: String = ""

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Clipboard History") {
                Toggle("Enable clipboard history", isOn: $enabled)
                Stepper(value: $maxItems, in: 100...2000, step: 100) {
                    LabeledContent("Maximum items", value: "\(maxItems)")
                }
                KeyboardShortcuts.Recorder("Open paste picker", name: .pastePicker)
                Toggle("Play sound when something is copied", isOn: $copySound)
                if copySound {
                    Picker("Copy sound", selection: $copySoundName) {
                        ForEach(CopySound.availableSounds(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onChange(of: copySoundName) { _, newName in
                        CopySound.preview(newName)   // hear it as you pick
                    }
                }
            }
            Section("History") {
                Button("Clear unpinned history…", role: .destructive) { showClearConfirmation = true }
                if let clearError { Text(clearError).font(.caption).foregroundStyle(.red) }
            }
            Section("Privacy — never record from") {
                if excludedApps.isEmpty {
                    Text("No excluded apps. Consider adding your terminal and password tools — the history database is not encrypted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(excludedApps, id: \.self) { bundleID in
                    HStack {
                        Text(appDisplayName(for: bundleID))
                        Text(bundleID).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") {
                            ClipboardExclusions.remove(bundleID)
                            excludedApps = ClipboardExclusions.current().sorted()
                        }
                    }
                }
                HStack {
                    Picker("Add running app", selection: $selectedRunningApp) {
                        Text("Choose…").tag("")
                        ForEach(runningAppChoices(), id: \.self) { bundleID in
                            Text(appDisplayName(for: bundleID)).tag(bundleID)
                        }
                    }
                    Button("Add") {
                        guard !selectedRunningApp.isEmpty else { return }
                        ClipboardExclusions.add(selectedRunningApp)
                        excludedApps = ClipboardExclusions.current().sorted()
                        selectedRunningApp = ""
                    }
                    .disabled(selectedRunningApp.isEmpty)
                }
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

    private func runningAppChoices() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !excludedApps.contains($0) }
            .sorted()
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        return bundleID
    }
}
