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

/// Installs the speech-stop hook before a clip is allowed to play.
///
/// `canPlay` is true only while `onBreakMustStop` is non-nil. A purge can run
/// when the player screen is not mounted, so the hook is armed where the DJ
/// session and the interlude player are created, not when a view appears.
@MainActor
public final class SpeechStopGate {
    public private(set) var onBreakMustStop: (@MainActor (InterludeStopReason) -> Void)?

    public init() {}

    /// A clip may start only after `arm`. That is the same moment the stop hook is stored.
    public var canPlay: Bool { onBreakMustStop != nil }

    public func arm(_ stop: @escaping @MainActor (InterludeStopReason) -> Void) {
        onBreakMustStop = stop
    }
}

/// Whether a play that has not started a clip player may start one.
///
/// The adapter guarantees this for every `stopCurrentInterlude(.sourceRevoked)` that
/// reaches it, including one that arrives before the clip player is set:
/// - before `begin`, the stop is kept and the next `begin` cancels that play;
/// - after `begin` and before `admit` (decode, or stop state begun with no clip player),
///   `admit` cancels that play.
/// No clip starts. Music resumes once, from `begin` or `admit`, when auto-resume is allowed.
/// `stop` itself does not resume, so the play and the stop do not resume twice.
///
/// A stop that never reaches the adapter, because the session hook was still nil, is not
/// visible here. Production arms that hook before a clip can play. The order in which
/// purge clears the on-air marker belongs to Fry.
public struct PendingPlayEffect: Equatable, Sendable {
    public var startAudio: Bool
    public var resumeMusic: Bool

    public init(startAudio: Bool, resumeMusic: Bool) {
        self.startAudio = startAudio
        self.resumeMusic = resumeMusic
    }
}

public struct PendingPlayStop: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case idle
        case pending
    }

    private var phase: Phase = .idle
    private var revoked = false

    public init() {}

    /// Records a revoke. Resume is decided by the following `begin` or `admit`, once.
    public mutating func stop(reason: InterludeStopReason, mayAutoResume: Bool) -> PendingPlayEffect {
        _ = reason
        _ = mayAutoResume
        revoked = true
        return PendingPlayEffect(startAudio: false, resumeMusic: false)
    }

    /// Opens the pending play, before decode. An earlier revoke cancels it.
    public mutating func begin(mayAutoResume: Bool) -> PendingPlayEffect {
        if revoked {
            revoked = false
            phase = .idle
            return PendingPlayEffect(startAudio: false, resumeMusic: mayResume(mayAutoResume))
        }
        phase = .pending
        return PendingPlayEffect(startAudio: true, resumeMusic: false)
    }

    /// After decode, before a clip player is created. A revoke while pending refuses audio.
    public mutating func admit(mayAutoResume: Bool) -> PendingPlayEffect {
        let stillPending = phase == .pending
        phase = .idle
        if revoked || !stillPending {
            let resume = revoked && mayResume(mayAutoResume)
            revoked = false
            return PendingPlayEffect(startAudio: false, resumeMusic: resume)
        }
        return PendingPlayEffect(startAudio: true, resumeMusic: false)
    }

    private func mayResume(_ mayAutoResume: Bool) -> Bool {
        NarrationResumePolicy.decide(.revoked, mayAutoResume: mayAutoResume, phase: .music).resumeMusic
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
    /// Halt a playing clip, record a revoke, and resume music once when that is still allowed.
    /// An idle break is unchanged. The result is never a natural end.
    public static func apply(isPlaying: Bool, reason: InterludeStopReason, mayAutoResume: Bool) -> ActiveBreakEffect {
        guard isPlaying else {
            return ActiveBreakEffect(stopped: false, end: .skipped, resumeMusic: false, naturalEnd: false)
        }
        _ = reason
        let decision = NarrationResumePolicy.decide(.revoked, mayAutoResume: mayAutoResume, phase: .voice)
        return ActiveBreakEffect(
            stopped: true,
            end: .revoked,
            resumeMusic: decision.resumeMusic,
            naturalEnd: false
        )
    }
}

/// Fake-friendly player. `stopActiveBreak` does not halt it yet.
@MainActor
public final class ActiveBreakController {
    private var stopState = InterludeStopState()
    /// Retained so a later clip cannot reuse this object's address.
    private var token: NSObject?
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
        let object = NSObject()
        token = object
        let id = ObjectIdentifier(object)
        player = id
        stopState.adopt(player: id)
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
