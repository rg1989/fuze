import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ScrollSettingsView()
                .tabItem { Label("Scroll", systemImage: "computermouse") }
            TilingSettingsView()
                .tabItem { Label("Tiling", systemImage: "rectangle.split.2x1") }
            ClipboardSettingsView()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            VoiceSettingsView()
                .tabItem { Label("Voice", systemImage: "mic") }
            DownloaderSettingsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            NotesSettingsView()
                .tabItem { Label("Notes", systemImage: "note.text") }
            // FUSE:SETTINGS_TABS
        }
        .frame(minWidth: 620, minHeight: 520)
    }
}
