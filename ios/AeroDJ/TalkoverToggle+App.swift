import AeroDJCore
import SwiftUI

/// DJ talk-over and fades as a Settings row (-Fry), in every build. The owner's 2026-11-02
/// decision replaces #225's owner A/B-only Player toolbar button. Unset shows the coordinator's
/// unset default (ON on a live station, OFF on the fixture test station); flipping it stores a
/// value under `DJTalkoverFlag.defaultsKey` that applies from the next DJ break.
struct TalkoverSettingsRow: View {
    @AppStorage private var enabled: Bool

    init(isTestStation: Bool, store: UserDefaults = .standard) {
        _enabled = AppStorage(wrappedValue: DJTalkoverFlag.unsetDefault(isTestStation: isTestStation),
                              DJTalkoverFlag.defaultsKey, store: store)
    }

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("DJ talk-over & fades", systemImage: enabled ? "waveform" : "waveform.slash")
            }
            .accessibilityIdentifier("settings.talkoverToggle")
            .accessibilityHint("Recommended")
        } header: {
            Text("DJ")
        } footer: {
            Text("Recommended. The DJ talks over the end of each song while the music dips, and the next song comes back up as the DJ finishes. Turn it off for a pause between songs. Applies from the next DJ break.")
        }
    }
}
