import KeyboardShortcuts
import SwiftUI

struct NotificationsSettingsView: View {
    @AppStorage("notifications.autoClearEnabled") private var autoClearEnabled = false
    @AppStorage("notifications.autoClearIntervalMinutes") private var autoClearIntervalMinutes = 30
    @State private var lastClearResult: String?
    @State private var lastDumpResult: String?
    @State private var hasAccessibility = PermissionsService.hasAccessibility

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !hasAccessibility {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        VStack(alignment: .leading) {
                            Text("Accessibility permission required")
                            Text("Fuse clears notifications by performing Notification Center's accessibility actions.")
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

            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Clear notifications", name: .clearNotifications)
                HStack {
                    Button("Clear now") {
                        lastClearResult = "Clearing…"
                        DispatchQueue.global(qos: .utility).async {
                            let performed = NotificationClearer().clearAll()
                            DispatchQueue.main.async {
                                lastClearResult = "Performed \(performed) clear action(s)"
                            }
                        }
                    }
                    if let lastClearResult {
                        Text(lastClearResult).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Auto-clear") {
                Toggle("Clear automatically on a schedule", isOn: $autoClearEnabled)
                Stepper("Every \(autoClearIntervalMinutes) minutes",
                        value: $autoClearIntervalMinutes, in: 5...240, step: 5)
                    .disabled(!autoClearEnabled)
                Text("Auto-clear silently dismisses every notification on the schedule — including ones you haven't read yet. That's why it ships OFF.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Debug") {
                Button("Dump Notification Center AX tree (debug)") {
                    lastDumpResult = "Dumping…"
                    DispatchQueue.global(qos: .utility).async {
                        let path = AXDump.dumpNotificationCenter()
                        DispatchQueue.main.async {
                            lastDumpResult = path ?? "Notification Center process not found"
                        }
                    }
                }
                if let lastDumpResult {
                    Text(lastDumpResult).font(.caption).textSelection(.enabled)
                }
                Text("If clearing stops working after a macOS update: dump the tree, find the new action descriptions, and update SweepMatch in NotificationSweep.swift.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Fuse performs Notification Center's own \"Clear All\" and \"Close\" accessibility actions — the same clicks you would make by hand, just automated. Focus and Do Not Disturb don't block it: clearing empties the notification drawer; it never suppresses new arrivals.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasAccessibility = PermissionsService.hasAccessibility
        }
    }
}
