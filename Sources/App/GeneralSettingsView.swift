import SwiftUI

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            LabeledContent("Version") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
