import Foundation

/// Build 10 P0 (-Atlas; window from Fry, call gate from Sentinel). On the Duo, `.began`
/// (`shouldResume=false`, reason 0) arrived 39 ms (a1) and 131 ms (a2) after our own `play()`
/// returned, and our handler then paused the start on purpose. This gate lets the app ignore
/// only that self-inflicted interruption:
/// - the current attempt is still in flight (begun, `play()` called, not confirmed or timed out),
/// - `.began` lands before `play()` returns or within `windowAfterPlayReturn` of the return,
/// - no call exists (CallKit: ringing or connected), and
/// - no DJ break is active.
/// Anything else, including any call-shaped interruption, is applied as before.
/// The `.ended` that pairs with an ignored `.began` is ignored too, so it cannot change the hold.
public struct SelfStartInterruptionGate: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case apply
        case ignoreSelfStart
    }

    /// Measured from `play()` returning, not from calling it (`play()` took 831 ms on the Duo).
    public static let windowAfterPlayReturn: TimeInterval = 0.5

    private var attempt: PlaybackAttemptID?
    private var playCalledAt: TimeInterval?
    private var playReturnedAt: TimeInterval?
    private var ignoredBeganPending = false

    public init() {}

    public mutating func startBegan(_ attempt: PlaybackAttemptID) {
        self.attempt = attempt
        playCalledAt = nil
        playReturnedAt = nil
    }

    public mutating func playCalled(_ attempt: PlaybackAttemptID, at time: TimeInterval) {
        guard attempt == self.attempt else { return }
        playCalledAt = time
    }

    public mutating func playReturned(_ attempt: PlaybackAttemptID, at time: TimeInterval) {
        guard attempt == self.attempt, playCalledAt != nil else { return }
        playReturnedAt = time
    }

    /// Confirmed `.playing`, the 8 s report, or a failed start. The window closes.
    public mutating func startSettled(_ attempt: PlaybackAttemptID) {
        guard attempt == self.attempt else { return }
        self.attempt = nil
    }

    public mutating func decide(_ notice: AudioSessionNotice, at now: TimeInterval,
                                current: PlaybackAttemptID?, callActive: Bool,
                                breakActive: Bool) -> Decision {
        switch notice {
        case .interruptionBegan:
            guard let attempt, attempt == current, let calledAt = playCalledAt, now >= calledAt,
                  !callActive, !breakActive else { return .apply }
            if let returnedAt = playReturnedAt, now - returnedAt > Self.windowAfterPlayReturn {
                return .apply
            }
            ignoredBeganPending = true
            return .ignoreSelfStart
        case .interruptionEnded:
            guard ignoredBeganPending else { return .apply }
            ignoredBeganPending = false
            return .ignoreSelfStart
        case .routeChanged:
            return .apply
        }
    }
}
