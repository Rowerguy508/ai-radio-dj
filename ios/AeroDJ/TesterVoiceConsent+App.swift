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
                    if accepted { TesterCloudVoice.consentStore.accept() } else { TesterCloudVoice.consentStore.decline() }
                    isPresented = false
                    if accepted, let tokens = TesterCloudVoice.tokens {
                        // Enrollment starts in the background; the first break never waits on it.
                        Task.detached(priority: .utility) { await tokens.prepare() }
                    }
                }
                .presentationDetents([.large])
            }
    }
}

/// #258's copy, minus `switchBack` ("…in Settings"): the Cloud voice toggle it points to ships
/// with #258, not in this build, so the line would promise a control testers can't find.
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
