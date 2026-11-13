import Foundation

/// Build 10 P0 (-Atlas; window from Fry, call gate from Sentinel, MusicKit-state check from
/// Orion's P1). On the Duo, `.began` (`shouldResume=false`, reason 0) arrived 39 ms (a1) and
/// 131 ms (a2) after our own `play()` returned, and our handler then paused the start.
///
/// A `.began` is never dropped on timing alone. It is deferred, and MusicKit's own state decides:
/// - **Eligible to defer:** the current attempt is in flight (`play()` called, not yet settled),
///   `.began` lands before `play()` returns or within `windowAfterPlayReturn` of the return,
///   no call is ringing or connected, and no DJ break is active. Anything else applies at once.
/// - **Discarded** only when MusicKit then reaches `.playing` for that attempt
///   (`startConfirmed`). If the system really interrupted (Siri, an alarm, another app), it
///   stops MusicKit too, so `.playing` doesn't arrive.
/// - **Applied late, exactly as it would have been**, when the start fails, the 8 s report
///   fires (including MusicKit `.interrupted`), or a call appears (`flush`).
/// - A new user start drops it: an explicit tap clears system holds anyway (`userPlay`).
/// The `.ended` that pairs with a deferred `.began` follows it: queued while pending, applied
/// after the `.began` on flush, and ignored once after a discard.
public struct SelfStartInterruptionGate: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case apply
        /// Held until MusicKit's state or a call decides.
        case deferSelfStart
        /// The `.ended` paired with a discarded `.began`.
        case ignorePairedEnd
    }

    /// Measured from `play()` returning, not from calling it (`play()` took 831 ms on the Duo).
    public static let windowAfterPlayReturn: TimeInterval = 0.5

    private var attempt: PlaybackAttemptID?
    private var playCalledAt: TimeInterval?
    private var playReturnedAt: TimeInterval?
    private var pending: [AudioSessionNotice] = []
    private var ignoreNextEnded = false
    /// #444 (-Atlas): the attempt whose `play()` has been called and has neither returned nor
    /// thrown. Not cleared by a confirm or a failure report, only by the end of that `play()`
    /// or a newer start.
    private var awaitingPlay: PlaybackAttemptID?

    public init() {}

    public var hasDeferred: Bool { !pending.isEmpty }

    /// A new start. A still-deferred `.began` from an older start is dropped (the user's tap
    /// overrides system holds), and its `.ended` is ignored once.
    public mutating func startBegan(_ attempt: PlaybackAttemptID) {
        if !pending.isEmpty {
            ignoreNextEnded = !pending.contains { if case .interruptionEnded = $0 { true } else { false } }
            pending = []
        }
        self.attempt = attempt
        playCalledAt = nil
        playReturnedAt = nil
        awaitingPlay = nil
    }

    public mutating func playCalled(_ attempt: PlaybackAttemptID, at time: TimeInterval) {
        guard attempt == self.attempt else { return }
        playCalledAt = time
        awaitingPlay = attempt
    }

    public mutating func playReturned(_ attempt: PlaybackAttemptID, at time: TimeInterval) {
        if awaitingPlay == attempt { awaitingPlay = nil }
        guard attempt == self.attempt, playCalledAt != nil else { return }
        playReturnedAt = time
    }

    /// #444 (-Atlas): `play()` threw for `attempt`. It is no longer awaiting. The deferral window
    /// is unchanged (a throw is not a return).
    public mutating func playThrew(_ attempt: PlaybackAttemptID) {
        if awaitingPlay == attempt { awaitingPlay = nil }
    }

    /// #444 (-Atlas): `attempt` called `play()` and that call has not returned or thrown yet. A
    /// MusicKit cut seen now is the ambiguous cut of our own start, not the user's Next.
    public func isAwaitingPlay(_ attempt: PlaybackAttemptID?) -> Bool {
        guard let attempt else { return false }
        return awaitingPlay == attempt
    }

    /// MusicKit reached `.playing` for `attempt`. True when a deferred `.began` was discarded.
    @discardableResult
    public mutating func startConfirmed(_ attempt: PlaybackAttemptID) -> Bool {
        guard attempt == self.attempt else { return false }
        self.attempt = nil
        guard !pending.isEmpty else { return false }
        ignoreNextEnded = !pending.contains { if case .interruptionEnded = $0 { true } else { false } }
        pending = []
        return true
    }

    /// The start failed or was reported (8 s, `.interrupted`). Returns deferred notices to apply now.
    public mutating func startFailed(_ attempt: PlaybackAttemptID) -> [AudioSessionNotice] {
        guard attempt == self.attempt else { return [] }
        self.attempt = nil
        return flush()
    }

    /// A call appeared, or anything else that must apply the deferred notices now.
    public mutating func flush() -> [AudioSessionNotice] {
        defer { pending = [] }
        return pending
    }

    public mutating func decide(_ notice: AudioSessionNotice, at now: TimeInterval,
                                current: PlaybackAttemptID?, callActive: Bool,
                                breakActive: Bool) -> Decision {
        switch notice {
        case .interruptionBegan:
            guard pending.isEmpty, let attempt, attempt == current, let calledAt = playCalledAt,
                  now >= calledAt, !callActive, !breakActive else { return .apply }
            if let returnedAt = playReturnedAt, now - returnedAt > Self.windowAfterPlayReturn {
                return .apply
            }
            ignoreNextEnded = false
            pending = [notice]
            return .deferSelfStart
        case .interruptionEnded:
            if !pending.isEmpty {
                pending.append(notice)
                return .deferSelfStart
            }
            guard ignoreNextEnded else { return .apply }
            ignoreNextEnded = false
            return .ignorePairedEnd
        case .routeChanged:
            return .apply
        }
    }
}
