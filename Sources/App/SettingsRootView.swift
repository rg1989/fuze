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
            // FUSE:SETTINGS_TABS
        }
        .frame(minWidth: 620, minHeight: 520)
    }
}
