import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            VoiceSettingsView()
                .tabItem { Label("Voice", systemImage: "mic") }
            // FUSE:SETTINGS_TABS
        }
        .frame(minWidth: 620, minHeight: 520)
    }
}
