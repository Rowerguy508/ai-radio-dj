import Foundation

/// The listener's answer to "Are you 18 or older?", asked before the cloud-voice consent sheet
/// (Orion + owner, 2026-10-29: Pro voice is 18+, the app stays 12+). There is no default answer:
/// `.unanswered` is not a yes, so it keeps the listener on the on-device voice.
public enum PaidVoiceAgeAnswer: String, Equatable, Sendable, CaseIterable {
    case unanswered, adult, notAdult

    /// Only an explicit yes confirms the age.
    public var isAdultConfirmed: Bool { self == .adult }
}

/// Where the age answer comes from. Must answer `.unanswered` until the listener answered, and
/// reflect a change (or a cleared answer) on the next read. Synchronous and on-device only.
public protocol PaidVoiceAgeProviding: Sendable {
    func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer
}

/// Fail-closed default: never answered.
public struct NoPaidVoiceAgeAnswer: PaidVoiceAgeProviding {
    public init() {}
    public func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer { .unanswered }
}

/// The on-device store for the age answer: one UserDefaults key, never sent anywhere.
/// This is the read/write API for the "Are you 18 or older?" step (Nova builds the UI).
/// After `record(isAdult:)` or `clear()`, the caller calls `DJBreakSession.paidVoiceAccessChanged()`
/// exactly as it does after a consent change, so a prepared cloud-voice break is dropped.
public struct PaidVoiceAgeStore: PaidVoiceAgeProviding, @unchecked Sendable {
    public static let key = "AeroDJ.paidVoice.ageAnswer"
    private static let yes = "yes", no = "no"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The stored answer. Missing or unrecognised values read as `.unanswered`.
    public var answer: PaidVoiceAgeAnswer {
        switch defaults.string(forKey: Self.key) {
        case Self.yes?: return .adult
        case Self.no?: return .notAdult
        default: return .unanswered
        }
    }

    public var isAdultConfirmed: Bool { answer.isAdultConfirmed }

    public func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer { answer }

    /// The listener's explicit answer: `true` for "yes, 18 or older", `false` for "no".
    public func record(isAdult: Bool) { defaults.set(isAdult ? Self.yes : Self.no, forKey: Self.key) }

    /// Withdraws the answer (back to `.unanswered`, which is not confirmed).
    public func clear() { defaults.removeObject(forKey: Self.key) }
}

extension ProVoiceAccess {
    /// This gate with the age check in front of it: unless `age` answers `.adult` at the moment
    /// of the lookup, the decision is `.denied(.ageNotConfirmed)` and the inner gate (consent,
    /// then Pro) is not even asked. `PaidVoice.publicComposition` applies it to the access it
    /// returns, so the per-cue check, the take re-check and bundled clips all see the age.
    public func requiringAdult(_ age: any PaidVoiceAgeProviding) -> ProVoiceAccess {
        let inner = self
        return ProVoiceAccess(deciding: {
            guard age.paidVoiceAgeAnswer().isAdultConfirmed else { return .denied(.ageNotConfirmed) }
            return await inner.decision()
        })
    }
}
