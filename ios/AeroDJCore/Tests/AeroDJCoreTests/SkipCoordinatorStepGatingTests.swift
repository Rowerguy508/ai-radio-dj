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

/// #444: `SkipCoordinator` step gating. When a step may run (`allowsStep`, `admits`), what a
/// chain's first step is allowed to skip, and which state a step starts from. Mutation hunt on
/// SkipCoordinator.swift: these guards had no test that fails without them.
@MainActor
final class SkipCoordinatorStepGatingTests: XCTestCase {
    // MARK: allowsStep

    func testAnUngatedCoordinatorAllowsAStep() {
        let r = ChainRig()
        r.c.stepGate = nil
        XCTAssertTrue(r.c.allowsStep(), "tests that never pause or hold: only the generation applies")
    }

    func testAPauseAfterTheChainWasAuthorizedDeniesTheStep() {
        let r = ChainRig()
        r.c.stepGate = nil
        r.c.invalidate(.userPause)
        XCTAssertFalse(r.c.allowsStep())
    }

    func testAStepNeedsTheUserToWantPlaybackAndNoSystemHold() {
        let r = ChainRig()
        r.gate = (true, false)
        XCTAssertTrue(r.c.allowsStep())
        r.gate = (false, false)
        XCTAssertFalse(r.c.allowsStep(), "the user paused")
        r.gate = (true, true)
        XCTAssertFalse(r.c.allowsStep(), "the system holds playback")
        r.gate = (false, true)
        XCTAssertFalse(r.c.allowsStep())
    }

    // MARK: admits

    func testOnlyTheChainsOpeningNextHasTheFreshNextPrivilege() async {
        let r = ChainRig()
        var opening: Bool?
        var openingReload: Bool?
        var followUp: Bool?
        var followUpReload: Bool?
        r.onStep = { n, _ in
            if n == 0 {
                r.gate = (false, true)
                opening = r.c.admits(.advance)
                openingReload = r.c.admits(.reload)
                r.gate = (true, false)
            } else {
                r.gate = (false, true)
                followUp = r.c.admits(.advance)
                followUpReload = r.c.admits(.reload)
            }
        }
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .advance])
        XCTAssertEqual(opening, true, "the user's Next may play over a hold")
        XCTAssertEqual(openingReload, false, "a reload may not")
        XCTAssertEqual(followUp, false, "a stored follow-up is gated like a reload")
        XCTAssertEqual(followUpReload, false)
    }

    func testACutOpenedFirstStepHasNoFreshNextPrivilege() async {
        let r = ChainRig()
        var admitted: Bool?
        r.onStep = { _, _ in
            r.gate = (false, true)
            admitted = r.c.admits(.advance)
        }
        XCTAssertEqual(r.c.noteCutAsNext(from: 0), .begin)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance], "no hold when the step began")
        XCTAssertEqual(admitted, false, "a cut is not the user's own command")
    }

    // MARK: runChain entry

    func testARunningChainIgnoresANestedRunChain() async {
        let r = ChainRig()
        r.onStep = { n, _ in
            if n == 0 { await r.chain() }
        }
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance], "the nested call returns at once and runs nothing")
    }

    func testARunChainWithoutAnIntakeIsStillInFlight() async {
        let r = ChainRig()
        var inFlight: Bool?
        r.onStep = { _, _ in inFlight = r.c.isInFlight }
        await r.chain()
        XCTAssertEqual(inFlight, true)
        XCTAssertFalse(r.c.isInFlight, "and not once it has exited")
    }

    func testAChainAuthorizedBeforeAPauseDoesNotRun() async {
        let idle = ChainRig()
        idle.c.invalidate(.userPause)
        await idle.chain()
        XCTAssertEqual(idle.jobs, [], "a chain with no intake after a pause has no authorization")
        let intake = ChainRig()
        XCTAssertEqual(intake.c.requestAdvance(), .begin)
        intake.c.invalidate(.userPause)
        await intake.chain()
        XCTAssertEqual(intake.jobs, [], "a pause between the Next and its first step cancels it")
    }

    func testARecoveryStartedAfterAnEarlierPauseRuns() async {
        let r = ChainRig()
        r.c.invalidate(.userPause)
        XCTAssertEqual(r.c.noteLoadCut(target: 0), .recover)
        await r.recover()
        XCTAssertEqual(r.jobs, [.reload], "a recovery is authorized when it begins, not when the app launched")
    }

    // MARK: the first step

    func testACutOpenedChainStartsTheRecoveryBudgetOver() async {
        let r = ChainRig()
        await r.spendRecovery(of: 1)
        XCTAssertEqual(r.c.noteCutAsNext(from: 1), .begin)
        await r.chain()
        XCTAssertEqual(r.c.recoveriesSpent, 0, "a cut-as-Next is a new Next to a new song")
        XCTAssertEqual(r.c.noteLoadCut(target: 1), .recover)
    }

    func testAUserNextStartsTheRecoveryBudgetOver() async {
        let r = ChainRig()
        await r.spendRecovery(of: 1)
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.c.recoveriesSpent, 0)
        XCTAssertEqual(r.c.noteLoadCut(target: 1), .recover)
    }

    func testAStoredFollowUpDoesNotStartTheRecoveryBudgetOver() async {
        let r = ChainRig()
        var spentAtFollowUp: Int?
        r.onStep = { n, _ in if n == 2 { spentAtFollowUp = r.c.recoveriesSpent } }
        r.results = [.failed(.couldNotStart, target: 0), .playing, .playing]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .reload, .advance])
        XCTAssertEqual(spentAtFollowUp, 1, "queued work is not a new command: the spent retry stays spent")
    }

    // MARK: later steps are gated

    func testAHoldThatLandsDuringTheStepStopsTheRetryReload() async {
        let r = ChainRig()
        r.onStep = { n, _ in if n == 0 { r.gate = (false, true) } }
        r.results = [.failed(.couldNotStart, target: 0)]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance], "a reload must not run over a hold")
    }

    func testACutSeenDuringAnEarlierStepDoesNotTurnALaterThrowIntoAnAdvance() async {
        let r = ChainRig()
        r.onStep = { n, _ in if n == 0 { _ = r.c.noteLoadCut(target: 0) } }
        r.results = [.playing, .failed(.couldNotStart, target: 0)]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .reload], "the cut belonged to the first step, and no Next is stored")
        XCTAssertEqual(r.surfaced, [.couldNotStart])
    }

    func testAFollowUpTheHoldCancelledStaysCancelledWhenTheHoldLifts() async {
        let r = ChainRig()
        r.results = [.loadCut(target: 0), .playing]
        // The gate is read once for the follow-up (held), then once for the reload step (clear).
        r.gateScript = [(false, true), (true, false)]
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .reload], "the stored Next was dropped by the hold, for good")
    }
}
