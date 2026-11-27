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

/// #444: `SkipCoordinator` intake and invalidation. What `invalidate`, `requestAdvance`,
/// `noteCutAsNext`, `noteSelected`, `noteInterruptionEnded` and a chain's exit reset or refuse.
/// Mutation hunt on SkipCoordinator.swift: these resets and guards had no test that fails without them.
@MainActor
final class SkipCoordinatorIntakeInvalidationTests: XCTestCase {
    // MARK: invalidate

    /// `invalidate` marks a chain that has been authorized but has not started running yet.
    func testNextAfterAHoldBeforeTheChainStartsWaitsForIdleInsteadOfQueueing() {
        let r = ChainRig()
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        r.c.invalidate(.userPause)
        XCTAssertEqual(r.c.requestAdvance(), .beginWhenIdle,
                       "a Next after a hold is a new command, not the one follow-up of the cancelled chain")
    }

    func testInvalidateDropsAnOwedResume() async {
        let r = ChainRig()
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        r.c.noteInterruptionEnded(shouldResume: true, mayAutoResume: true)
        XCTAssertTrue(r.c.resumeOwed)
        r.c.invalidate(.interruptionBegan)
        XCTAssertFalse(r.c.resumeOwed, "a later hold cancels the owed resume")
        await r.chain(resume: { r.resumes += 1 })
        XCTAssertEqual(r.resumes, 0)
    }

    func testOnlyAReplacedQueueResetsTheRecoveryBudget() async {
        for reason in [SkipInvalidation.userPause, .userPlay, .routeRemoved, .interruptionBegan] {
            let r = ChainRig()
            await r.spendRecovery(of: 1)
            r.c.invalidate(reason)
            XCTAssertEqual(r.c.recoveriesSpent, 1, "\(reason) keeps the spent recovery")
            XCTAssertEqual(r.c.noteLoadCut(target: 1), .exhausted, "\(reason) must not grant a second recovery")
        }
        let replaced = ChainRig()
        await replaced.spendRecovery(of: 1)
        replaced.c.invalidate(.queueReplaced)
        XCTAssertEqual(replaced.c.recoveriesSpent, 0)
        XCTAssertEqual(replaced.c.noteLoadCut(target: 1), .recover, "a new queue starts the budget over")
    }

    func testOnlyAReplacedQueueForgetsTheSkippedPastSong() {
        let r = ChainRig()
        _ = r.c.noteCutAsNext(from: 1)
        XCTAssertEqual(r.c.skippedPastIndex, 1)
        r.c.invalidate(.userPause)
        XCTAssertEqual(r.c.skippedPastIndex, 1, "a pause does not serve the skip")
        r.c.invalidate(.queueReplaced)
        XCTAssertNil(r.c.skippedPastIndex, "an index of the old queue means nothing in the new one")
    }

    // MARK: noteInterruptionEnded, noteSelected

    func testAnInterruptionEndOwesAResumeOnlyInFlightAndOnlyWhenBothAllowIt() {
        let r = ChainRig()
        r.c.noteInterruptionEnded(shouldResume: true, mayAutoResume: true)
        XCTAssertFalse(r.c.resumeOwed, "nothing is in flight: the existing resume path handles it")
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        r.c.noteInterruptionEnded(shouldResume: true, mayAutoResume: false)
        XCTAssertFalse(r.c.resumeOwed, "the session policy forbids an auto resume")
        r.c.noteInterruptionEnded(shouldResume: false, mayAutoResume: true)
        XCTAssertFalse(r.c.resumeOwed, "the system did not ask to resume")
        r.c.noteInterruptionEnded(shouldResume: false, mayAutoResume: false)
        XCTAssertFalse(r.c.resumeOwed)
        r.c.noteInterruptionEnded(shouldResume: true, mayAutoResume: true)
        XCTAssertTrue(r.c.resumeOwed)
    }

    func testSelectingALaterSongServesTheSkippedPastIndexAndNothingElseDoes() {
        let r = ChainRig()
        _ = r.c.noteCutAsNext(from: 1)
        r.c.noteSelected(index: 0)
        XCTAssertEqual(r.c.skippedPastIndex, 1, "an earlier song is not past it")
        r.c.noteSelected(index: 1)
        XCTAssertEqual(r.c.skippedPastIndex, 1, "the same song is not past it")
        r.c.noteSelected(index: 2)
        XCTAssertNil(r.c.skippedPastIndex, "a later song serves it")
    }

    // MARK: requestAdvance limits

    func testAThirdNextWhileOneIsQueuedIsIgnored() {
        let r = ChainRig()
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        XCTAssertEqual(r.c.requestAdvance(), .ignore, "one stored follow-up at most")
    }

    func testANextDuringTheStoredFollowUpIsIgnoredBecauseTheChainIsSealed() async {
        let r = ChainRig()
        var seen: SkipCoordinator.Intake?
        r.onStep = { n, _ in if n == 1 { seen = r.c.requestAdvance() } }
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .advance])
        XCTAssertEqual(seen, .ignore, "the follow-up has been taken: the chain takes no more")
    }

    // MARK: the ending window (a Next while the chain awaits an owed resume)

    func testANextInTheEndingWindowWaitsForIdleAndRunsExactlyOnce() async {
        let r = ChainRig()
        var intake: SkipCoordinator.Intake?
        var pending: Bool?
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        r.c.noteInterruptionEnded(shouldResume: true, mayAutoResume: true)
        await r.chain(resume: {
            intake = r.c.requestAdvance()
            pending = r.c.hasPendingSkipWork
        })
        XCTAssertEqual(intake, .beginWhenIdle)
        XCTAssertEqual(pending, true)
        XCTAssertEqual(r.jobs, [.advance, .advance], "the pending Next runs once after the resume, not again")
        XCTAssertFalse(r.c.isInFlight)
        XCTAssertFalse(r.c.hasPendingSkipWork)
    }

    /// Runs a chain whose owed resume lets `during` act in the ending window, with a hold on at the
    /// time the pending Next would start. Returns the steps the chain ran.
    private func endingWindow(_ during: @escaping @MainActor (ChainRig) -> Void) async -> [SkipJob] {
        let r = ChainRig()
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        r.c.noteInterruptionEnded(shouldResume: true, mayAutoResume: true)
        await r.chain(resume: {
            r.gate = (false, true)
            during(r)
        })
        return r.jobs
    }

    func testACutAsNextInTheEndingWindowHasNoFreshNextPrivilegeUnderAHold() async {
        let jobs = await endingWindow { r in XCTAssertEqual(r.c.noteCutAsNext(from: 0), .beginWhenIdle) }
        XCTAssertEqual(jobs, [.advance], "the cut-derived Next must pass the hold gate")
    }

    func testTwoCutsInTheEndingWindowStillHaveNoFreshNextPrivilege() async {
        let jobs = await endingWindow { r in
            XCTAssertEqual(r.c.noteCutAsNext(from: 0), .beginWhenIdle)
            XCTAssertEqual(r.c.noteCutAsNext(from: 0), .beginWhenIdle)
        }
        XCTAssertEqual(jobs, [.advance])
    }

    func testAUserNextInTheEndingWindowKeepsItsPrivilegeUnderAHold() async {
        let jobs = await endingWindow { r in XCTAssertEqual(r.c.requestAdvance(), .beginWhenIdle) }
        XCTAssertEqual(jobs, [.advance, .advance], "a user Next may start while paused or held")
    }

    func testAUserNextAfterACutInTheEndingWindowTakesOverItsPrivilege() async {
        let jobs = await endingWindow { r in
            XCTAssertEqual(r.c.noteCutAsNext(from: 0), .beginWhenIdle)
            XCTAssertEqual(r.c.requestAdvance(), .beginWhenIdle)
        }
        XCTAssertEqual(jobs, [.advance, .advance], "the user pressed Next too: it is not only a cut")
    }

    func testACutAfterAUserNextInTheEndingWindowDoesNotTakeThePrivilegeAway() async {
        let jobs = await endingWindow { r in
            XCTAssertEqual(r.c.requestAdvance(), .beginWhenIdle)
            XCTAssertEqual(r.c.noteCutAsNext(from: 0), .beginWhenIdle)
        }
        XCTAssertEqual(jobs, [.advance, .advance])
    }

    // MARK: what a chain leaves behind when it exits

    func testAnOwedResumeIsSpentByTheChainThatRanIt() async {
        let r = ChainRig()
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        r.c.noteInterruptionEnded(shouldResume: true, mayAutoResume: true)
        await r.chain(resume: { r.resumes += 1 })
        XCTAssertEqual(r.resumes, 1)
        XCTAssertFalse(r.c.resumeOwed, "spent")
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        await r.chain(resume: { r.resumes += 1 })
        XCTAssertEqual(r.resumes, 1, "the next chain does not resume a second time")
    }

    func testAFollowUpStoredForACancelledStepDoesNotSurviveIntoARecovery() async {
        let r = ChainRig()
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        r.results = [.cancelled]
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance])
        XCTAssertEqual(r.c.noteLoadCut(target: 0), .recover)
        await r.recover()
        XCTAssertEqual(r.jobs, [.advance, .reload], "no Next was pressed: the recovery must not advance")
    }

    func testASealedChainDoesNotLeaveTheNextChainSealed() async {
        let r = ChainRig()
        XCTAssertEqual(r.c.requestAdvance(), .begin)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore)
        await r.chain()
        XCTAssertEqual(r.jobs, [.advance, .advance])
        XCTAssertEqual(r.c.noteLoadCut(target: 1), .recover)
        XCTAssertEqual(r.c.requestAdvance(), .queueOneMore, "a new chain may store its own follow-up")
    }
}
