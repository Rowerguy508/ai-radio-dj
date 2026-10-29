import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One cloud voice the owner can pick in the A/B build. Only `id` is ever persisted.
public struct PremiumVoiceOption: Equatable, Sendable, Identifiable {
    /// The upstream voice ID (sent to the proxy as `voiceId`).
    public let id: String
    public let displayName: String
    public let description: String
    public let upstream: ProxyVoiceProvider.Upstream

    public init(id: String, displayName: String, description: String, upstream: ProxyVoiceProvider.Upstream) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.upstream = upstream
    }
}

/// The owner-approved lineup (2026-10-28): four ElevenLabs replacement voices.
///
/// IDs and descriptions are from ElevenLabs' public docs (replacement table),
/// https://elevenlabs.io/docs/help-center/product/voices/my-voices/what-are-default-voices
/// That page says the old Default voices expire 2026-12-31 and that these new voices
/// "you will be able to use forever"; it states no account-age limit for them.
/// The proxy's `AERODJ_TTS_VOICE_IDS` must list exactly `allowlistCSV`.
public enum PremiumVoiceCatalog {
    /// The one place the lineup is defined (keep `PremiumVoicePickerTests` in step, and
    /// update the proxy's AERODJ_TTS_VOICE_IDS to the new `allowlistCSV`).
    public static let voices: [PremiumVoiceOption] = [
        PremiumVoiceOption(id: "8dEUmyPMdDdK91vboYih", displayName: "Sawyer",
                           description: "Midnight Storyteller", upstream: .elevenlabs),
        PremiumVoiceOption(id: "ktkP7Nsj67dw2zcplQYt", displayName: "Lawrence",
                           description: "Bright and Informative", upstream: .elevenlabs),
        PremiumVoiceOption(id: "OZ0L6eISlOejga3XjDFt", displayName: "Talia",
                           description: "Warm Soft Guide", upstream: .elevenlabs),
        PremiumVoiceOption(id: "g7LVvkPWALzPxOQbF6OE", displayName: "Jade",
                           description: "Upbeat and Natural", upstream: .elevenlabs),
    ]

    /// The value for the proxy's `AERODJ_TTS_VOICE_IDS`.
    public static var allowlistCSV: String { voices.map(\.id).joined(separator: ",") }

    public static func index(ofVoiceID id: String) -> Int? { voices.firstIndex { $0.id == id } }
    public static func option(id: String) -> PremiumVoiceOption? { index(ofVoiceID: id).map { voices[$0] } }
}

/// Owner-only A/B gate for paid voices.
///
/// `BetaVoicePolicy.paidProvidersEnabled` stays `false` (the beta default). This gate is
/// compiled in only when the Swift condition `AERODJ_OWNER_AB` is set, which happens only
/// in a TestFlight archive dispatched with `owner_ab: true` (testflight.yml). Debug, Release
/// and every other build compile the `#else` branch (`check-release-disables-paid-voice.sh`).
/// Even with the flag, the ElevenLabs route needs a selected voice and a Keychain token.
///
/// Spend (owner, 2026-10-29): ElevenLabs Starter, hard 40k-credit ceiling with no usage-based
/// billing, a 9k-credit key cap and the proxy's 9,000-character daily cap. The app-side route
/// is priced at 0, so the app's VoiceBudget does not apply to it.
public enum OwnerVoiceTrial {
    #if AERODJ_OWNER_AB
    /// Found in the binary only when the flag is set (needle positive control).
    public static let buildMarker = "AERODJ_OWNER_AB_VOICE_TRIAL_BUILD"
    public static let paidProvidersEnabled = !buildMarker.isEmpty
    #else
    public static let paidProvidersEnabled = false
    #endif
}

/// Persists only the selected voice ID. Unknown IDs read back as `nil`.
public struct PremiumVoiceSelectionStore: @unchecked Sendable {
    public static let key = "AeroDJ.premiumVoice.selectedID"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var selectedVoiceID: String? {
        guard let id = defaults.string(forKey: Self.key), PremiumVoiceCatalog.option(id: id) != nil else { return nil }
        return id
    }

    /// `nil` clears the choice (on-device only). An ID outside the catalog is ignored.
    public func select(_ id: String?) {
        guard let id else { defaults.removeObject(forKey: Self.key); return }
        guard PremiumVoiceCatalog.option(id: id) != nil else { return }
        defaults.set(id, forKey: Self.key)
    }
}

/// Proxy endpoint and owner bearer token, read at runtime from debug-only storage
/// (Keychain in the app). Never compiled in.
public struct PremiumProxyCredentials: Sendable {
    public let endpoint: URL
    public let token: String
    public init(endpoint: URL, token: String) {
        self.endpoint = endpoint
        self.token = token
    }
}

/// Puts the selected ElevenLabs voice ahead of the existing on-device routes, through
/// the existing `ProxyVoiceProvider` and `VoiceRenderer` fallback chain. No new renderer.
public enum PremiumVoiceRoutes {
    public static let providerID = "elevenlabs"
    /// Above the proxy's own 15 s upstream abort, so its 504 arrives before we give up.
    public static let timeout: Duration = .seconds(16)
    /// Exact deployed proxy hosts only; no suffix or wildcard rule. The production
    /// `aerodj-tts` deployment; any other host (preview URLs included) omits the route.
    public static let allowedHosts: Set<String> = ["aerodj-tts.vercel.app"]

    public enum OmitReason: String, Equatable, Sendable {
        case paidDisabled, notEntitled, noSelection, unknownVoice, noCredentials, emptyToken, endpointNotAllowed
    }

    public enum Decision: Equatable, Sendable {
        /// Index into `PremiumVoiceCatalog.voices` (logged instead of a name).
        case included(catalogIndex: Int)
        case omitted(OmitReason)
    }

    public struct Composition: Sendable {
        public let routes: [VoiceRoute]
        public let decision: Decision
    }

    /// The proxy returns no timestamps, so ElevenLabs captions show the whole line.
    public static func hasWordTimings(providerID: String) -> Bool { false }

    /// Prefilled in the owner picker when the Keychain has no endpoint (still editable).
    public static let defaultEndpoint = "https://aerodj-tts.vercel.app/api/tts"

    public static func isAllowed(host: String, pinned: Set<String> = allowedHosts) -> Bool {
        pinned.contains(host.lowercased())
    }

    /// `[ElevenLabs(selected voice)] + onDevice` when every gate passes, else `onDevice` unchanged.
    /// `access` is the Pro + consent gate (`ProVoiceGate`); it has no default, so every caller
    /// states it, and a denial omits the route (fail closed).
    public static func compose(onDevice: [VoiceRoute], paidProvidersEnabled: Bool, access: ProVoiceGate.Decision,
                               selectedVoiceID: String?,
                               credentials: PremiumProxyCredentials?,
                               pinnedHosts: Set<String> = allowedHosts,
                               transport: any HTTPTransport = URLSessionTransport()) -> Composition {
        func omit(_ reason: OmitReason) -> Composition { Composition(routes: onDevice, decision: .omitted(reason)) }
        guard paidProvidersEnabled else { return omit(.paidDisabled) }
        guard access.permitsPaidVoice else { return omit(.notEntitled) }
        guard let selectedVoiceID else { return omit(.noSelection) }
        guard let index = PremiumVoiceCatalog.index(ofVoiceID: selectedVoiceID) else { return omit(.unknownVoice) }
        guard let credentials else { return omit(.noCredentials) }
        let token = credentials.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return omit(.emptyToken) }
        guard let configuration = proxyConfiguration(endpoint: credentials.endpoint, token: token,
                                                     pinnedHosts: pinnedHosts) else { return omit(.endpointNotAllowed) }
        let option = PremiumVoiceCatalog.voices[index]
        // App-side price is 0: spend is capped upstream (Starter's hard 40k credits, the key's
        // 9k cap) and by the proxy's daily character cap, so the app's $0 VoiceBudget does not block it.
        let route = VoiceRoute(providerID: providerID,
                               provider: ProxyVoiceProvider(configuration: configuration, transport: transport),
                               voice: VoiceProfile(id: option.id, name: option.displayName),
                               microdollarsPerThousandCharacters: 0, timeout: timeout, acceptsSSML: false,
                               leavesDevice: true)
        return Composition(routes: [route] + onDevice, decision: .included(catalogIndex: index))
    }

    /// The one endpoint rule `compose` applies: exact pinned host, then HTTPS and no userinfo
    /// (`ProxyVoiceProvider.Configuration`). `nil` means the route is omitted.
    static func proxyConfiguration(endpoint: URL, token: String,
                                   pinnedHosts: Set<String>) -> ProxyVoiceProvider.Configuration? {
        guard let host = endpoint.host?.lowercased(), isAllowed(host: host, pinned: pinnedHosts) else { return nil }
        return try? ProxyVoiceProvider.Configuration(endpoint: endpoint, allowedHosts: [host], upstream: .elevenlabs,
                                                     sessionToken: { token })
    }
}

/// Display-only helpers for the owner picker sheet. They mirror what Done saves
/// (trimmed endpoint, typed token replaces the saved one) and never read or return a token.
/// They only READ `PremiumVoiceRoutes.allowedHosts` (a `let`): the public API takes no host
/// list, so the app has no way to widen the pin. The `pinnedHosts:` overloads are internal,
/// for `@testable` tests only.
public enum PremiumVoicePickerStatus {
    /// The endpoint field's initial value: the saved endpoint, else `PremiumVoiceRoutes.defaultEndpoint`.
    public static func initialEndpoint(saved: String?) -> String {
        guard let saved, !saved.isEmpty else { return PremiumVoiceRoutes.defaultEndpoint }
        return saved
    }

    /// Whether `compose` would accept this endpoint (same rule, via `proxyConfiguration`).
    public static func isEndpointAllowed(_ endpoint: String) -> Bool {
        isEndpointAllowed(endpoint, pinnedHosts: PremiumVoiceRoutes.allowedHosts)
    }

    static func isEndpointAllowed(_ endpoint: String, pinnedHosts: Set<String>) -> Bool {
        guard let url = savedURL(endpoint) else { return false }
        return PremiumVoiceRoutes.proxyConfiguration(endpoint: url, token: "", pinnedHosts: pinnedHosts) != nil
    }

    public static func endpointFooter(_ endpoint: String) -> String {
        endpointFooter(endpoint, pinnedHosts: PremiumVoiceRoutes.allowedHosts)
    }

    static func endpointFooter(_ endpoint: String, pinnedHosts: Set<String>) -> String {
        isEndpointAllowed(endpoint, pinnedHosts: pinnedHosts)
            ? "Host allowed" : "Not the pinned host: route will be omitted"
    }

    /// The decision `compose` would make on next launch if Done saved these settings.
    /// `hasSavedToken` stands in for the Keychain token, whose value is never needed here.
    public static func pendingDecision(paidProvidersEnabled: Bool, selectedVoiceID: String?, endpoint: String,
                                       enteredToken: String, hasSavedToken: Bool) -> PremiumVoiceRoutes.Decision {
        pendingDecision(paidProvidersEnabled: paidProvidersEnabled, selectedVoiceID: selectedVoiceID, endpoint: endpoint,
                        enteredToken: enteredToken, hasSavedToken: hasSavedToken,
                        pinnedHosts: PremiumVoiceRoutes.allowedHosts, access: ProVoiceGate.ownerPickerAccess)
    }

    static func pendingDecision(paidProvidersEnabled: Bool, selectedVoiceID: String?, endpoint: String,
                                enteredToken: String, hasSavedToken: Bool,
                                pinnedHosts: Set<String>, access: ProVoiceGate.Decision) -> PremiumVoiceRoutes.Decision {
        let entered = enteredToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // Done: an empty field keeps the saved token; a typed one replaces it (blank deletes it).
        let hasToken = enteredToken.isEmpty ? hasSavedToken : !entered.isEmpty
        let credentials = savedURL(endpoint).flatMap { url in
            hasToken ? PremiumProxyCredentials(endpoint: url, token: entered.isEmpty ? "saved" : entered) : nil
        }
        return PremiumVoiceRoutes.compose(onDevice: [], paidProvidersEnabled: paidProvidersEnabled,
                                          access: access, selectedVoiceID: selectedVoiceID, credentials: credentials,
                                          pinnedHosts: pinnedHosts).decision
    }

    /// Type, code and catalog index only.
    public static func statusLine(_ decision: PremiumVoiceRoutes.Decision) -> String {
        switch decision {
        case .included(let index): return "Premium: included (catalog index \(index))"
        case .omitted(let reason): return "Premium: omitted (\(reason.rawValue))"
        }
    }

    /// The URL the Keychain would hold after Done (trimmed; empty means none).
    private static func savedURL(_ endpoint: String) -> URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }
}
