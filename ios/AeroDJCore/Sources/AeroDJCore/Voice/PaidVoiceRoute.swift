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

    /// Every build without the owner A/B flag. The route needs, at setup: the compile-time
    /// switch (`PublicPaidVoiceRoute.compiledIn`), a selected catalog voice, and per-install
    /// session credentials on the pinned host. Pro + consent are NOT read here: the observer
    /// starts `.free` and consent is async, so they are enforced per cue by `DJBreakPreparer`
    /// with `access` (live render, render cache and bundled clips alike), and re-checked at take.
    ///
    /// Age (18+, owner 2026-10-29): `age` has no default. Unless it answers `.adult` at setup the
    /// route is left out (`.ageNotConfirmed`) and no session is asked, so nothing can reach the
    /// proxy this launch. The returned `access` also checks the age first on every cue and at take
    /// (`requiringAdult`), so a "no" or a cleared answer mid-show drops prepared cloud breaks
    /// through `paidVoiceAccessChanged()`. A new "yes" adds the route on the next launch.
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
        let adult = age.paidVoiceAgeAnswer().isAdultConfirmed
        // The session is not even asked while the route is compiled out or the age is not confirmed.
        let credentials = routeCompiledIn && adult ? session.installSessionCredentials() : nil
        let composition = PremiumVoiceRoutes.compose(onDevice: base.routes, paidProvidersEnabled: routeCompiledIn,
                                                     access: adult ? setupDeferredToPerCueGate : .denied(.ageNotConfirmed),
                                                     selectedVoiceID: selectedVoiceID,
                                                     credentials: credentials, pinnedHosts: pinnedHosts,
                                                     transport: transport)
        return PaidVoice(renderer: VoiceRenderer(routes: composition.routes, budget: base.budget, cache: base.cache,
                                                 revocations: base.revocations),
                         access: access.requiringAdult(age), decision: composition.decision)
    }

    /// Setup does not decide Pro + consent for the public route (see above); `access` does, per
    /// cue. Only `publicComposition` uses this, and it always returns `access` with the route.
    static let setupDeferredToPerCueGate: ProVoiceGate.Decision = .allowed

    /// On-device only, with the fail-closed gate.
    public static func onDevice(_ base: VoiceRenderer) -> PaidVoice {
        PaidVoice(renderer: base, access: .none, decision: .omitted(.paidDisabled))
    }
}
