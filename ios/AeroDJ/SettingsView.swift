import AeroDJCore
import SwiftUI

/// App settings sheet (-Fry), opened from the gear on the Stations list. Every build.
/// DJ talk-over & fades (`TalkoverSettingsRow`), then station ratings' "Clear all ratings"
/// (-Nova, PR B; only when the app root set `\.songRating`).
struct SettingsView: View {
    @Binding var isPresented: Bool
    /// Fixture mode: the talk-over row's unset default is OFF, matching the coordinator.
    let isTestStation: Bool
    @Environment(\.songRating) private var songRating

    var body: some View {
        NavigationStack {
            Form {
                TalkoverSettingsRow(isTestStation: isTestStation)
                if let songRating { StationRatingsSettingsSection(controller: songRating) }
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
