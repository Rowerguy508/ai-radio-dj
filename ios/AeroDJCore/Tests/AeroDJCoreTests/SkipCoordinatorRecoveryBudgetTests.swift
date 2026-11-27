import XCTest
@testable import AeroDJCore

/// A scripted player for `SkipCoordinator`, called the way `MusicKitService` calls it.
/// Public coordinator API only. `results` are consumed one per step (default `.playing`).
@MainActor
private final class ChainRig {
    typealias Gate = (userWantsPlayback: Bool, pausedBySystem: Bool)
    let c = SkipCoordinator()
    /// The live hold gate. `gateScript` answers first, one value per `stepGate` call.
    var gate: Gate = (true, false)
    var gateScript: [Gate] = []
    var surfaced: [SkipTerminalFailure] = []
    var resumes = 0
    var jobs: [SkipJob] = []
    var results: [SkipLoadResult] = []
    var onStep: (@MainActor (Int, SkipJob) async -> Void)?

    init() {
        c.stepGate = { [unowned self] in
            if !self.gateScript.isEmpty { return self.gateScript.removeFirst() }
            return self.gate
        }
    }

    func chain(first: SkipJob = .advance, resume: (@MainActor () async -> Void)? = nil) async {
        await c.runChain(first: first, surface: { [unowned self] in self.surfaced.append($0) },
                         resume: resume, body)
    }

    func recover() async {
        await c.runRecovery(surface: { [unowned self] in self.surfaced.append($0) }, resume: nil, body)
    }

    private func body(_ job: SkipJob) async -> SkipLoadResult {
        let n = jobs.count
        jobs.append(job)
        // A mutant that loops would never finish: a pause ends any runaway chain.
        if jobs.count > 8 { c.invalidate(.userPause) }
        await onStep?(n, job)
        return results.isEmpty ? .playing : results.removeFirst()
    }

    /// One recovery of `target`: the budget for it is spent afterwards.
    func spendRecovery(of target: Int) async {
        XCTAssertEqual(c.noteLoadCut(target: target), .recover)
        await recover()
        XCTAssertEqual(c.recoveriesSpent, 1)
    }
}

/// #444: `SkipCoordinator` recovery budget and error surfacing. One same-target recovery until
/// real progress or a new Next, and one banner per exhausted target. Mutation hunt on
/// SkipCoordinator.swift: these resets and guards had no test that fails without them.
@MainActor
final class SkipCoordinatorRecoveryBudgetTests: XCTestCase {
    // MARK: noteLoadCut

    func testAnExhaustedTargetIsSurfacedOnceAndThenFolded() async {
        let r = ChainRig()
        await r.spendRecovery(of: 1)
        XCTAssertEqual(r.c.noteLoadCut(target: 1), .exhausted)
        XCTAssertEqual(r.c.noteLoadCut(target: 1), .folded, "the banner is already up")
    }

    func testANewTargetGetsItsOwnRecoveryAndItsOwnCount() async {
        let r = ChainRig()
        await r.spendRecovery(of: 1)
        XCTAssertEqual(r.c.noteLoadCut(target: 2), .recover)
        await r.recover()
        XCTAssertEqual(r.c.recoveriesSpent, 1, "the count restarts for the new target")
        XCTAssertEqual(r.c.noteLoadCut(target: 2), .exhausted)
    }

    func testProgressClearsTheSpentRecoveryCount() async {
        let r = ChainRig()
        await r.spendRecovery(of: 1)
        r.c.noteProgress()
        XCTAssertEqual(r.c.recoveriesSpent, 0)
        XCTAssertEqual(r.c.noteLoadCut(target: 1), .recover)
    }

    // MARK: a reload with no budget left

    func testAReloadOfASpentTargetSurfacesOnceAndDoesNotLoad() async {
        let r = ChainRig()
        await r.spendRecovery(of: 1)
        XCTAssertEqual(r.jobs, [.reload])
        await r.recover()
        XCTAssertEqual(r.jobs, [.reload], "the budget is spent: no load")
        XCTAssertEqual(r.surfaced, [.couldNotStart])
        await r.recover()
        XCTAssertEqual(r.surfaced, [.couldNotStart], "one banner, not one per attempt")
    }

    // MARK: the one same-target retry for a throw

    func testAReloadThatThrowsIsNotRetriedEvenForAnotherTarget() async {
        let r = ChainRig()
        r.results = [.failed(.couldNotStart, target: 0), .failed(.couldNotStart, target: 7)]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .reload], "only an advance earns the one same-target retry")
        XCTAssertEqual(r.surfaced, [.couldNotStart])
    }

    func testAFollowUpThatThrowsAfterTheSpentRetryIsNotRetried() async {
        let r = ChainRig()
        r.results = [.failed(.couldNotStart, target: 0), .playing, .failed(.couldNotStart, target: 0)]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .reload, .advance], "the retry of target 0 is already spent")
        XCTAssertEqual(r.surfaced, [.couldNotStart])
    }

    func testAnUnavailableSongStillRunsTheStoredNextInsteadOfSurfacing() async {
        let r = ChainRig()
        r.results = [.failed(.songUnavailable, target: 0), .playing]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .advance], "the user already moved on")
        XCTAssertEqual(r.surfaced, [], "no banner for a song they left")
    }

    func testASurfacedThrowMarksTheTargetSurfaced() async {
        let r = ChainRig()
        r.results = [.failed(.couldNotStart, target: 0), .failed(.couldNotStart, target: 0)]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.surfaced, [.couldNotStart])
        XCTAssertEqual(r.c.noteLoadCut(target: 0), .folded, "a late clear must not raise the banner again")
    }

    func testANewNextLetsTheNextExhaustedTargetSurfaceAgain() async {
        let r = ChainRig()
        await r.spendRecovery(of: 0)
        XCTAssertEqual(r.c.noteLoadCut(target: 0), .exhausted)
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.c.noteLoadCut(target: 0), .recover, "the new Next starts the budget over")
        r.results = [.playing]
        await r.recover()
        XCTAssertEqual(r.c.noteLoadCut(target: 0), .exhausted, "a banner raised before the new Next is not this one")
    }

    // MARK: cuts reported by the step itself

    func testALoadCutResultReloadsTheTargetItNamesAndSpendsItsBudget() async {
        let r = ChainRig()
        r.results = [.loadCut(target: 0), .playing]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .reload])
        XCTAssertEqual(r.c.recoveriesSpent, 1, "the reload consumed the recovery of the named target")
    }

    func testASecondLoadCutOfTheSameTargetSurfacesOnceAndMarksItSurfaced() async {
        let r = ChainRig()
        r.results = [.loadCut(target: 0), .loadCut(target: 0)]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .reload])
        XCTAssertEqual(r.surfaced, [.couldNotStart])
        XCTAssertEqual(r.c.noteLoadCut(target: 0), .folded, "already surfaced")
    }
}

/// `SkipFailureSurface`: the banner and transport for a skip that cannot start.
final class SkipFailureSurfaceTests: XCTestCase {
    func testASurfacedSkipFailureCancelsTheConfirmRaisesTheErrorAndPauses() {
        let attempt = PlaybackAttemptID(number: 3)
        let effect = SkipFailureSurface.effect(.couldNotStart, attempt: attempt, current: attempt)
        XCTAssertFalse(effect.pausesPlayer)
        XCTAssertTrue(effect.cancelsConfirm, "the start-confirm watchdog must not fire over the surfaced failure")
        XCTAssertEqual(effect.events.count, 2)
        if case .errorRaised(let error)? = effect.events.first {
            XCTAssertTrue(error.isRecoverable)
        } else {
            XCTFail("the first event raises the error")
        }
        XCTAssertEqual(effect.events.last, .userPaused, "the transport shows paused, as for a thrown start")
        XCTAssertNotNil(effect.message)
    }
}
