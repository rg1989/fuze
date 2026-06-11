import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            // FUSE:SETTINGS_TABS
        }
        .frame(minWidth: 620, minHeight: 520)
    }
}
