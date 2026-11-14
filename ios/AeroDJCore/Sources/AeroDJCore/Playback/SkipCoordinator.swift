import Foundation

/// What one step of a skip did to the player.
public enum SkipLoadResult: Equatable, Sendable {
    /// The selected target is audible, and no load cut was observed for it.
    case playing
    /// The skip walked off the end of the queue on purpose.
    case queueStopped
    /// MusicKit cleared or rewound `target` while our own `play()` for it was awaiting. Not a new Next.
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
    /// Explicit or remote Play replaced a skip that was still loading.
    case userPlay
    case routeRemoved
    case interruptionBegan
    case queueReplaced
}

/// What an ambiguous clear of our own awaiting `play()` asks the caller to do. It never mints a
/// Next. A cut seen after our `play()` returned is `noteCutAsNext` instead (#444 build 43).
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
/// follow-up. An ambiguous MusicKit clear of the song being loaded, while our own `play()` is
/// awaiting, recovers that song; it is not another Next. #444 build 43 (-Atlas): a clear seen
/// after our `play()` returned is MusicKit's own Next (`noteCutAsNext`), and a step that throws
/// after a cut was seen during it advances once instead of reloading the song the user left. A later Pause, route loss, interruption, or queue replacement
/// invalidates the chain so the follow-up and any reload cannot call `userPlay()` over the hold.
@MainActor
public final class SkipCoordinator {
    /// One automatic recovery of a target until real playback progress or a new explicit Next.
    public static let recoveryLimit = 1

    public enum Intake: Equatable, Sendable {
        /// Caller starts the chain now.
        case begin
        /// Stored behind the step that is running. Not returned once the chain is invalidated or ending.
        case queueOneMore
        /// A fresh Next arrived after the chain was invalidated or was about to end.
        /// The chain that is running starts it when it exits. The caller does not start a second one.
        case beginWhenIdle
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
    /// #444 build 43: a MusicKit cut (ambiguous or a Next) was observed during the running step.
    private var cutDuringStep = false
    /// #444 build 43: the index a cut-as-Next was observed on, until an advance selects a later one.
    private var skippedFrom: Int?
    /// #459 B1 (Sentinel): the chain about to start was opened by a MusicKit cut, not by the user's
    /// own Next. Its opening step has no fresh-Next privilege: it must pass `allowsStep()`.
    private var openingFromCut = false
    /// The same for a Next stored as `pendingFresh` (`.beginWhenIdle`) that came from a cut.
    private var pendingFreshFromCut = false
    private var stepGeneration = 0
    /// The step in `body` is the explicit Next that started this chain, not a stored follow-up.
    private var stepIsFresh = false
    /// `invalidate` bumped the generation while this chain was still running.
    private var invalidated = false
    /// A fresh Next arrived for a chain that is invalidated or ending. Run it after this chain exits,
    /// and only if no hold has landed since the press.
    private var pendingFresh = false
    /// `generation` when that Next was pressed. A later hold bumps generation and cancels it.
    private var pendingFreshGeneration = 0
    /// The chain will not take another stored follow-up. A Next here is a new chain, not `.queueOneMore`.
    private var ending = false

    public init() {}

    /// Same-target recoveries spent on the current recovery target. Diagnostics only.
    public var recoveriesSpent: Int { recoveries }

    /// #444 build 43: the song a lock-screen Next (seen as a cut) was meant to leave, while no
    /// advance has selected a later song yet. Play must not reload it.
    public var skippedPastIndex: Int? { skippedFrom }

    /// #453 (-Atlas): skip work an explicit or remote Play must cancel. A chain in flight, and also
    /// the ending window after it, while it awaits an owed interruption resume: a Next pressed there
    /// is stored as `pendingFresh` and would start once that resume returns, after the newer Play.
    public var hasPendingSkipWork: Bool { isInFlight || ending }

    /// Pause, route loss, interruption began, or a new queue. Drops a stored follow-up.
    /// The in-flight load is left to finish; the next step sees the new generation and does not run.
    public func invalidate(_ reason: SkipInvalidation) {
        generation += 1
        queued = false
        resumeOwed = false
        // A Next pressed after an earlier hold is still pending until the old load returns.
        // This later Pause, call, or route loss cancels it.
        pendingFresh = false
        pendingFreshFromCut = false
        if chainRunning || isInFlight { invalidated = true }
        if reason == .queueReplaced {
            resetBudget()
            skippedFrom = nil
        }
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
        // A Next after pause, route loss, or interruption is a new command. Do not fold it
        // into the chain those just cancelled, and do not report a follow-up that will not run.
        if invalidated || ending {
            pendingFresh = true
            pendingFreshFromCut = false
            pendingFreshGeneration = generation
            return .beginWhenIdle
        }
        if !isInFlight {
            authorizedGeneration = generation
            isInFlight = true
            openingFromCut = false
            queued = false
            sealed = false
            return .begin
        }
        if sealed || queued { return .ignore }
        queued = true
        return .queueOneMore
    }

    /// #444 build 43 (-Atlas): MusicKit cleared or rewound the skipped-to song after our own `play()`
    /// for it returned (or before it was called). That is the user's lock-screen Next: the same
    /// intake as `requestAdvance()`, so it folds into `.queueOneMore` when a chain is running.
    /// The caller has already checked that no hold is active (`SkipLoadCutRoute`), but a hold can
    /// still land before the step runs. #459 B1: a cut is not the user's own command, so the step it
    /// opens (or the `.beginWhenIdle` Next it stores) passes `allowsStep()` like a stored follow-up,
    /// and cannot call `userPlay()` over a hold. A real user Next keeps its fresh-Next privilege.
    public func noteCutAsNext(from index: Int) -> Intake {
        if chainRunning { cutDuringStep = true }
        skippedFrom = index
        let userFreshPending = pendingFresh && !pendingFreshFromCut
        let intake = requestAdvance()
        switch intake {
        case .begin:
            openingFromCut = true
        case .beginWhenIdle:
            if !userFreshPending { pendingFreshFromCut = true }
        case .queueOneMore, .ignore:
            break
        }
        return intake
    }

    /// An advance selected `index`. A cut-as-Next observed on an earlier song has been served.
    public func noteSelected(index: Int) {
        if let from = skippedFrom, index > from { skippedFrom = nil }
    }

    /// A clear or rewind while our own `play()` was awaiting. Recovers `target` or folds into the
    /// chain. Never queues a Next.
    public func noteLoadCut(target: Int) -> LoadCutDisposition {
        pendingCutTarget = target
        if isInFlight {
            loadCut = true
            if chainRunning { cutDuringStep = true }
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
    /// and the system is not holding it. A stored follow-up uses this. A fresh explicit Next does not.
    public func allowsStep() -> Bool {
        guard stepGeneration == generation, !invalidated else { return false }
        guard let stepGate else { return true }
        let gate = stepGate()
        return gate.userWantsPlayback && !gate.pausedBySystem
    }

    /// `.advance` that opened this chain is the user's Next: it may call `userPlay()` while paused
    /// or held. `.reload` and a stored follow-up must pass `allowsStep()`.
    public func admits(_ job: SkipJob) -> Bool {
        if job == .advance && stepIsFresh { return stepGeneration == generation && !invalidated }
        return allowsStep()
    }

    public func runChain(first: SkipJob = .advance,
                         surface: (@MainActor (SkipTerminalFailure) -> Void)? = nil,
                         resume: (@MainActor () async -> Void)? = nil,
                         _ body: @MainActor (SkipJob) async -> SkipLoadResult) async {
        guard !chainRunning else { return }
        chainRunning = true
        isInFlight = true
        let ticket = authorizedGeneration
        // #459 B1: a chain a cut opened has no fresh-Next privilege on its first step.
        let cutOpened = openingFromCut
        openingFromCut = false
        var job = first
        var opening = true
        while true {
            stepGeneration = ticket
            let openingAdvance = opening && job == .advance
            let fresh = openingAdvance && !cutOpened
            opening = false
            stepIsFresh = fresh
            if openingAdvance && cutOpened {
                // Gated like a stored follow-up. Still a new Next to a new song: the budget starts over.
                guard allowsStep() else { break }
                resetBudget()
            } else if fresh {
                guard stepGeneration == generation, !invalidated else { break }
                // A new explicit Next, not a stored follow-up. The recovery budget starts over.
                resetBudget()
            } else {
                guard allowsStep() else { break }
                if job == .reload, let target = pendingCutTarget {
                    guard budgetAllows(target) else {
                        if !terminalSurfaced {
                            terminalSurfaced = true
                            surface?(.couldNotStart)
                        }
                        break
                    }
                    consume(target)
                }
            }
            loadCut = false
            cutDuringStep = false
            let captured = generation
            let result = await body(job)
            stepIsFresh = false
            guard captured == generation, !invalidated else { break }
            switch result {
            case .cancelled, .queueStopped:
                break
            case let .failed(failure, target):
                // #444 build 43: MusicKit cut this load and then it threw. The cut was the user's
                // Next: one stored follow-up advance, never a reload of the song they left. A hold
                // still cancels it (`takeFollowUp` checks the gate), and a sealed chain falls through.
                if cutDuringStep, !sealed, !invalidated {
                    queued = true
                    if takeFollowUp() {
                        job = .advance
                        continue
                    }
                }
                // One same-target retry for a throw. An unavailable song is never retried elsewhere.
                // The stored Next waits until that retry finishes, then runs only if the hold allows.
                if failure != .songUnavailable, job == .advance, budgetAllows(target) {
                    pendingCutTarget = target
                    job = .reload
                    continue
                }
                if takeFollowUp() {
                    job = .advance
                    continue
                }
                surface?(failure)
                terminalSurfaced = true
                break
            case .playing, .loadCut:
                if takeFollowUp() {
                    // Honor the Next pressed during this advance or reload. Do not reset the
                    // recovery budget: this is queued work, not a new command.
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
        stepIsFresh = false
        chainRunning = false
        isInFlight = false
        queued = false
        sealed = false
        loadCut = false
        ending = true
        let owed = resumeOwed
        resumeOwed = false
        if owed, let resume { await resume() }
        let startFresh = pendingFresh && pendingFreshGeneration == generation
        let freshFromCut = pendingFreshFromCut
        pendingFresh = false
        pendingFreshFromCut = false
        invalidated = false
        ending = false
        if startFresh {
            authorizedGeneration = generation
            isInFlight = true
            openingFromCut = freshFromCut
            await runChain(first: .advance, surface: surface, resume: resume, body)
        }
    }

    /// A Next stored during this chain. It runs only while the hold still allows it, and it does
    /// not reset the recovery budget. A pause or hold clears `queued` in `invalidate` as well.
    private func takeFollowUp() -> Bool {
        guard queued, !sealed, !invalidated, !ending else { return false }
        guard allowsStep() else {
            queued = false
            return false
        }
        queued = false
        sealed = true
        return true
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
