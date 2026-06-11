import SwiftUI

struct ScrollSettingsView: View {
    @AppStorage("scroll.enabled") private var enabled = true
    @AppStorage("scroll.reverseTrackpad") private var reverseTrackpad = true
    @AppStorage("scroll.reverseMouse") private var reverseMouse = true
    @AppStorage("scroll.reverseHorizontal") private var reverseHorizontal = false

    @State private var hasAccessibility = PermissionsService.hasAccessibility
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !hasAccessibility {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility permission required")
                                .foregroundStyle(.red)
                            Text("Scroll control intercepts scroll events, which needs Accessibility. Fuse keeps retrying and starts reversing as soon as it is granted.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant…") {
                            PermissionsService.promptForAccessibility()
                            PermissionsService.openSystemSettings(pane: .accessibility)
                        }
                    }
                }
            }
            Section("Scroll direction") {
                Toggle("Reverse scrolling", isOn: $enabled)
                Toggle("Reverse trackpad & Magic Mouse", isOn: $reverseTrackpad)
                    .disabled(!enabled)
                Toggle("Reverse mouse scroll wheel", isOn: $reverseMouse)
                    .disabled(!enabled)
                Toggle("Also reverse horizontal scrolling", isOn: $reverseHorizontal)
                    .disabled(!enabled)
            }
            Section {
                Text("Trackpads and Magic Mice both report \"continuous\" scrolling, so macOS cannot tell them apart without per-device drivers. Fuse treats them as one class: the trackpad toggle also covers Magic Mice. Classic scroll wheels are controlled by the mouse toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasAccessibility = PermissionsService.hasAccessibility
        }
    }
}
