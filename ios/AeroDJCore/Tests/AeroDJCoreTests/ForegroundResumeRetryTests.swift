import XCTest
@testable import AeroDJCore

/// #304 R2 (-Atlas): a post-break resume that failed in the background is retried exactly once
/// when the app returns to the foreground, and never for a user who paused, stopped or moved on.
final class ForegroundResumeRetryTests: XCTestCase {
    private let failed = PlaybackAttemptID(number: 4)
    private let retry = PlaybackAttemptID(number: 5)
    private let generation = 7

    /// Backgrounded, and the post-break resume (attempt #4) threw there.
    private func failedInBackground() -> ForegroundResumeRetry {
        var policy = ForegroundResumeRetry()
        policy.sceneEnteredBackground()
        policy.attemptBegan(failed)
        XCTAssertEqual(policy.resumeFailed(attempt: failed, generation: generation, afterBreak: true),
                       .keepErrorRetryInForeground)
        return policy
    }

    // MARK: - One retry

    func testBackgroundFailureThenForegroundRetriesOnce() {
        var policy = failedInBackground()
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true),
                       .retryResume)
        policy.attemptBegan(retry)
        XCTAssertEqual(policy.retryAttempt, retry)
        XCTAssertNil(policy.pending)
        // A second foreground (no new failure) does not retry again.
        policy.sceneEnteredBackground()
        XCTAssertEqual(policy.sceneBecameActive(current: retry, generation: generation, mayAutoResume: true), .none)
    }

    func testFailedRetryIsFinalAndKeepsTheError() {
        var policy = failedInBackground()
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true),
                       .retryResume)
        policy.attemptBegan(retry)
        XCTAssertEqual(policy.resumeFailed(attempt: retry, generation: generation, afterBreak: false), .keepError)
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.retryAttempt)
        // Still final if the app goes to the background and back.
        policy.sceneEnteredBackground()
        XCTAssertEqual(policy.sceneBecameActive(current: retry, generation: generation, mayAutoResume: true), .none)
    }

    func testRetryThatFailsInTheBackgroundAgainIsNotArmedAgain() {
        var policy = failedInBackground()
        _ = policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true)
        policy.attemptBegan(retry)
        policy.sceneEnteredBackground()
        XCTAssertEqual(policy.resumeFailed(attempt: retry, generation: generation, afterBreak: true), .keepError)
        XCTAssertEqual(policy.sceneBecameActive(current: retry, generation: generation, mayAutoResume: true), .none)
    }

    func testConfirmedRetryClearsTheErrorOnce() {
        var policy = failedInBackground()
        _ = policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true)
        policy.attemptBegan(retry)
        XCTAssertFalse(policy.confirmed(failed))
        XCTAssertTrue(policy.confirmed(retry))
        XCTAssertFalse(policy.confirmed(retry))
    }

    func testRetryThatNeverBeganLeavesNothingBehind() {
        var policy = failedInBackground()
        _ = policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true)
        policy.retryReturned()
        // The next start is ordinary, not the retry.
        policy.attemptBegan(retry)
        XCTAssertNil(policy.retryAttempt)
        XCTAssertFalse(policy.confirmed(retry))
    }

    // MARK: - The user moved on

    func testUserPauseClearsThePendingRetry() {
        var policy = failedInBackground()
        policy.userIntervened()
        XCTAssertNil(policy.pending)
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true), .none)
    }

    func testNewQueueClearsThePendingRetry() {
        var policy = failedInBackground()
        // `play(_:)` reports the intervention and begins a new start.
        policy.userIntervened()
        policy.attemptBegan(retry)
        XCTAssertEqual(policy.sceneBecameActive(current: retry, generation: generation + 1, mayAutoResume: true), .none)
        XCTAssertNil(policy.retryAttempt)
    }

    func testAnyNewStartClearsThePendingRetry() {
        var policy = failedInBackground()
        policy.attemptBegan(retry)
        XCTAssertNil(policy.pending)
        XCTAssertEqual(policy.sceneBecameActive(current: retry, generation: generation, mayAutoResume: true), .none)
    }

    func testSupersededAttemptDropsTheRetry() {
        var policy = failedInBackground()
        // Stop after the deadline leaves no current attempt.
        XCTAssertEqual(policy.sceneBecameActive(current: nil, generation: generation, mayAutoResume: true),
                       .dropped(.attemptSuperseded))
        XCTAssertFalse(policy.retryRequested)
    }

    func testChangedQueueGenerationDropsTheRetry() {
        var policy = failedInBackground()
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation + 1, mayAutoResume: true),
                       .dropped(.queueChanged))
        XCTAssertFalse(policy.retryRequested)
    }

    func testNoAutoResumeDropsTheRetry() {
        var policy = failedInBackground()
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: false),
                       .dropped(.mayNotAutoResume))
        XCTAssertFalse(policy.retryRequested)
        // Consumed: a later foreground does not retry.
        policy.sceneEnteredBackground()
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true), .none)
    }

    // MARK: - Nothing to retry

    func testForegroundWithNoPriorFailureDoesNothing() {
        var policy = ForegroundResumeRetry()
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true), .none)
        policy.sceneEnteredBackground()
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true), .none)
        XCTAssertFalse(policy.retryRequested)
        XCTAssertNil(policy.retryAttempt)
    }

    func testForegroundFailureDoesNotArmARetry() {
        var policy = ForegroundResumeRetry()
        policy.attemptBegan(failed)
        XCTAssertEqual(policy.resumeFailed(attempt: failed, generation: generation, afterBreak: true), .keepError)
        XCTAssertNil(policy.pending)
    }

    func testBackgroundFailureNotAfterABreakDoesNotArmARetry() {
        var policy = ForegroundResumeRetry()
        policy.sceneEnteredBackground()
        policy.attemptBegan(failed)
        XCTAssertEqual(policy.resumeFailed(attempt: failed, generation: generation, afterBreak: false), .keepError)
        XCTAssertEqual(policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true), .none)
    }

    // MARK: - Which resume is post-break

    func testOnlyTheResumeRightAfterABreakIsPostBreak() {
        var policy = ForegroundResumeRetry()
        XCTAssertFalse(policy.takeBreakResume(), "an interruption resume with no break")
        policy.breakEnded(resumesMusic: true)
        XCTAssertTrue(policy.takeBreakResume())
        XCTAssertFalse(policy.takeBreakResume(), "consumed by the first resume")
        policy.breakEnded(resumesMusic: false)
        XCTAssertFalse(policy.takeBreakResume(), "a break that does not resume music")
    }

    func testANewStartOrAPauseForgetsTheEndedBreak() {
        var policy = ForegroundResumeRetry()
        policy.breakEnded(resumesMusic: true)
        policy.attemptBegan(failed)
        XCTAssertFalse(policy.takeBreakResume())
        policy.breakEnded(resumesMusic: true)
        policy.userIntervened()
        XCTAssertFalse(policy.takeBreakResume())
    }

    func testTheRetryItselfIsNotAPostBreakResume() {
        var policy = failedInBackground()
        _ = policy.sceneBecameActive(current: failed, generation: generation, mayAutoResume: true)
        XCTAssertFalse(policy.takeBreakResume())
        policy.attemptBegan(retry)
        XCTAssertEqual(policy.retryAttempt, retry)
    }
}
