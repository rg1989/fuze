import SwiftUI

// All settings tabs. (The old FUSE:SETTINGS_TABS anchor is retired — new
// features add a case here and a row in `content`.)
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, scroll, tiling, clipboard, voice, capture, downloads, notifications, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .scroll: return "Scroll Reverser"
        case .tiling: return "Tiling Manager"
        case .clipboard: return "Clipboard Manager"
        case .voice: return "Speech to Text"
        case .capture: return "Capture Image/Video"
        case .downloads: return "Download Videos by URL"
        case .notifications: return "Notifications Cleaner"
        case .notes: return "Notes"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .scroll: return "computermouse"
        case .tiling: return "rectangle.split.2x1"
        case .clipboard: return "doc.on.clipboard"
        case .voice: return "mic"
        case .capture: return "camera.viewfinder"
        case .downloads: return "arrow.down.circle"
        case .notifications: return "bell.badge"
        case .notes: return "note.text"
        }
    }
}

/// Custom always-visible horizontal tab bar. SwiftUI's TabView on macOS 26
/// collapses 8 tabs into an overflow chevron menu; this never does.
struct SettingsRootView: View {
    @State private var selection: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 560)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17))
                            .frame(height: 20)
                        Text(tab.title)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(width: 86, height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                .background(
                    selection == tab ? Color.accentColor.opacity(0.13) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: GeneralSettingsView()
        case .scroll: ScrollSettingsView()
        case .tiling: TilingSettingsView()
        case .clipboard: ClipboardSettingsView()
        case .voice: VoiceSettingsView()
        case .capture: CaptureSettingsView()
        case .downloads: DownloaderSettingsView()
        case .notifications: NotificationsSettingsView()
        case .notes: NotesSettingsView()
        }
    }
}
