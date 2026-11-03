import AeroDJCore
import SwiftUI

/// App settings sheet (-Fry), opened from the gear on the Stations list. Every build.
/// Holds one row today: DJ talk-over & fades (`TalkoverSettingsRow`).
struct SettingsView: View {
    @Binding var isPresented: Bool
    /// Fixture mode: the talk-over row's unset default is OFF, matching the coordinator.
    let isTestStation: Bool

    var body: some View {
        NavigationStack {
            Form {
                TalkoverSettingsRow(isTestStation: isTestStation)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
    }
}

#Preview {
    SettingsView(isPresented: .constant(true), isTestStation: false)
}
