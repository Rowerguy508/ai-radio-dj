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
        /// The owner's A/B trial with the owner token (`AERODJ_OWNER_AB` builds only). The
        /// proxy caps it separately, and it is removed before a public paid voice (Sentinel, #233).
        case ownerTrial
        case denied(Denial)

        public var permitsPaidVoice: Bool {
            switch self {
            case .allowed, .ownerTrial: return true
            case .denied: return false
            }
        }
    }

    /// Consent first: without it the answer is `.noConsent` whatever the subscription says,
    /// so the paywall can never stand in for, or skip, the consent sheet.
    public static func decide(entitlement: ProEntitlementState, paidVoiceConsent: Bool) -> Decision {
        guard paidVoiceConsent else { return .denied(.noConsent) }
        switch entitlement {
        case .pro: return .allowed
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

    public init(entitlement: any ProEntitlementProviding, consent: any PaidVoiceConsentProviding) {
        decide = {
            // Consent is asked first and alone decides a denial; the entitlement is not even read.
            guard await consent.hasPaidVoiceConsent() else { return .denied(.noConsent) }
            return ProVoiceGate.decide(entitlement: await entitlement.currentProEntitlement(), paidVoiceConsent: true)
        }
    }

    private init(fixed: ProVoiceGate.Decision) { decide = { fixed } }

    /// Fail closed: free and no consent. What every build gets until the paywall and the
    /// consent sheet are wired.
    public static let none = ProVoiceAccess(entitlement: NoProEntitlement(), consent: NoPaidVoiceConsent())

    /// Owner A/B trial only. Use it solely from `#if AERODJ_OWNER_AB` code (OwnerVoiceTrial+App).
    public static let ownerTrial = ProVoiceAccess(fixed: .ownerTrial)

    public func decision() async -> ProVoiceGate.Decision { await decide() }
}
