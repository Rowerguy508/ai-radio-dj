import AeroDJCore
import SwiftUI

extension View {
    /// DJ talk-over switch (-Fry) in an `AERODJ_OWNER_AB` build (TestFlight `owner_ab: true`),
    /// with or without P0 DIAG. Every other build gets the view unchanged: no switch, and the
    /// flag stays at its build default (OFF), so Debug, fixture mode and tests never talk over.
    /// `isTestStation` picks the unset default the coordinator uses (OFF in fixture mode).
    @ViewBuilder func talkoverToggleEntry(isTestStation: Bool) -> some View {
        #if AERODJ_OWNER_AB
        modifier(TalkoverToggleEntry(isTestStation: isTestStation))
        #else
        self
        #endif
    }
}

#if AERODJ_OWNER_AB
/// A toolbar button on the Player screen. Unset shows the coordinator's unset default (ON live,
/// OFF on the fixture station); flipping it stores a value that applies from the next break.
private struct TalkoverToggleEntry: ViewModifier {
    @AppStorage private var enabled: Bool

    init(isTestStation: Bool) {
        _enabled = AppStorage(wrappedValue: DJTalkoverFlag.unsetDefault(isTestStation: isTestStation),
                              DJTalkoverFlag.defaultsKey)
    }

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $enabled) {
                    Label("DJ talk-over", systemImage: enabled ? "waveform" : "waveform.slash")
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("owner.talkoverToggle")
                .accessibilityValue(enabled ? "On" : "Off")
            }
        }
    }
}
#endif
