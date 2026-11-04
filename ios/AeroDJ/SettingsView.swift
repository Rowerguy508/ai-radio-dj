import AeroDJCore
import SwiftUI

/// App settings sheet (-Fry), opened from the gear on the Stations list. Every build.
/// DJ talk-over & fades (`TalkoverSettingsRow`), then station ratings' "Clear all ratings"
/// (-Nova, PR B; only when the app root set `\.songRating`), then "Delete my DJ data"
/// (Sentinel's #410 n4, -Fry; the app's one purge-all, `PersonalDataReset`).
struct SettingsView: View {
    @Binding var isPresented: Bool
    /// Fixture mode: the talk-over row's unset default is OFF, matching the coordinator.
    let isTestStation: Bool
    /// Nil (previews): no "Delete my DJ data" row.
    var personalDataReset: (any PersonalNarrationResetting)? = nil
    @Environment(\.songRating) private var songRating

    var body: some View {
        NavigationStack {
            Form {
                TalkoverSettingsRow(isTestStation: isTestStation)
                if let songRating { StationRatingsSettingsSection(controller: songRating) }
                if let personalDataReset { PersonalDataResetSection(purger: personalDataReset) }
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

/// "Delete my DJ data", with a confirmation. Runs `PersonalDataReset.run`, which publishes the
/// purge-all every data-reset listener already handles.
struct PersonalDataResetSection: View {
    let purger: any PersonalNarrationResetting
    @State private var confirming = false
    @State private var deleting = false

    var body: some View {
        Section {
            Button(PersonalDataReset.title, role: .destructive) { confirming = true }
                .disabled(deleting)
                .accessibilityIdentifier(PersonalDataReset.accessibilityIdentifier)
                .confirmationDialog(PersonalDataReset.title, isPresented: $confirming, titleVisibility: .visible) {
                    Button(PersonalDataReset.confirm, role: .destructive) {
                        deleting = true
                        Task {
                            await PersonalDataReset.run(purger)
                            deleting = false
                        }
                    }
                } message: {
                    Text(PersonalDataReset.message)
                }
        } footer: {
            Text(PersonalDataReset.footer)
        }
    }
}

#Preview {
    SettingsView(isPresented: .constant(true), isTestStation: false)
}
