import XCTest
@testable import AeroDJCore

final class PlaybackIntentTests: XCTestCase {
    func testNothingResumesUntilTheUserPlays() {
        let i = PlaybackIntent()
        XCTAssertFalse(i.mayAutoResume)
    }

    func testUserPlayAllowsAutoResumeAfterABreak() {
        var i = PlaybackIntent()
        i.userPlay()
        XCTAssertTrue(i.mayAutoResume, "a cancelled or finished DJ break resumes the song the user wanted")
    }

    func testUserPauseDuringABreakBlocksResume() {
        var i = PlaybackIntent()
        i.userPlay()
        i.userPause()
        XCTAssertFalse(i.mayAutoResume, "pausing during narration must not restart music when speech ends")
    }

    func testCallWithoutShouldResumeStaysPaused() {
        var i = PlaybackIntent()
        i.userPlay()
        i.systemInterruptionBegan()
        i.systemInterruptionEnded(shouldResume: false)
        XCTAssertFalse(i.mayAutoResume)
    }

    func testCallWithShouldResumeResumesWhenUserWantedPlayback() {
        var i = PlaybackIntent()
        i.userPlay()
        i.systemInterruptionBegan()
        i.systemInterruptionEnded(shouldResume: true)
        XCTAssertTrue(i.mayAutoResume)
    }

    func testCallEndingWhileUserPausedDoesNotResume() {
        var i = PlaybackIntent()
        i.userPlay()
        i.systemInterruptionBegan()
        i.userPause()
        i.systemInterruptionEnded(shouldResume: true)
        XCTAssertFalse(i.mayAutoResume)
    }

    func testRouteRemovalHoldsUntilTheUserPlays() {
        var i = PlaybackIntent()
        i.userPlay()
        i.routeRemoved()
        XCTAssertFalse(i.mayAutoResume, "headphones unplugged must not blast the speaker")
        i.userPlay()
        XCTAssertTrue(i.mayAutoResume, "an explicit user play overrides the hold")
    }

    func testHeadphonesUnpluggedDuringACallStillHoldAfterTheCallEnds() {
        var i = PlaybackIntent()
        i.userPlay()
        i.systemInterruptionBegan()
        i.routeRemoved()
        i.systemInterruptionEnded(shouldResume: true)
        XCTAssertFalse(i.mayAutoResume, "a call ending must not release a route hold the user never cleared")
    }

    func testRouteRemovedBeforeACallAndCallEndingWithPermissionStillHolds() {
        var i = PlaybackIntent()
        i.userPlay()
        i.routeRemoved()
        i.systemInterruptionBegan()
        i.systemInterruptionEnded(shouldResume: true)
        XCTAssertFalse(i.mayAutoResume)
    }

    func testUserPlayClearsACallHoldAndARouteHoldTogether() {
        var i = PlaybackIntent()
        i.systemInterruptionBegan()
        i.routeRemoved()
        i.userPlay()
        XCTAssertTrue(i.mayAutoResume)
        XCTAssertFalse(i.pausedBySystem)
    }

    func testRapidBeganEndedSequenceFollowsTheLastEvent() {
        var i = PlaybackIntent()
        i.userPlay()
        i.systemInterruptionBegan()
        i.systemInterruptionEnded(shouldResume: false)
        i.systemInterruptionBegan()
        XCTAssertFalse(i.mayAutoResume, "a second call starting while the first held must keep playback paused")
        i.systemInterruptionEnded(shouldResume: true)
        XCTAssertTrue(i.mayAutoResume)
    }

    func testUserPauseWhileInterruptedStaysPausedEvenWhenTheCallAllowsResume() {
        var i = PlaybackIntent()
        i.userPlay()
        i.systemInterruptionBegan()
        i.userPause()
        i.systemInterruptionEnded(shouldResume: true)
        XCTAssertFalse(i.mayAutoResume)
        XCTAssertFalse(i.userWantsPlayback)
    }

    func testEndWithoutPermissionAfterUserPlayStillBlocksAutoResume() {
        var i = PlaybackIntent()
        i.userPlay()
        i.systemInterruptionBegan()
        i.systemInterruptionEnded(shouldResume: false)
        XCTAssertFalse(i.mayAutoResume, "the system did not grant resume, so only the user may restart playback")
        i.userPlay()
        XCTAssertTrue(i.mayAutoResume)
    }
}
