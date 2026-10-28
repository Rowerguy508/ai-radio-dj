// TEMPORARY P0 Experiment B, "S" toggle (remove with #121 / #133). -Fry
// Compiled only in Debug (so `swift test` runs its tests) and in AERODJ_P0_DIAG builds.
//
// S reproduces build 14's session path inside Direct Mode, using the real Core policy types:
// `.playback` category, `setActive(true)` right before `play()`, `PlaybackStartGuard` after
// `play()`, `AudioSessionPolicy` on interruption and route-change notices, and the poll's
// `RemotePlayGate`. Off (the default) it records nothing and asks for nothing.
// The trace is sanitized: t, an event enum and booleans only.
#if DEBUG || AERODJ_P0_DIAG

public struct DirectModeSessionTraceEntry: Equatable, Sendable, CustomStringConvertible {
    public enum Event: Equatable, Sendable {
        case enabled
        case setCategory(ok: Bool)
        case setActive(ok: Bool)
        case guardAfterPlay(keepPlaying: Bool)
        case notice(DirectModeSessionNoticeKind, AudioSessionDirective)
        case remoteGatePause
        case userPause
    }

    public let t: Double
    public let event: Event

    public var description: String {
        let head = String(format: "%7.2f S ", t)
        switch event {
        case .enabled: return head + "session.layer=on"
        case .setCategory(let ok): return head + "setCategory.playback ok=\(ok)"
        case .setActive(let ok): return head + "setActive.true ok=\(ok)"
        case .guardAfterPlay(let keep): return head + "guard.afterPlay " + (keep ? "keepPlaying" : "pauseBecauseHeld")
        case let .notice(kind, directive):
            return head + "session.\(kind.rawValue) -> " + DirectModeLayerTraceEntry.name(directive)
        case .remoteGatePause: return head + "remoteGate.pauseBecauseHeld"
        case .userPause: return head + "user.pause"
        }
    }
}

/// What the app shell must do for S. The app performs the AVAudioSession calls and the pauses;
/// this decides them, exactly as MusicKitService does at 6171fda.
public struct DirectModeSessionLayer: Equatable, Sendable {
    public static let traceCapacity = 200

    public let enabled: Bool
    public private(set) var policy = AudioSessionPolicy()
    public private(set) var categorySet = false
    public private(set) var trace: [DirectModeSessionTraceEntry] = []
    /// One remote-gate pause per held episode, so the 250 ms poll does not flood the trace.
    private var gatePauseLatched = false

    public init(enabled: Bool, at t: Double = 0) {
        self.enabled = enabled
        if enabled { record(.enabled, at: t) }
    }

    /// Before `play()`. True when the app must set the category (once) and call `setActive(true)`.
    public mutating func beforePlay(at t: Double) -> Bool {
        guard enabled else { return false }
        policy.userPlay()
        gatePauseLatched = false
        return true
    }

    /// True once the category is set; the app skips setCategory after that, like the service.
    public var needsCategory: Bool { enabled && !categorySet }

    public mutating func categoryResult(ok: Bool, at t: Double) {
        guard enabled else { return }
        if ok { categorySet = true }
        record(.setCategory(ok: ok), at: t)
    }

    public mutating func activationResult(ok: Bool, at t: Double) {
        guard enabled else { return }
        record(.setActive(ok: ok), at: t)
    }

    /// After `play()` returns. True when the app must pause (PlaybackStartGuard said held).
    public mutating func afterPlay(at t: Double) -> Bool {
        guard enabled else { return false }
        let decision = PlaybackStartGuard.afterPlay(mayAutoResume: policy.mayAutoResume,
                                                    userWantsPlayback: policy.userWantsPlayback)
        let keep = decision == .keepPlaying
        record(.guardAfterPlay(keepPlaying: keep), at: t)
        return !keep
    }

    /// An interruption or route-change notice. True when the app must pause (`.suspendPlayback`).
    /// `.resumeIfPermitted` is recorded only: S reproduces the pause, not the service's resume.
    public mutating func handle(_ notice: AudioSessionNotice, at t: Double) -> Bool {
        guard enabled else { return false }
        let directive = policy.handle(notice, breakIsActive: false)
        record(.notice(DirectModeSessionNoticeKind(notice), directive), at: t)
        return directive == .suspendPlayback
    }

    /// The poll saw the player playing. True when the app must pause (RemotePlayGate said held).
    public mutating func observePlaying(at t: Double) -> Bool {
        guard enabled else { return false }
        let decision = RemotePlayGate.admit(mayAutoResume: policy.mayAutoResume,
                                            userWantsPlayback: policy.userWantsPlayback)
        guard decision != .keepPlaying else {
            gatePauseLatched = false
            return false
        }
        if !gatePauseLatched {
            gatePauseLatched = true
            record(.remoteGatePause, at: t)
        }
        return true
    }

    public mutating func userPause(at t: Double) {
        guard enabled else { return }
        policy.userPause()
        record(.userPause, at: t)
    }

    /// The Direct Mode log, the layer trace and the S trace as one list, oldest first.
    /// Ordered by t; on a tie Direct Mode first, then layers, then S. With S off this is
    /// exactly `DirectModeLayerStack.mergedLog`.
    public static func mergedLog(_ log: [DirectModeLogEntry], _ layers: [DirectModeLayerTraceEntry],
                                 _ session: [DirectModeSessionTraceEntry]) -> [String] {
        let tagged = log.enumerated().map { (t: $0.element.t, rank: 0, i: $0.offset, line: $0.element.description) }
            + layers.enumerated().map { (t: $0.element.t, rank: 1, i: $0.offset, line: $0.element.description) }
            + session.enumerated().map { (t: $0.element.t, rank: 2, i: $0.offset, line: $0.element.description) }
        return tagged.sorted { ($0.t, $0.rank, $0.i) < ($1.t, $1.rank, $1.i) }.map(\.line)
    }

    private mutating func record(_ event: DirectModeSessionTraceEntry.Event, at t: Double) {
        trace.append(DirectModeSessionTraceEntry(t: t, event: event))
        if trace.count > Self.traceCapacity { trace.removeFirst(trace.count - Self.traceCapacity) }
    }
}
#endif
