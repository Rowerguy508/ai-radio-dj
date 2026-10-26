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
    public private(set) var onBreakMustStop: (@MainActor (InterludeStopReason, Int?) -> Void)?

    public init() {}

    /// A clip may start only after `arm`. That is the same moment the stop hook is stored.
    public var canPlay: Bool { onBreakMustStop != nil }

    public func arm(_ stop: @escaping @MainActor (InterludeStopReason, Int?) -> Void) {
        onBreakMustStop = stop
    }
}

/// Whether a play that has not started a clip player may start one.
///
/// The adapter guarantees this for every `stopCurrentInterlude(.sourceRevoked)` that
/// reaches it while a play is pending, before the clip player is set:
/// - while idle, with nothing handed out, the stop is ignored. The next break is unrelated;
/// - after `handOut` and before `begin`, a nil tag or a tag for that `afterTrack` cancels
///   that break. A tag for a different `afterTrack` is ignored and not stored. `handOut`
///   and a `begin` that starts audio clear any held stop, so it cannot cancel a later break.
///   The natural-end boundary calls `handOut` before it awaits break preparation. A stop
///   during that await is held. `abandonHandOut` drops the hand-out when nothing will be
///   spoken, including a stop held for it, and does not resume music;
/// - after `begin` and before `admit` (decode, or stop state begun with no clip player),
///   a nil tag or a matching tag makes `admit` cancel that play. A different tag does not.
/// A nil tag is the untagged stop `skip()` sends. It fails closed for a handed-out, pending,
/// or playing break. No clip starts. Music resumes once, from `begin` or `admit`, when
/// auto-resume is allowed. `stop` itself does not resume, so the play and the stop do not
/// resume twice.
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
        case handedOut
        case pending
    }

    /// A stop scoped to every current break, or to one `afterTrack`.
    private enum HeldStop: Equatable, Sendable {
        case any
        case track(Int)
    }

    private var phase: Phase = .idle
    private var track: Int?
    private var heldStop: HeldStop?
    private var revoked = false

    public init() {}

    /// The break for `afterTrack` has been handed out and has not called `begin` yet.
    /// A new hand-out drops any stop held for the previous break, so the natural-end
    /// boundary must hand out once, before any await, and must not hand out again.
    public mutating func handOut(afterTrack: Int) {
        guard phase != .pending else { return }
        phase = .handedOut
        track = afterTrack
        heldStop = nil
    }

    /// Nothing will be spoken for the hand-out (nothing prepared, or music continues).
    /// Drops the hand-out and any stop held for it, so that stop cannot cancel a later
    /// break. A pending play is left for `admit`. This does not start or resume audio.
    public mutating func abandonHandOut() {
        guard phase == .handedOut else { return }
        phase = .idle
        track = nil
        heldStop = nil
    }

    /// Records a revoke for the handed-out or pending play.
    ///
    /// `afterTrack == nil` is untagged and fails closed: it cancels whatever was handed
    /// out or is pending. A tag cancels only the break with that index. A tag for a
    /// different handed-out break is ignored and not stored. An idle revoke, with nothing
    /// handed out, is ignored, so the next unrelated break still starts. Resume is decided
    /// by the following `begin` or `admit`, once.
    public mutating func stop(reason: InterludeStopReason, afterTrack: Int? = nil, mayAutoResume: Bool) -> PendingPlayEffect {
        _ = reason
        _ = mayAutoResume
        switch phase {
        case .idle:
            return PendingPlayEffect(startAudio: false, resumeMusic: false)
        case .handedOut:
            if let afterTrack, afterTrack != track {
                return PendingPlayEffect(startAudio: false, resumeMusic: false)
            }
            heldStop = afterTrack.map(HeldStop.track) ?? .any
            return PendingPlayEffect(startAudio: false, resumeMusic: false)
        case .pending:
            if let afterTrack, afterTrack != track {
                return PendingPlayEffect(startAudio: false, resumeMusic: false)
            }
            revoked = true
            return PendingPlayEffect(startAudio: false, resumeMusic: false)
        }
    }

    /// Opens the pending play, before decode.
    ///
    /// A nil-tagged or matching stop recorded after `handOut` cancels this break.
    /// A stop tagged for a different `afterTrack` does not. A begin that starts audio
    /// clears any held stop.
    public mutating func begin(afterTrack: Int? = nil, mayAutoResume: Bool) -> PendingPlayEffect {
        if let afterTrack { track = afterTrack }
        if revoked || stopAppliesToBegin() {
            heldStop = nil
            revoked = false
            phase = .idle
            return PendingPlayEffect(startAudio: false, resumeMusic: mayResume(mayAutoResume))
        }
        heldStop = nil
        phase = .pending
        return PendingPlayEffect(startAudio: true, resumeMusic: false)
    }

    private func stopAppliesToBegin() -> Bool {
        switch heldStop {
        case .any:
            return phase == .handedOut
        case .track(let tagged):
            return track == tagged
        case nil:
            return false
        }
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

/// How a stop held across `naturalBoundary` is reported when `begin` cancels the break.
///
/// The adapter emits `.revoked`. The session records `playbackFinished`, so DJ state
/// leaves `.ready` without a voice failure. `resumeMusic` is the same `.revoked` policy
/// `PendingPlayStop.begin` uses.
public struct HeldBoundaryStopCancellation: Equatable, Sendable {
    public var event: DJPresentationEvent
    public var resumeMusic: Bool

    public init(event: DJPresentationEvent, resumeMusic: Bool) {
        self.event = event
        self.resumeMusic = resumeMusic
    }
}

public enum HeldBoundaryStopReport {
    public static func cancellation(afterTrack: Int, mayAutoResume: Bool) -> HeldBoundaryStopCancellation {
        HeldBoundaryStopCancellation(
            event: .playbackFinished(afterTrack: afterTrack),
            resumeMusic: NarrationResumePolicy.decide(.revoked, mayAutoResume: mayAutoResume, phase: .music).resumeMusic
        )
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

/// Where `stopCurrentInterlude` applies a stop that is not an untagged `stop()`.
///
/// Idle, handed-out, and pending are not playing. An interruption or a route removal
/// cancels that break the same way a revoke does, so it cannot start on the speaker
/// at the boundary. A nil tag fails closed. A tag for a different playing break is ignored.
public enum InterludeBoundaryStop: Equatable, Sendable {
    case ignore
    case cancelPending(afterTrack: Int?)
    case stopPlaying

    public static func action(
        reason: InterludeStopReason,
        afterTrack: Int?,
        isPlaying: Bool,
        playingTrack: Int
    ) -> InterludeBoundaryStop {
        switch reason {
        case .sourceRevoked, .interruption, .routeRemoved:
            if isPlaying {
                if let afterTrack, afterTrack != playingTrack { return .ignore }
                return .stopPlaying
            }
            return .cancelPending(afterTrack: afterTrack)
        }
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
