import AeroDJCore
import SwiftUI

extension View {
    /// The cloud-voice consent sheet for an internal TestFlight tester build (#378 §4,
    /// `AERODJ_TESTER_VOICE`); a no-op in every other build, owner A/B builds included, so no
    /// existing screen or snapshot changes. -Atlas
    @ViewBuilder func testerCloudVoiceConsent() -> some View {
        #if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
        modifier(TesterCloudVoiceConsentGate())
        #else
        self
        #endif
    }
}

#if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
/// Asks once per launch while the stored answer is undecided, and only where the tester voice
/// could run (App Attest supported, clients configured). It records into the existing
/// `CloudVoiceConsentStore` (#258) with `accept()` / `decline()`, the same answer #258's sheet
/// and toggle use, and shows #258's disclosure copy (`CloudVoiceConsentCopy`). Nothing is sent
/// before "Use cloud voice". Swiping it away leaves the answer undecided: on-device only.
private struct TesterCloudVoiceConsentGate: ViewModifier {
    @MainActor private static var askedThisLaunch = false
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !Self.askedThisLaunch, TesterCloudVoice.tokens != nil, TesterCloudVoice.attestSupported,
                      TesterCloudVoice.consent.shouldOfferSheet else { return }
                Self.askedThisLaunch = true
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                TesterCloudVoiceConsentSheet { accepted in
                    TesterCloudVoice.record(accepted: accepted)
                    isPresented = false
                }
                .presentationDetents([.large])
            }
    }
}

extension TesterCloudVoice {
    /// Set once at launch (`AppDependencies.live`): the launch's preparer and renderer, so a
    /// withdrawal drops prepared cloud breaks and deletes cached cloud clips (Echo's N2 on #395).
    @MainActor static var preparer: DJBreakPreparer?
    @MainActor static var renderer: VoiceRenderer?

    /// The one place the tester build records an answer (the sheet and the Cloud voice toggle).
    /// Accept: enrollment starts in the background; the first break never waits on it.
    /// Decline or toggle off: the next render is on-device (the token source reads the store per
    /// request), prepared breaks with cloud audio are dropped and cached cloud clips deleted. -Nova
    @MainActor static func record(accepted: Bool) {
        if accepted {
            consentStore.accept()
            if let tokens { Task.detached(priority: .utility) { await tokens.prepare() } }
        } else {
            consentStore.decline()
            let preparer = preparer, renderer = renderer
            Task {
                await preparer?.dropCloudVoiceBreaks()
                await renderer?.purgeCloudClips()
            }
        }
    }
}

/// Tune → DJ: the "Cloud voice" switch for testers (Sentinel's N1 on #395), the minimal piece of
/// #258's `CloudVoiceToggleCard` this build needs: same copy, same identifier, same store. On is
/// only reachable through the consent sheet; off takes effect for the next DJ line. Compiled only
/// in the tester build, so no other build's Tune screen or snapshot changes. -Nova
///
/// `settingsBlocked` (Tune's `blockedMessage`, Fry's nit 1 on #398): turning the cloud voice OFF
/// always works, because withdrawing consent must never wait on station settings. Turning it ON
/// stays blocked while settings are loading or read-only, matching the rest of Tune: nothing new
/// is switched on from a screen that is locked. -Nova
struct TesterCloudVoiceToggleCard: View {
    let settingsBlocked: Bool
    @State private var granted = TesterCloudVoice.consentStore.isGranted
    @State private var asking = false

    /// Explicit: the private `@State` properties make the memberwise initializer private.
    init(settingsBlocked: Bool) { self.settingsBlocked = settingsBlocked }

    var body: some View {
        if CloudVoiceConsentPrompt.isCloudVoiceOfferedInThisBuild(selectedVoiceID: PremiumVoiceSelectionStore().selectedVoiceID) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(CloudVoiceConsentCopy.toggleTitle, isOn: Binding(get: { granted }, set: { on in
                    if on {
                        asking = true
                    } else {
                        TesterCloudVoice.record(accepted: false)
                        granted = false
                    }
                }))
                .accessibilityIdentifier("tune.cloudVoiceToggle")
                .disabled(settingsBlocked && !granted)   // off is always possible; on waits for Tune
                Text(CloudVoiceConsentCopy.footer)
                    .font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .workspaceCardBackground(Color(.tertiarySystemFill).opacity(0.6))
            .onAppear { granted = TesterCloudVoice.consentStore.isGranted }
            .sheet(isPresented: $asking, onDismiss: { granted = TesterCloudVoice.consentStore.isGranted }) {
                TesterCloudVoiceConsentSheet { accepted in
                    TesterCloudVoice.record(accepted: accepted)
                    granted = accepted
                    asking = false
                }
                .presentationDetents([.large])
            }
        }
    }
}

/// #258's copy, minus `switchBack` ("…in Settings"): the tester build's Cloud voice toggle is in
/// Tune → DJ (`TesterCloudVoiceToggleCard`), not Settings, so the line would point testers to the
/// wrong screen. The copy itself is left to Atlas's consent-text fix on #395 (N2).
private struct TesterCloudVoiceConsentSheet: View {
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(CloudVoiceConsentCopy.title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(CloudVoiceConsentCopy.intro)
                    labelled(CloudVoiceConsentCopy.sentHeading, CloudVoiceConsentCopy.sent)
                    labelled(CloudVoiceConsentCopy.neverSentHeading, CloudVoiceConsentCopy.neverSent)
                    labelled(CloudVoiceConsentCopy.storedHeading, CloudVoiceConsentCopy.stored)
                    Link(CloudVoiceConsentCopy.elevenLabsPolicyLabel, destination: CloudVoiceConsentCopy.elevenLabsPolicyURL)
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            VStack(spacing: 10) {
                Button { answer(true) } label: {
                    Text(CloudVoiceConsentCopy.accept).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("cloudVoiceConsent.accept")
                Button { answer(false) } label: {
                    Text(CloudVoiceConsentCopy.decline).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("cloudVoiceConsent.decline")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func labelled(_ heading: String, _ body: String) -> some View {
        (Text(heading).bold() + Text(" ") + Text(body)).accessibilityElement(children: .combine)
    }
}
#endif

/// Launch wiring for the tester build's cloud-voice consent (Echo's N2 on #395); nil and a no-op
/// in every other build, owner A/B builds included. -Nova
enum TesterCloudVoiceConsentHooks {
    /// The preparer's per-take consent check: the tester build only.
    static var preparerConsent: (@Sendable () -> Bool)? {
        #if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
        let store = TesterCloudVoice.consentStore
        return { store.isGranted }
        #else
        return nil
        #endif
    }

    /// Lets a decline reach this launch's preparer and renderer.
    @MainActor static func attach(preparer: DJBreakPreparer, renderer: VoiceRenderer) {
        #if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
        TesterCloudVoice.preparer = preparer
        TesterCloudVoice.renderer = renderer
        #endif
    }
}
