import AeroDJCore
import Foundation
import SwiftUI
#if AERODJ_OWNER_AB
import Security
#endif

/// Owner-only ElevenLabs A/B wiring. Compiled only with the Swift condition
/// `AERODJ_OWNER_AB` (TestFlight `owner_ab: true`). Owner-only here: the owner token
/// (`OwnerProxyKeychain`), the `.ownerTrial` access, the voice picker and the A/B switch.
/// The paid-voice route and its per-cue Pro + consent gate are build-agnostic
/// (`PaidVoice+App.swift`, `PaidVoice` in AeroDJCore); every other build gets the public
/// composition there and `ownerVoiceTrialEntry()` returns the view unchanged (-Echo).
///
/// The proxy URL and owner token come only from a Keychain entry the owner fills in at
/// runtime; nothing is compiled in or stored in the repo, Info.plist or build settings.
/// Spend: ElevenLabs Starter, hard 40k-credit ceiling with no usage-based billing, a 9k-credit
/// key cap and the proxy's 9,000-character daily cap. The route is priced at 0 µ$, so the
/// app-side VoiceBudget does not apply to it.
#if AERODJ_OWNER_AB
extension PaidVoice {
    /// The owner A/B composition: owner token from the Keychain, the owner trial decision at
    /// setup, and `ProVoiceAccess.live` (the owner trial in this build) as the per-cue gate.
    static func ownerTrial(base: VoiceRenderer) -> PaidVoice {
        let composition = PremiumVoiceRoutes.compose(
            onDevice: base.routes,
            paidProvidersEnabled: OwnerVoiceTrial.paidProvidersEnabled,
            access: .ownerTrial, selectedVoiceID: PremiumVoiceSelectionStore().selectedVoiceID,
            credentials: OwnerProxyKeychain.load())
        // Every render still checks the stored cloud-voice consent first (Nova #cloud-voice-consent);
        // the compose decision is logged once by PaidVoice.live() (PaidVoiceLog).
        return PaidVoice(renderer: VoiceRenderer(routes: composition.routes, budget: base.budget, cache: base.cache,
                                                 revocations: base.revocations, cloudConsent: CloudVoiceConsentStore()),
                         access: .live, decision: composition.decision)
    }
}
#endif

extension ProVoiceAccess {
    /// The Pro + consent gate the live app runs with. Owner A/B builds: the owner trial, matching
    /// the route above. Every other build: the paywall's verified client Pro state and the consent
    /// sheet's store, so a paid voice needs Pro AND consent (both fail closed).
    static var live: ProVoiceAccess {
        #if AERODJ_OWNER_AB
        return .ownerTrial
        #else
        // The paywall's client Pro state (written by SubscriptionModel from verified App Store
        // transactions, Free until then) and the consent sheet's store, asked per use.
        return ProVoiceAccess(entitlement: ProEntitlementCache.shared, consent: CloudVoiceConsentStore())
        #endif
    }
}

extension View {
    /// Adds the owner voice picker entry in an `AERODJ_OWNER_AB` build; a no-op otherwise.
    @ViewBuilder func ownerVoiceTrialEntry() -> some View {
        #if AERODJ_OWNER_AB
        modifier(OwnerVoiceTrialEntry())
        #else
        self
        #endif
    }
}

#if AERODJ_OWNER_AB
/// Keychain entry (this device only, when unlocked) for the proxy endpoint and owner token.
enum OwnerProxyKeychain {
    private static let service = OwnerProxyAuth.keychainService

    static func load() -> PremiumProxyCredentials? {
        guard let endpoint = read("endpoint").flatMap(URL.init(string:)), let token = read("token") else { return nil }
        return PremiumProxyCredentials(endpoint: endpoint, token: token)
    }

    static var hasToken: Bool { read("token")?.isEmpty == false }
    static var endpoint: String { read("endpoint") ?? "" }

    static func save(endpoint: String, token: String?) {
        write("endpoint", endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        if let token { write("token", token.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func clear() {
        for account in ["endpoint", "token"] { SecItemDelete(query(account) as CFDictionary) }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

private struct OwnerVoiceTrialEntry: ViewModifier {
    @State private var showPicker = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                Button("Owner voice test") { showPicker = true }
                    .font(.footnote)
                    .padding(8)
                    .accessibilityIdentifier("ownerVoiceTrial.open")
            }
            .sheet(isPresented: $showPicker) { OwnerVoicePickerSheet(isPresented: $showPicker) }
    }
}

/// The owner's voice picker. Persists only the selected voice ID; the token goes to the Keychain.
private struct OwnerVoicePickerSheet: View {
    @Binding var isPresented: Bool
    @State private var selected: String = PremiumVoiceSelectionStore().selectedVoiceID ?? ""
    @State private var endpoint: String = PremiumVoicePickerStatus.initialEndpoint(saved: OwnerProxyKeychain.endpoint)
    @State private var token: String = ""
    private let store = PremiumVoiceSelectionStore()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("DJ voice", selection: $selected) {
                        Text("On-device only").tag("")
                        ForEach(PremiumVoiceCatalog.voices) { voice in
                            VStack(alignment: .leading) {
                                Text(voice.displayName)
                                Text(voice.description).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(voice.id)
                        }
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("ElevenLabs first, on-device voice as fallback. Captions show whole lines. Applies on next launch.")
                }
                Section {
                    TextField("Proxy URL (exact pinned host)", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField(OwnerProxyKeychain.hasToken ? "Token saved (enter to replace)" : "Owner token",
                                text: $token)
                    Button("Clear proxy settings", role: .destructive) {
                        OwnerProxyKeychain.clear()
                        endpoint = ""
                        token = ""
                    }
                } header: {
                    Text("Proxy (owner only)")
                } footer: {
                    Text(PremiumVoicePickerStatus.endpointFooter(endpoint))
                        .accessibilityIdentifier("ownerVoiceTrial.hostCheck")
                }
                Section {
                    // Read-only: catalog index or omit reason code, never the token.
                    Text(PremiumVoicePickerStatus.statusLine(PremiumVoicePickerStatus.pendingDecision(
                        paidProvidersEnabled: OwnerVoiceTrial.paidProvidersEnabled,
                        selectedVoiceID: selected.isEmpty ? nil : selected, endpoint: endpoint,
                        enteredToken: token, hasSavedToken: OwnerProxyKeychain.hasToken)))
                        .font(.footnote.monospaced())
                        .accessibilityIdentifier("ownerVoiceTrial.status")
                }
            }
            .navigationTitle("Owner voice test")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.select(selected.isEmpty ? nil : selected)
                        OwnerProxyKeychain.save(endpoint: endpoint, token: token.isEmpty ? nil : token)
                        token = ""
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}
#endif
