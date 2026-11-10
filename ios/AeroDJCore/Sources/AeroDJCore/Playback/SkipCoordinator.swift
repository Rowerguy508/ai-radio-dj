import Foundation

/// What one step of a skip did to the player.
public enum SkipLoadResult: Equatable, Sendable {
    /// The selected target is audible, and no load cut was observed for it.
    case playing
    /// The skip walked off the end of the queue on purpose.
    case queueStopped
    /// MusicKit cleared or rewound `target` before it played. Not a new Next.
    case loadCut(target: Int)
    /// The user paused, a hold landed, or a newer start owns the player.
    case cancelled
    /// The song cannot be started. Stay on `target` and surface the error.
    case failed(SkipTerminalFailure, target: Int)
}

/// Why a skip load will not succeed by trying again on a different song.
public enum SkipTerminalFailure: Equatable, Sendable {
    /// The queue entry has no playable song. Do not reload a different index.
    case songUnavailable
    /// `prepareToPlay` / `play` failed, and the one same-target recovery is spent.
    case couldNotStart
}

/// One load inside a skip chain. `.advance` is an explicit Next. `.reload` plays the
/// already selected target again and must not clear a system hold.
public enum SkipJob: Equatable, Sendable {
    case advance
    case reload
}

/// Why a queued follow-up or a recovery must not run.
public enum SkipInvalidation: Equatable, Sendable {
    case userPause
    case routeRemoved
    case interruptionBegan
    case queueReplaced
}

/// What an ambiguous pre-progress clear asks the caller to do. It never mints a Next.
public enum LoadCutDisposition: Equatable, Sendable {
    /// A chain is already running. It recovers the selected track, or plays the one
    /// explicit follow-up already stored. This observation is not a second command.
    case folded
    /// No chain is running and this target still has a recovery. Start `runRecovery`.
    case recover
    /// This target has already been recovered since the last real progress or user Next.
    /// Surface a recoverable error. Do not load again.
    case exhausted
}

/// The banner and transport for a skip that cannot start, using the same shape as a thrown start.
public enum SkipFailureSurface {
    public static func effect(_ failure: SkipTerminalFailure, attempt: PlaybackAttemptID,
                              current: PlaybackAttemptID?) -> StartFailureEffect {
        guard current == attempt else { return .none }
        let message = PlaybackFailureCopy.message(for: failure.kind)
        return StartFailureEffect(
            pausesPlayer: false,
            cancelsConfirm: true,
            events: [
                .errorRaised(PlaybackError(kind: .playbackFailed, message: message, isRecoverable: true)),
                .userPaused
            ],
            message: message
        )
    }
}

extension SkipTerminalFailure {
    var kind: PlaybackFailureKind {
        switch self {
        case .songUnavailable: .songUnavailable
        case .couldNotStart: .couldNotStart
        }
    }
}

/// #444 (-Echo): one skip chain. A second explicit Next while it is loading stores one
/// follow-up. An ambiguous MusicKit clear of the song being loaded recovers that song;
/// it is not another Next. A later Pause, route loss, interruption, or queue replacement
/// invalidates the chain so the follow-up and any reload cannot call `userPlay()` over the hold.
@MainActor
public final class SkipCoordinator {
    /// One automatic recovery of a target until real playback progress or a new explicit Next.
    public static let recoveryLimit = 1

    public enum Intake: Equatable, Sendable {
        case begin
        case queueOneMore
        case ignore
    }

    public private(set) var generation = 0
    public private(set) var isInFlight = false
    /// An interruption ended with permission to resume while this chain was still in flight.
    public private(set) var resumeOwed = false

    /// Read at the start of each step. Nil in tests that never pause or hold: only the generation applies.
    public var stepGate: (@MainActor () -> (userWantsPlayback: Bool, pausedBySystem: Bool))?

    private var chainRunning = false
    /// Generation when this chain was authorized. A later pause or hold does not become the step's generation.
    private var authorizedGeneration = 0
    private var queued = false
    private var sealed = false
    private var loadCut = false
    private var pendingCutTarget: Int?
    private var recoveryTarget: Int?
    private var recoveries = 0
    private var terminalSurfaced = false
    private var stepGeneration = 0

    public init() {}

    /// Pause, route loss, interruption began, or a new queue. Drops a stored follow-up.
    /// The in-flight load is left to finish; the next step sees the new generation and does not run.
    public func invalidate(_ reason: SkipInvalidation) {
        generation += 1
        queued = false
        resumeOwed = false
        if reason == .queueReplaced { resetBudget() }
    }

    /// Call after the session policy has applied the end. Owed only while a chain is in flight,
    /// so the chain can resume once when it exits. A chain that is not running resumes immediately
    /// through the existing `resumeIfAllowed` path.
    public func noteInterruptionEnded(shouldResume: Bool, mayAutoResume: Bool) {
        guard isInFlight else { return }
        resumeOwed = shouldResume && mayAutoResume
    }

    /// The loaded song played past the failed-start window. This target may be recovered again
    /// after a later skip.
    public func noteProgress() {
        resetBudget()
    }

    /// An explicit Next: the in-app button, `nextTrackCommand`, or a remote skip of a song that
    /// had already played. The second one while a chain is running queues one advance. The third
    /// is ignored. A load cut must not call this.
    public func requestAdvance() -> Intake {
        if !isInFlight {
            authorizedGeneration = generation
            isInFlight = true
            queued = false
            sealed = false
            return .begin
        }
        if sealed || queued { return .ignore }
        queued = true
        return .queueOneMore
    }

    /// A pre-progress clear or rewind. Recovers `target` or folds into the chain. Never queues a Next.
    public func noteLoadCut(target: Int) -> LoadCutDisposition {
        pendingCutTarget = target
        if isInFlight {
            loadCut = true
            return .folded
        }
        guard budgetAllows(target) else {
            if terminalSurfaced { return .folded }
            terminalSurfaced = true
            return .exhausted
        }
        guard beginRecovery() else { return .folded }
        return .recover
    }

    private func beginRecovery() -> Bool {
        guard !isInFlight, !chainRunning else { return false }
        authorizedGeneration = generation
        isInFlight = true
        return true
    }

    /// True for the step that was just started, and only while the user still wants playback
    /// and the system is not holding it.
    public func allowsStep() -> Bool {
        guard stepGeneration == generation else { return false }
        guard let stepGate else { return true }
        let gate = stepGate()
        return gate.userWantsPlayback && !gate.pausedBySystem
    }

    public func runChain(first: SkipJob = .advance,
                         surface: (@MainActor (SkipTerminalFailure) -> Void)? = nil,
                         resume: (@MainActor () async -> Void)? = nil,
                         _ body: @MainActor (SkipJob) async -> SkipLoadResult) async {
        guard !chainRunning else { return }
        chainRunning = true
        isInFlight = true
        let ticket = authorizedGeneration
        var job = first
        while true {
            stepGeneration = ticket
            guard allowsStep() else { break }
            if job == .advance {
                resetBudget()
            } else if let target = pendingCutTarget {
                // The reload is the one recovery of this target. A later clear does not get another.
                guard budgetAllows(target) else {
                    if !terminalSurfaced {
                        terminalSurfaced = true
                        surface?(.couldNotStart)
                    }
                    break
                }
                consume(target)
            }
            loadCut = false
            let captured = generation
            let result = await body(job)
            guard captured == generation, allowsStep() else { break }
            switch result {
            case .cancelled, .queueStopped:
                break
            case let .failed(failure, target):
                // A throw is not a load cut. One same-target retry, then the recoverable error.
                // An unavailable song is never retried onto a different index.
                if failure != .songUnavailable, job == .advance, budgetAllows(target) {
                    pendingCutTarget = target
                    job = .reload
                    continue
                }
                surface?(failure)
                terminalSurfaced = true
                break
            case .playing, .loadCut:
                if queued, !sealed, job == .advance {
                    // The explicit follow-up is the second Next. Its MusicKit observation is not another one.
                    queued = false
                    sealed = true
                    job = .advance
                    continue
                }
                let cut: Int? = {
                    if case let .loadCut(target) = result { return target }
                    if loadCut { return pendingCutTarget }
                    return nil
                }()
                guard let target = cut else { break }
                guard budgetAllows(target) else {
                    if !terminalSurfaced {
                        terminalSurfaced = true
                        surface?(.couldNotStart)
                    }
                    break
                }
                pendingCutTarget = target
                job = .reload
                continue
            }
            break
        }
        chainRunning = false
        isInFlight = false
        queued = false
        sealed = false
        loadCut = false
        let owed = resumeOwed
        resumeOwed = false
        if owed, let resume { await resume() }
    }

    public func runRecovery(surface: (@MainActor (SkipTerminalFailure) -> Void)? = nil,
                            resume: (@MainActor () async -> Void)? = nil,
                            _ body: @MainActor (SkipJob) async -> SkipLoadResult) async {
        await runChain(first: .reload, surface: surface, resume: resume, body)
    }

    private func budgetAllows(_ target: Int) -> Bool {
        if recoveryTarget != target { return true }
        return recoveries < Self.recoveryLimit
    }

    private func consume(_ target: Int) {
        if recoveryTarget != target {
            recoveryTarget = target
            recoveries = 0
        }
        recoveries += 1
    }

    private func resetBudget() {
        recoveryTarget = nil
        recoveries = 0
        terminalSurfaced = false
    }
}
