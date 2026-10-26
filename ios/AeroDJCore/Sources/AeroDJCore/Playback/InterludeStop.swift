import Foundation

/// Why the speaking break was cut.
///
/// Consent and deletion call `InterludePlaybackAdapter.stopCurrentInterlude(reason:)`
/// with `.sourceRevoked`. The adapter stops that break's audio before the call returns.
public enum InterludeStopReason: Equatable, Sendable {
    /// A personal source this break was built from was deleted or its consent was revoked.
    case sourceRevoked
    /// A system interruption stopped the speaking break.
    case interruption
    /// The output route was removed while the break was speaking.
    case routeRemoved

    public var logToken: String {
        switch self {
        case .sourceRevoked: "sourceRevoked"
        case .interruption: "interruption"
        case .routeRemoved: "routeRemoved"
        }
    }
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

/// What a revoke does to a break that is already playing.
public struct ActiveBreakEffect: Equatable, Sendable {
    public var stopped: Bool
    public var end: NarrationEnd
    public var resumeMusic: Bool
    /// True when the stop is reported as the clip finishing on its own.
    public var naturalEnd: Bool

    public init(stopped: Bool, end: NarrationEnd, resumeMusic: Bool, naturalEnd: Bool) {
        self.stopped = stopped
        self.end = end
        self.resumeMusic = resumeMusic
        self.naturalEnd = naturalEnd
    }
}

public enum ActiveBreakStop {
    /// A playing clip is left running. `mayAutoResume` is not applied.
    public static func apply(isPlaying: Bool, reason: InterludeStopReason, mayAutoResume: Bool) -> ActiveBreakEffect {
        _ = (isPlaying, reason, mayAutoResume)
        return ActiveBreakEffect(stopped: false, end: .finished, resumeMusic: false, naturalEnd: true)
    }
}

/// Fake-friendly player. `stopActiveBreak` does not halt it yet.
@MainActor
public final class ActiveBreakController {
    private var stopState = InterludeStopState()
    private var player: ObjectIdentifier?
    public private(set) var playerStops = 0
    public private(set) var delegateCleared = false
    public private(set) var end: NarrationEnd?
    public private(set) var resumes = 0
    public private(set) var naturalEnds = 0
    public private(set) var delivered = 0

    public init() {}

    public func play() {
        stopState.begin()
        player = ObjectIdentifier(NSObject())
        if let player { stopState.adopt(player: player) }
    }

    public var currentPlayer: ObjectIdentifier? { player }

    public func stopActiveBreak(reason: InterludeStopReason, mayAutoResume: Bool) {
        let effect = ActiveBreakStop.apply(isPlaying: stopState.isPlaying, reason: reason, mayAutoResume: mayAutoResume)
        guard effect.stopped else { return }
        guard stopState.stop(reason: reason) else { return }
        player = nil
        playerStops += 1
        delegateCleared = true
        end = effect.end
        if effect.naturalEnd { naturalEnds += 1 }
        if effect.resumeMusic { resumes += 1 }
    }

    public func lateDelegate(from id: ObjectIdentifier) {
        guard stopState.acceptsDelegate(player: id) else { return }
        delivered += 1
        naturalEnds += 1
        end = .finished
        resumes += 1
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
