import Foundation

/// The App Store (public) paid-voice route switch. OFF, at compile time, until per-install
/// attestation from #233 PRs 3–4 lands (Sentinel gate 2). It is a Swift compilation condition,
/// not a UserDefaults, Info.plist, Keychain or remote value, so nothing at runtime can turn it
/// on. No workflow or build setting sets `AERODJ_PUBLIC_PAID_ROUTE` today;
/// `check-release-disables-paid-voice.sh` and the ios.yml Release grep fail if its marker is in
/// a plain Release build, and find it only in a build that sets the flag (positive control).
public enum PublicPaidVoiceRoute {
    #if AERODJ_PUBLIC_PAID_ROUTE
    /// Found in the binary only when the flag is set (needle positive control).
    public static let buildMarker = "AERODJ_PUBLIC_PAID_ROUTE_BUILD"
    public static let compiledIn = !buildMarker.isEmpty
    #else
    public static let compiledIn = false
    #endif
}

/// Per-install proxy session (#233 PRs 3–4: App Attest + server-issued install session).
/// The only credential source the public route may use; never the owner token.
public protocol PaidVoiceInstallSessionProviding: Sendable {
    func installSessionCredentials() -> PremiumProxyCredentials?
}

/// Until #233 PRs 3–4: no install session, so the public route is omitted (`noCredentials`).
public struct NoInstallSession: PaidVoiceInstallSessionProviding {
    public init() {}
    public func installSessionCredentials() -> PremiumProxyCredentials? { nil }
}

/// The launch's voice: the renderer (with the ElevenLabs route when setup allowed it) and the
/// Pro + consent gate that `DJBreakPreparer` asks on every cue and again when a prepared break
/// is taken. They travel together so a paid route is never prepared without its gate.
/// Built once per launch through the existing `PremiumVoiceRoutes.compose`; no second renderer,
/// route builder or scheduler (-Echo).
public struct PaidVoice: Sendable {
    public let renderer: VoiceRenderer
    public let access: ProVoiceAccess
    public let decision: PremiumVoiceRoutes.Decision

    public init(renderer: VoiceRenderer, access: ProVoiceAccess, decision: PremiumVoiceRoutes.Decision) {
        self.renderer = renderer
        self.access = access
        self.decision = decision
    }

    /// Every build without the owner A/B flag. At setup the route needs only the compile-time
    /// switch (`PublicPaidVoiceRoute.compiledIn`) and a selected catalog voice. It is composed
    /// DEFERRED (`InstallSessionProxyVoiceProvider`): nothing is asked of the install session at
    /// setup. Age (18+), consent and Pro are decided per cue by `access` (in `DJBreakPreparer`,
    /// at take, for bundled clips, and again inside the provider), and only an allowed cue asks
    /// the session for credentials, on the pinned host, before the one proxy request.
    ///
    /// Age (18+, owner 2026-10-29): `age` has no default. The returned `access` checks it first
    /// (`requiringAdult`), so until a "yes" there is no session read and no proxy call. A "yes"
    /// followed by `paidVoiceAccessChanged()` takes effect at the next cue without a relaunch;
    /// a "no" or a cleared answer takes effect at once (prepared cloud breaks are dropped).
    /// `decision` reports `.ageNotConfirmed` when the age was not confirmed at setup (log only).
    public static func publicComposition(base: VoiceRenderer, access: ProVoiceAccess,
                                         age: any PaidVoiceAgeProviding, selectedVoiceID: String?,
                                         session: any PaidVoiceInstallSessionProviding) -> PaidVoice {
        publicComposition(base: base, access: access, age: age, selectedVoiceID: selectedVoiceID, session: session,
                          routeCompiledIn: PublicPaidVoiceRoute.compiledIn)
    }

    /// `routeCompiledIn` is injectable for `@testable` tests only; the public API takes no switch.
    static func publicComposition(base: VoiceRenderer, access: ProVoiceAccess, age: any PaidVoiceAgeProviding,
                                  selectedVoiceID: String?,
                                  session: any PaidVoiceInstallSessionProviding, routeCompiledIn: Bool,
                                  pinnedHosts: Set<String> = PremiumVoiceRoutes.allowedHosts,
                                  transport: any HTTPTransport = URLSessionTransport()) -> PaidVoice {
        let gate = access.requiringAdult(age)
        func voice(_ routes: [VoiceRoute], _ decision: PremiumVoiceRoutes.Decision) -> PaidVoice {
            PaidVoice(renderer: VoiceRenderer(routes: routes, budget: base.budget, cache: base.cache,
                                              revocations: base.revocations),
                      access: gate, decision: decision)
        }
        guard routeCompiledIn else { return voice(base.routes, .omitted(.paidDisabled)) }
        guard let selectedVoiceID else { return voice(base.routes, .omitted(.noSelection)) }
        guard let index = PremiumVoiceCatalog.index(ofVoiceID: selectedVoiceID) else {
            return voice(base.routes, .omitted(.unknownVoice))
        }
        let provider = InstallSessionProxyVoiceProvider(session: session, access: gate, pinnedHosts: pinnedHosts,
                                                        transport: transport)
        let route = PremiumVoiceRoutes.cloudRoute(PremiumVoiceCatalog.voices[index], provider: provider)
        let adult = age.paidVoiceAgeAnswer().isAdultConfirmed
        return voice([route] + base.routes, adult ? .included(catalogIndex: index) : .omitted(.ageNotConfirmed))
    }


    /// On-device only, with the fail-closed gate.
    public static func onDevice(_ base: VoiceRenderer) -> PaidVoice {
        PaidVoice(renderer: base, access: .none, decision: .omitted(.paidDisabled))
    }
}

/// The public route's provider, deferred (Nova, #267): it asks the gate (age, then consent, then
/// Pro) and only then the install session, on every cue that reaches it, so no session read
/// and no proxy request happen before an allowed cue. Credentials go through the same pinned-host
/// rule as `PremiumVoiceRoutes.compose` (`proxyConfiguration`). Any refusal throws, and the
/// renderer falls back to the on-device voice.
struct InstallSessionProxyVoiceProvider: VoiceProvider {
    enum Refusal: Error, Equatable { case notAllowed, noCredentials, emptyToken, endpointNotAllowed }

    let session: any PaidVoiceInstallSessionProviding
    let access: ProVoiceAccess
    let pinnedHosts: Set<String>
    let transport: any HTTPTransport

    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        // Belt and braces: the preparer already narrowed a denied cue to on-device routes.
        guard await access.decision().permitsPaidVoice else { throw Refusal.notAllowed }
        guard let credentials = session.installSessionCredentials() else { throw Refusal.noCredentials }
        let token = credentials.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Refusal.emptyToken }
        guard let configuration = PremiumVoiceRoutes.proxyConfiguration(endpoint: credentials.endpoint, token: token,
                                                                        pinnedHosts: pinnedHosts) else {
            throw Refusal.endpointNotAllowed
        }
        return try await ProxyVoiceProvider(configuration: configuration, transport: transport)
            .synthesize(text, voice: voice, context: context)
    }
}
