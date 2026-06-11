import KeyboardShortcuts
import SwiftUI

struct TilingSettingsView: View {
    @AppStorage("tiling.enabled") private var tilingEnabled = true
    @AppStorage("tiling.gap") private var gap = 0.0
    @State private var hasAccessibility = PermissionsService.hasAccessibility

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !hasAccessibility {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Accessibility permission required")
                                .foregroundStyle(.red)
                            Text("Fuse cannot move other apps' windows without it.")
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
            Section {
                Toggle("Enable window tiling", isOn: $tilingEnabled)
                HStack {
                    Slider(value: $gap, in: 0...24, step: 1) {
                        Text("Window gap")
                    }
                    Text("\(Int(gap)) pt")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Gap is applied at screen edges and between adjacent tiled windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Halves") {
                KeyboardShortcuts.Recorder("Left half", name: .tileLeftHalf)
                KeyboardShortcuts.Recorder("Right half", name: .tileRightHalf)
                KeyboardShortcuts.Recorder("Top half", name: .tileTopHalf)
                KeyboardShortcuts.Recorder("Bottom half", name: .tileBottomHalf)
            }
            Section("Quarters") {
                KeyboardShortcuts.Recorder("Top left", name: .tileTopLeft)
                KeyboardShortcuts.Recorder("Top right", name: .tileTopRight)
                KeyboardShortcuts.Recorder("Bottom left", name: .tileBottomLeft)
                KeyboardShortcuts.Recorder("Bottom right", name: .tileBottomRight)
            }
            Section("Other") {
                KeyboardShortcuts.Recorder("Maximize", name: .tileMaximize)
                KeyboardShortcuts.Recorder("Center", name: .tileCenter)
                KeyboardShortcuts.Recorder("Next display", name: .tileNextDisplay)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(refresh) { _ in
            hasAccessibility = PermissionsService.hasAccessibility
        }
    }
}
