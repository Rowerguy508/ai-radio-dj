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
}
