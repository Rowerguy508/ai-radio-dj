import XCTest
@testable import AeroDJCore

/// Build 10 P0 on the Duo, from the overlay: session.setActive at 151 ms, interruption.began
/// (shouldResume=false) at 152 ms, play.returned status=paused at 232 ms, start refused.
/// These replay that interleaving through the same policies the app uses. -Atlas
final class Build10SessionOwnerTests: XCTestCase {
    private let songs = [
        TrackInfo(id: "s0", title: "Zero", artistName: "A", artworkURL: nil),
        TrackInfo(id: "s1", title: "One", artistName: "A", artworkURL: nil),
    ]

    /// The app no longer activates its own session before or around `play()`.
    func testPlaybackDoesNotActivateTheAppSession() {
        XCTAssertFalse(AudioSessionActivation.shouldActivate(during: .playback))
    }

    /// Race: an interruption lands after the tap and before `play()` returns. This is why the
    /// #120 spinner and Stop never showed: the interruption moved `.preparing` to `.paused` at
    /// 152 ms, long before the 8 s deadline, and the refusal then raised nothing.
    func testInterruptionBeforePlayReturnsLeavesPreparingAndNowSaysWhy() {
        var session = AudioSessionPolicy()
        var attempts = PlaybackAttempts()
        var engine = PlaybackEngine()

        // Tap.
        session.userPlay()
        let tap = attempts.beginStart()
        engine.apply(.queueStarted(tracks: songs, startIndex: 0, station: nil))
        XCTAssertEqual(engine.snapshot.transport, .preparing, "spinner state")

        // interruption.began shouldResume=false, while play() is in flight.
        XCTAssertEqual(session.handle(.interruptionBegan, breakIsActive: false), .suspendPlayback)
        engine.apply(.interruptionPaused)
        XCTAssertEqual(engine.snapshot.transport, .paused, "spinner gone at ~152 ms; no deadline is ever reached")
        XCTAssertFalse(engine.snapshot.startTimedOut, "so Stop never appears either")

        // play() returns paused; the hold gate refuses.
        XCTAssertEqual(PlaybackStartGuard.afterPlay(mayAutoResume: session.mayAutoResume,
                                                    userWantsPlayback: session.userWantsPlayback),
                       .pauseBecauseHeld)
        let effect = StartFailurePolicy.effect(.refused(pausedBySystem: session.pausedBySystem),
                                               attempt: tap, current: attempts.current)
        for event in effect.events { engine.apply(event) }
        XCTAssertNotNil(effect.message, "the refusal is visible, not a silent return to Play")
        XCTAssertEqual(engine.snapshot.error?.kind, .playbackFailed)
        XCTAssertEqual(engine.snapshot.transport, .paused)
        XCTAssertEqual(engine.snapshot.nowPlaying?.id, "s0", "still on the tapped song")
        XCTAssertFalse(effect.advancesQueue)
        XCTAssertFalse(effect.pausesPlayer)
    }

    /// The retry at 6836 ms: interruption.ended then a Play tap. The tap clears the system hold,
    /// so with no self-inflicted interruption the start is allowed through.
    func testRetryTapAfterTheInterruptionEndsIsAllowed() {
        var session = AudioSessionPolicy()
        session.userPlay()
        session.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(session.handle(.interruptionEnded(shouldResume: false), breakIsActive: false), .none,
                       "shouldResume=false never auto-resumes")
        XCTAssertFalse(session.mayAutoResume)
        session.userPlay()
        XCTAssertTrue(session.mayAutoResume)
        XCTAssertEqual(PlaybackStartGuard.afterPlay(mayAutoResume: session.mayAutoResume,
                                                    userWantsPlayback: session.userWantsPlayback),
                       .keepPlaying)
    }

    /// A user refusal (not a system hold) stays quiet, as before.
    func testUserRefusalStillRaisesNothing() {
        var attempts = PlaybackAttempts()
        let a = attempts.beginStart()
        let effect = StartFailurePolicy.effect(.refused(pausedBySystem: false), attempt: a, current: attempts.current)
        XCTAssertNil(effect.message)
        XCTAssertEqual(effect.events, [.userPaused])
    }
}
