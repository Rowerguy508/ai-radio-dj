import Foundation
import Observation

// The "Are you 18 or older?" step for the Pro (cloud) voice (-Nova, stacked on Fry's #267).
// OnAirly is rated 13+; only the Pro voice is 18+. The step never gates anything else: a no,
// "Not now" or a dismissed sheet leaves every free feature as it is and keeps the on-device voice.
// Storage is Fry's `PaidVoiceAgeStore` (this-device-only Keychain item); this file only reads it
// and calls `record(isAdult:)` / `clear()`, then the session's `paidVoiceAccessChanged()`.

/// Fixed copy for the age step. Truthful about timing: a yes is used from the next break (a break
/// never switches voices part-way), a no applies right away. Never "next launch", never "instantly".
public enum PaidVoiceAgeStepCopy {
    public static let navigationTitle = "Pro voice"
    public static let title = "Are you 18 or older?"
    public static let detail =
        "The Pro DJ voice is for listeners 18 and older. Your answer stays on this device and isn't sent anywhere."
    public static let yes = "Yes, I'm 18 or older"
    public static let no = "No, I'm under 18"
    public static let notNow = "Not now"
    public static let done = "Done"
    public static let clear = "Clear my answer"
    /// Shown under the buttons whatever the answer: nothing else in the app depends on it.
    public static let footer =
        "Everything else in OnAirly works the same either way. Until you say yes, your DJ uses the on-device voice."

    /// The entry the listener uses to change the answer later.
    public static let entryTitle = "Pro voice age"

    public static func currentAnswer(_ answer: PaidVoiceAgeAnswer) -> String {
        switch answer {
        case .unanswered: return "Your answer: not answered"
        case .adult: return "Your answer: 18 or older"
        case .notAdult: return "Your answer: under 18"
        }
    }

    /// What happened after a write. `paidVoiceOtherwiseAllowed` is the Pro + consent gate without
    /// the age check, so a yes never promises the Pro voice to someone without Pro or consent.
    public static func confirmation(after answer: PaidVoiceAgeAnswer, paidVoiceOtherwiseAllowed: Bool) -> String {
        switch answer {
        case .adult:
            return paidVoiceOtherwiseAllowed
                ? "Thanks. Your DJ switches to the Pro voice from the next break."
                : "Saved. The Pro voice also needs an active Pro plan and your OK to use the cloud voice."
        case .notAdult:
            return "Saved. Your DJ uses the on-device voice from now on."
        case .unanswered:
            return "Answer cleared. Your DJ uses the on-device voice until you answer again."
        }
    }
}

/// The age step's state and actions. `@MainActor`, observed by the SwiftUI sheet and its entry.
///
/// - `accessWithoutAge` is the Pro + consent gate on its own (never wrapped in `requiringAdult`),
///   so the step can ask "would the Pro voice play if only the age were confirmed?".
/// - Every write goes to `PaidVoiceAgeStore` first, then `accessChanged` runs (the app passes
///   `DJBreakSession.paidVoiceAccessChanged()`), the same as after a consent change.
@MainActor @Observable
public final class PaidVoiceAgeStepModel {
    public private(set) var answer: PaidVoiceAgeAnswer
    /// Pro and consent allow the paid voice (age aside). Read by `refresh()`.
    public private(set) var paidVoiceOtherwiseAllowed = false
    /// "Not now" or a swiped-away sheet: not asked again until the next launch. Never stored.
    public private(set) var dismissedThisLaunch = false
    /// The result line after a write, until the sheet is opened again.
    public private(set) var confirmation: String?

    @ObservationIgnored private let store: PaidVoiceAgeStore
    @ObservationIgnored private let accessWithoutAge: ProVoiceAccess
    @ObservationIgnored private let accessChanged: @MainActor () async -> Void

    public init(store: PaidVoiceAgeStore, accessWithoutAge: ProVoiceAccess,
                accessChanged: @escaping @MainActor () async -> Void) {
        self.store = store
        self.accessWithoutAge = accessWithoutAge
        self.accessChanged = accessChanged
        self.answer = store.answer
    }

    /// Only an explicit `.allowed` counts. Every denial (no consent, not Pro, expired, unverified,
    /// revoked) means the step is not needed. The owner A/B trial is not age-gated (#267), so it
    /// does not ask either.
    public nonisolated static func otherwiseAllows(_ decision: ProVoiceGate.Decision) -> Bool {
        if case .allowed = decision { return true }
        return false
    }

    /// The step is offered only where the Pro voice needs it: Pro and consent allow the paid
    /// voice, and there is no answer yet.
    public nonisolated static func offersStep(paidVoiceOtherwiseAllowed: Bool, answer: PaidVoiceAgeAnswer) -> Bool {
        paidVoiceOtherwiseAllowed && answer == .unanswered
    }

    /// Present the sheet on its own: offered, and not put off this launch.
    public var offersStep: Bool {
        Self.offersStep(paidVoiceOtherwiseAllowed: paidVoiceOtherwiseAllowed, answer: answer) && !dismissedThisLaunch
    }

    /// The change-it-later entry: shown where the Pro voice applies, or once there is an answer
    /// to change or clear. Hidden otherwise, so free listeners never see an age question.
    public var showsChangeEntry: Bool { paidVoiceOtherwiseAllowed || answer != .unanswered }

    /// Re-reads the stored answer and the Pro + consent gate.
    public func refresh() async {
        answer = store.answer
        paidVoiceOtherwiseAllowed = Self.otherwiseAllows(await accessWithoutAge.decision())
    }

    /// Opening the sheet (on its own or from the entry) starts without an old result line.
    public func beginReview() { confirmation = nil }

    /// "Yes" (`true`) or "No" (`false`). A yes is used from the next break; a no applies at once.
    public func answer(isAdult: Bool) async {
        store.record(isAdult: isAdult)
        await afterWrite()
    }

    /// Withdraws the answer (back to unanswered: on-device voice). Not asked again this launch.
    public func clearAnswer() async {
        store.clear()
        dismissedThisLaunch = true
        await afterWrite()
    }

    /// "Not now" or a dismissed sheet: nothing is written and nothing else changes.
    public func dismiss() {
        if answer == .unanswered { dismissedThisLaunch = true }
    }

    private func afterWrite() async {
        answer = store.answer
        confirmation = PaidVoiceAgeStepCopy.confirmation(after: answer,
                                                         paidVoiceOtherwiseAllowed: paidVoiceOtherwiseAllowed)
        await accessChanged()
    }
}
