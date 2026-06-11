import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DownloaderSettingsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            // FUSE:SETTINGS_TABS
        }
        .frame(minWidth: 620, minHeight: 520)
    }
}
