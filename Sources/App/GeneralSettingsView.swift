import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @State private var hasAccessibility = PermissionsService.hasAccessibility
    @State private var hasInputMonitoring = PermissionsService.hasInputMonitoring
    @State private var micStatus = PermissionsService.microphoneStatus
    @State private var hasScreenRecording = PermissionsService.hasScreenRecording
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var conflicts = ConflictDetector.currentConflicts()

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ModuleGrid()
                    .padding(.vertical, 2)
            } header: {
                Text("Fused apps")
            } footer: {
                Text("Turn a whole app on or off in one place. A disabled app keeps its settings but its hotkeys, menu items, and background behavior go quiet immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !conflicts.isEmpty {
                Section("Conflicting utilities detected") {
                    ForEach(conflicts) { conflict in
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            VStack(alignment: .leading) {
                                Text("\(conflict.appName) — overlaps \(conflict.fuseFeature)")
                                Text(conflict.advice).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Permissions") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Window tiling, pasting, notification clearing, scroll control",
                    granted: hasAccessibility,
                    pane: .accessibility,
                    prompt: PermissionsService.promptForAccessibility)
                permissionRow(
                    title: "Input Monitoring",
                    detail: "May be required for scroll event interception",
                    granted: hasInputMonitoring,
                    pane: .inputMonitoring,
                    prompt: PermissionsService.promptForInputMonitoring)
                permissionRow(
                    title: "Microphone",
                    detail: "Push-to-talk dictation",
                    granted: micStatus == .authorized,
                    pane: .microphone,
                    prompt: { PermissionsService.requestMicrophone { _ in } })
                permissionRow(
                    title: "Screen Recording",
                    detail: "Screenshots and screen recordings (Capture)",
                    granted: hasScreenRecording,
                    pane: .screenRecording,
                    prompt: PermissionsService.promptForScreenRecording)
            }
            Section("Startup") {
                Toggle("Launch Fuse at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.app.error("launch-at-login toggle failed: \(error.localizedDescription)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasAccessibility = PermissionsService.hasAccessibility
            hasInputMonitoring = PermissionsService.hasInputMonitoring
            micStatus = PermissionsService.microphoneStatus
            hasScreenRecording = PermissionsService.hasScreenRecording
            conflicts = ConflictDetector.currentConflicts()
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, detail: String, granted: Bool,
                               pane: SettingsPane, prompt: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            if !granted {
                Button("Grant…") {
                    prompt()
                    PermissionsService.openSystemSettings(pane: pane)
                }
            }
        }
    }
}
