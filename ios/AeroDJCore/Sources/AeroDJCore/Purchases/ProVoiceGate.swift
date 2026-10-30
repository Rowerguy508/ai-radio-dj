import Foundation

/// What Nova's paywall / subscription store conforms to: the client-side Pro state.
/// Must report `.free` (or `.unverified`) whenever it does not know; never a cached `.pro`
/// past its expiry. `currentProEntitlement()` may be called on every DJ cue, so keep it cheap.
public protocol ProEntitlementProviding: Sendable {
    func currentProEntitlement() async -> ProEntitlementState
}

/// The listener's consent to send DJ lines to the paid voice service (the consent sheet).
/// Must answer false until the sheet was accepted, and false again as soon as it is withdrawn.
public protocol PaidVoiceConsentProviding: Sendable {
    func hasPaidVoiceConsent() async -> Bool
}

/// Fail-closed defaults until the paywall and the consent sheet are wired: free, no consent.
public struct NoProEntitlement: ProEntitlementProviding {
    public init() {}
    public func currentProEntitlement() async -> ProEntitlementState { .free }
}

public struct NoPaidVoiceConsent: PaidVoiceConsentProviding {
    public init() {}
    public func hasPaidVoiceConsent() async -> Bool { false }
}

/// The client-side gate for everything in the paid ElevenLabs voice: the proxy route at setup
/// and bundled pre-rendered clips per cue. Both need Pro AND consent; anything else is the
/// on-device voice. Client-side only: the proxy still verifies the transaction and decides.
public enum ProVoiceGate {
    public enum Denial: String, Equatable, Sendable {
        case noConsent, notPro, unverified, expired, revoked
    }

    public enum Decision: Equatable, Sendable {
        case allowed
        #if AERODJ_OWNER_AB
        /// The owner's A/B trial with the owner token. Compiled only into owner and TestFlight
        /// A/B builds (`AERODJ_OWNER_AB`), so an App Store Release build cannot produce it
        /// (Orion's ruling; OwnerTrialIsFlagOnlyTests). The proxy caps it separately, and it is
        /// removed before a public paid voice (Sentinel, #233).
        case ownerTrial
        #endif
        case denied(Denial)

        public var permitsPaidVoice: Bool {
            switch self {
            case .allowed: return true
            #if AERODJ_OWNER_AB
            case .ownerTrial: return true
            #endif
            case .denied: return false
            }
        }
    }

    /// The access the owner voice picker previews. Owner A/B builds: the owner trial. Every
    /// other build has no owner trial to preview, so it is a denial.
    public static var ownerPickerAccess: Decision {
        #if AERODJ_OWNER_AB
        return .ownerTrial
        #else
        return .denied(.notPro)
        #endif
    }

    /// Consent first: without it the answer is `.noConsent` whatever the subscription says,
    /// so the paywall can never stand in for, or skip, the consent sheet.
    ///
    /// `now` is the moment of the lookup: a `.pro` whose expiry has passed (or that has none) is
    /// `.expired` here, even if a provider hands back a stale cached `.pro` (Echo E1 / Sentinel
    /// N1, #244). Revocations reach the state through the provider's re-read
    /// (`ProEntitlementRecord` recomputes from the transactions' revocation dates at call time).
    public static func decide(entitlement: ProEntitlementState, paidVoiceConsent: Bool, now: Date) -> Decision {
        guard paidVoiceConsent else { return .denied(.noConsent) }
        switch entitlement {
        case .pro(_, let expiresAt):
            guard let expiresAt, expiresAt > now else { return .denied(.expired) }
            return .allowed
        case .free: return .denied(.notPro)
        case .unverified: return .denied(.unverified)
        case .expired: return .denied(.expired)
        case .revoked: return .denied(.revoked)
        }
    }
}

/// Asks both providers, at the moment of use. Used per cue for bundled clips, so withdrawing
/// consent or an expiry mid-show stops the next lookup.
public struct ProVoiceAccess: Sendable {
    private let decide: @Sendable () async -> ProVoiceGate.Decision

    public init(entitlement: any ProEntitlementProviding, consent: any PaidVoiceConsentProviding,
                now: @escaping @Sendable () -> Date = { Date() }) {
        decide = {
            // Consent is asked first and alone decides a denial; the entitlement is not even read.
            guard await consent.hasPaidVoiceConsent() else { return .denied(.noConsent) }
            let entitlement = await entitlement.currentProEntitlement()
            return ProVoiceGate.decide(entitlement: entitlement, paidVoiceConsent: true, now: now())
        }
    }

    private init(fixed: ProVoiceGate.Decision) { decide = { fixed } }

    /// Fail closed: free and no consent. What every build gets until the paywall and the
    /// consent sheet are wired.
    public static let none = ProVoiceAccess(entitlement: NoProEntitlement(), consent: NoPaidVoiceConsent())

    #if AERODJ_OWNER_AB
    /// Owner A/B trial. Exists only in `AERODJ_OWNER_AB` builds.
    public static let ownerTrial = ProVoiceAccess(fixed: .ownerTrial)
    #endif

    /// The gate the live app runs with. Owner A/B builds: the owner trial. Every other build,
    /// App Store Release included: `.none` (free, no consent), so nothing paid resolves until
    /// the paywall (Nova) and the consent sheet provide real conformers.
    public static var buildDefault: ProVoiceAccess {
        #if AERODJ_OWNER_AB
        return .ownerTrial
        #else
        return .none
        #endif
    }

    public func decision() async -> ProVoiceGate.Decision { await decide() }
}
