import AeroDJCore
import SwiftUI

extension View {
    /// DJ talk-over switch (-Fry) in an `AERODJ_OWNER_AB` build (TestFlight `owner_ab: true`),
    /// with or without P0 DIAG. Every other build gets the view unchanged: no switch, and the
    /// flag stays at its build default (OFF), so Debug, fixture mode and tests never talk over.
    @ViewBuilder func talkoverToggleEntry() -> some View {
        #if AERODJ_OWNER_AB
        modifier(TalkoverToggleEntry())
        #else
        self
        #endif
    }
}

#if AERODJ_OWNER_AB
/// A toolbar button on the Player screen. Unset reads the build default (ON in this build);
/// flipping it stores an override that applies from the next break (rollback without a build).
private struct TalkoverToggleEntry: ViewModifier {
    @AppStorage(DJTalkoverFlag.defaultsKey) private var enabled = DJTalkoverFlag.buildDefault

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $enabled) {
                    Label("DJ talk-over", systemImage: enabled ? "mic.fill" : "mic.slash")
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("owner.talkoverToggle")
                .accessibilityValue(enabled ? "On" : "Off")
            }
        }
    }
}
#endif
