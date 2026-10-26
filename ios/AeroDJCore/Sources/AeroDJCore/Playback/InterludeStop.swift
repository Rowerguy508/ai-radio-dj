import Foundation

/// Why the speaking break was cut.
///
/// Consent and deletion call `InterludePlaybackAdapter.stopCurrentInterlude(reason:)`
/// with `.sourceRevoked`. The adapter stops that break's audio before the call returns.
public enum InterludeStopReason: Equatable, Sendable {
    /// A personal source this break was built from was deleted or its consent was revoked.
    case sourceRevoked
}

/// Which player, if any, may still deliver a finish callback.
///
/// Stopping retires the current player immediately. A delegate callback that arrives
/// afterwards, including one already queued, does not belong to this break.
public struct InterludeStopState: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var isPlaying = false
    public private(set) var reason: InterludeStopReason?
    private var player: ObjectIdentifier?

    public init() {}

    /// A break has started. The player id is adopted when a clip actually starts.
    public mutating func begin() {
        generation &+= 1
        isPlaying = true
        reason = nil
        player = nil
    }

    public mutating func adopt(player: ObjectIdentifier) {
        guard isPlaying else { return }
        self.player = player
    }

    /// Stops a playing break. An idle break is unchanged, and this returns false.
    @discardableResult
    public mutating func stop(reason: InterludeStopReason?) -> Bool {
        guard isPlaying else { return false }
        isPlaying = false
        self.reason = reason
        player = nil
        generation &+= 1
        return true
    }

    /// The break ended on its own. A later callback for its player is not delivered.
    public mutating func end() {
        isPlaying = false
        player = nil
    }

    public func acceptsDelegate(player: ObjectIdentifier) -> Bool {
        isPlaying && self.player == player
    }
}

/// Runs work on the main actor before the caller continues.
///
/// On the main thread the work runs in this turn. Off the main thread the caller
/// waits until the main queue has run it. No task is created, so a cancelled caller
/// cannot leave the stop running after this returns.
public enum MainActorImmediate {
    public static func run(_ body: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
            return
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }
}
