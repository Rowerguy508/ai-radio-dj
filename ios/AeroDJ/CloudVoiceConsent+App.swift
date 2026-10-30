import AeroDJCore
import SwiftUI

// Cloud-voice consent sheet (docs/privacy/disclosure-copy.md §1, #174). The gate itself is in
// AeroDJCore: `VoiceRenderer` reads `CloudVoiceConsentStore` before every cloud or paid route,
// so this file only asks and records. Swipe-down or backgrounding leaves the answer undecided,
// which is on-device only (fail-closed); music plays throughout. -Nova

/// Shared consent state for the sheet and the Tune toggle. Reads go to the store each time.
@MainActor @Observable
final class CloudVoiceConsentModel {
    static let shared = CloudVoiceConsentModel()

    private let store: CloudVoiceConsentStore
    /// Grant and revoke go through here, so the break session hears of each (E1).
    private let signals: PaidVoiceConsentSignals
    private(set) var state: CloudVoiceConsentState
    /// True only when this build can use a cloud voice and one is selected.
    private(set) var isCloudVoiceOffered: Bool
    var isSheetPresented = false
    /// The voice whose sheet was swiped away unanswered this launch: not asked again for it until
    /// the next launch or a different pick, so unrelated settings writes don't re-open the sheet.
    private var unansweredVoiceID: String?

    init(store: CloudVoiceConsentStore = CloudVoiceConsentStore(), signals: PaidVoiceConsentSignals? = nil) {
        self.store = store
        self.signals = signals ?? PaidVoiceConsentSignals(store: store)
        self.state = store.state
        self.isCloudVoiceOffered = false
        refresh()
    }

    /// Re-reads the stored answer and whether a cloud voice is offered; presents the sheet when a
    /// cloud voice is offered and the listener has not answered (before its first render).
    func refresh() {
        state = store.state
        let selected = PremiumVoiceSelectionStore().selectedVoiceID
        isCloudVoiceOffered = CloudVoiceConsentPrompt.isCloudVoiceOffered(
            paidProvidersEnabled: OwnerVoiceTrial.paidProvidersEnabled, selectedVoiceID: selected)
        if CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: isCloudVoiceOffered, state: state),
           selected != unansweredVoiceID, !isSheetPresented {
            isSheetPresented = true
        }
    }

    /// Sheet closed. Without an answer the state stays undecided: on-device only.
    func sheetDismissed() {
        state = store.state
        if state == .undecided { unansweredVoiceID = PremiumVoiceSelectionStore().selectedVoiceID }
    }

    func accept() {
        signals.accept()
        state = store.state
        isSheetPresented = false
        // Consent first, then (Free only) the Pro offer, once the consent sheet has closed.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            SubscriptionModel.shared.offerIfAllowed()
        }
    }

    func decline() {
        signals.decline()
        state = store.state
        isSheetPresented = false
    }

    /// The Tune toggle. On asks with the sheet (consent is only ever given there); off stops
    /// sending at once: the next render, including one already queued, uses the on-device voice.
    func setCloudVoice(_ on: Bool) {
        if on { isSheetPresented = true } else { decline() }
    }
}

extension View {
    /// Presents the cloud-voice consent sheet at the root when a cloud voice is offered and the
    /// listener has not answered. A no-op in builds without a cloud voice.
    func cloudVoiceConsentGate() -> some View { modifier(CloudVoiceConsentGate()) }
}

private struct CloudVoiceConsentGate: ViewModifier {
    @Bindable private var model = CloudVoiceConsentModel.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { model.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
            // The owner voice picker saves its selection to UserDefaults: ask right after a pick.
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)) { _ in model.refresh() }
            .sheet(isPresented: $model.isSheetPresented, onDismiss: model.sheetDismissed) {
                CloudVoiceConsentSheet(onAccept: model.accept, onDecline: model.decline)
            }
    }
}

struct CloudVoiceConsentSheet: View {
    let onAccept: () -> Void
    let onDecline: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "waveform.badge.globe")
                        .font(.largeTitle)
                        .foregroundStyle(AeroDJPalette.accentText)
                        .accessibilityHidden(true)
                    Text(CloudVoiceConsentCopy.title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("cloudVoiceConsent.title")
                    Text(CloudVoiceConsentCopy.intro)
                    labelled(CloudVoiceConsentCopy.sentHeading, CloudVoiceConsentCopy.sent)
                    labelled(CloudVoiceConsentCopy.neverSentHeading, CloudVoiceConsentCopy.neverSent)
                    labelled(CloudVoiceConsentCopy.storedHeading, CloudVoiceConsentCopy.stored)
                    Text(CloudVoiceConsentCopy.switchBack)
                        .foregroundStyle(AeroDJPalette.secondaryText)
                    policyLinks
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            buttons
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("cloudVoiceConsent.sheet")
        .transaction { if reduceMotion { $0.animation = nil } }
    }

    private func labelled(_ heading: String, _ body: String) -> some View {
        (Text(heading).bold() + Text(" ") + Text(body))
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var policyLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { links }
            VStack(alignment: .leading, spacing: 8) { links }
        }
        .font(.footnote)
    }

    @ViewBuilder private var links: some View {
        // Our own Privacy Policy is shown once the owner supplies its URL (copy doc [owner]).
        if let ours = CloudVoiceConsentCopy.privacyPolicyURL {
            Link(CloudVoiceConsentCopy.privacyPolicyLabel, destination: ours)
                .accessibilityIdentifier("cloudVoiceConsent.privacyPolicy")
        }
        Link(CloudVoiceConsentCopy.elevenLabsPolicyLabel, destination: CloudVoiceConsentCopy.elevenLabsPolicyURL)
            .accessibilityIdentifier("cloudVoiceConsent.elevenLabsPolicy")
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button(action: onAccept) {
                Text(CloudVoiceConsentCopy.accept)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .aeroGlass(Capsule(), role: .control, fallback: AnyShapeStyle(.tint.opacity(0.18)))
            .accessibilityHint("Sends the words of each DJ break to ElevenLabs to make audio.")
            .accessibilityIdentifier("cloudVoiceConsent.accept")

            Button(action: onDecline) {
                Text(CloudVoiceConsentCopy.decline)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .aeroGlass(Capsule(), role: .control, fallback: AnyShapeStyle(.thinMaterial))
            .accessibilityHint("The DJ keeps using the voice on your iPhone. Nothing is sent.")
            .accessibilityIdentifier("cloudVoiceConsent.decline")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Tune → DJ: the "Cloud voice" switch with the short footer. Shown only when a cloud voice is
/// offered. On is only reachable through the sheet; off takes effect for the next DJ line.
struct CloudVoiceToggleCard: View {
    @Bindable private var model = CloudVoiceConsentModel.shared

    var body: some View {
        if model.isCloudVoiceOffered {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(CloudVoiceConsentCopy.toggleTitle,
                       isOn: Binding(get: { model.state == .accepted },
                                     set: { model.setCloudVoice($0) }))
                    .accessibilityIdentifier("tune.cloudVoiceToggle")
                Text(CloudVoiceConsentCopy.footer)
                    .font(.caption).foregroundStyle(AeroDJPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .workspaceCardBackground(Color(.tertiarySystemFill).opacity(0.6))
            .onAppear { model.refresh() }
        }
    }
}
