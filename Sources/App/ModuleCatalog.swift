import SwiftUI

/// Every feature ("fused app") with its single master switch. The key MUST be
/// the exact UserDefaults key the feature's controller checks at its entry
/// points — turning a card off silences that feature immediately.
struct FuseModule: Identifiable, Equatable {
    let key: String      // "<module>.enabled"
    let title: String
    let icon: String

    var id: String { key }

    static let all: [FuseModule] = [
        FuseModule(key: "scroll.enabled", title: "Scroll Reverser", icon: "computermouse"),
        FuseModule(key: "tiling.enabled", title: "Tiling Manager", icon: "rectangle.split.2x1"),
        FuseModule(key: "clipboard.enabled", title: "Clipboard Manager", icon: "doc.on.clipboard"),
        FuseModule(key: "voice.enabled", title: "Speech to Text", icon: "mic"),
        FuseModule(key: "capture.enabled", title: "Capture Image/Video", icon: "camera.viewfinder"),
        FuseModule(key: "downloads.enabled", title: "Download Videos by URL", icon: "arrow.down.circle"),
        FuseModule(key: "notifications.enabled", title: "Notifications Cleaner", icon: "bell.badge"),
        FuseModule(key: "notes.enabled", title: "Notes", icon: "note.text"),
    ]
}

/// One compact card: icon, name, switch. The whole card is clickable.
struct ModuleCard: View {
    let module: FuseModule
    @AppStorage private var enabled: Bool

    init(module: FuseModule) {
        self.module = module
        _enabled = AppStorage(wrappedValue: true, module.key)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: module.icon)
                .font(.system(size: 14))
                .frame(width: 20)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
            Text(module.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(enabled ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(enabled ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { enabled.toggle() }
    }
}

/// The "fused apps" grid shown at the top of General settings.
struct ModuleGrid: View {
    private let columns = [GridItem(.adaptive(minimum: 172), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(FuseModule.all) { module in
                ModuleCard(module: module)
            }
        }
    }
}
