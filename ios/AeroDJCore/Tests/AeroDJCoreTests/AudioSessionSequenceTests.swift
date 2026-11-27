import XCTest
@testable import AeroDJCore

/// #195 (-Fry): session notice sequences that `AudioReliabilityTests` and `SongEndInterruptionTests`
/// did not pin at e6e45842. Each one is a rule that keeps music from starting when the user or
/// the system did not allow it. Policy only: these do not prove MusicKit or a real phone.
final class AudioSessionSequenceTests: XCTestCase {
    private func playing() -> AudioSessionPolicy {
        var p = AudioSessionPolicy()
        p.userPlay()
        return p
    }

    /// A user pause during a call is not undone when the call ends with permission to resume.
    func testUserPauseDuringACallSurvivesTheCallEnding() {
        var p = playing()
        XCTAssertEqual(p.handle(.interruptionBegan, breakIsActive: false), .suspendPlayback)
        XCTAssertEqual(p.userPause(), .suspendPlayback)
        XCTAssertEqual(p.handle(.interruptionEnded(shouldResume: true), breakIsActive: false), .none)
        XCTAssertFalse(p.mayAutoResume)
        XCTAssertFalse(p.pausedBySystem, "the call's hold is gone; only the user's pause remains")
    }

    /// A route that appears or changes (Bluetooth connects, AirPlay picks a speaker) never starts
    /// music and never clears a call or headphone hold.
    func testANonRemovalRouteChangeNeitherResumesNorClearsAHold() {
        var held = playing()
        _ = held.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(held.handle(.routeChanged(.other), breakIsActive: false), .none)
        XCTAssertTrue(held.pausedBySystem)

        var unplugged = playing()
        _ = unplugged.handle(.routeChanged(.oldDeviceUnavailable), breakIsActive: false)
        XCTAssertEqual(unplugged.handle(.routeChanged(.other), breakIsActive: false), .none, "plugging back in")
        XCTAssertFalse(unplugged.mayAutoResume)

        var paused = playing()
        _ = paused.userPause()
        XCTAssertEqual(paused.handle(.routeChanged(.other), breakIsActive: false), .none)
        XCTAssertFalse(paused.mayAutoResume)
    }

    /// Headphones pulled while the DJ is speaking: speech stops and music does not come back
    /// when the break ends.
    func testHeadphonesRemovedDuringABreakHoldAfterTheBreak() {
        var p = playing()
        XCTAssertEqual(p.handle(.routeChanged(.oldDeviceUnavailable), breakIsActive: true), .suspendPlayback)
        let after = NarrationResumePolicy.decide(.finished, mayAutoResume: p.mayAutoResume, phase: .voice)
        XCTAssertFalse(after.resumeMusic)
    }

    /// A call that begins while the DJ is speaking suspends the break at once.
    func testACallDuringABreakSuspendsAtOnce() {
        var p = playing()
        XCTAssertEqual(p.handle(.interruptionBegan, breakIsActive: true), .suspendPlayback)
        XCTAssertTrue(p.interruptionOngoing)
        XCTAssertFalse(p.mayAutoResume)
    }

    /// An end with no matching begin (the system can send one after launch) never starts music
    /// the user did not ask for, and never undoes a pause.
    func testAStrayEndNeverStartsMusic() {
        var fresh = AudioSessionPolicy()
        XCTAssertEqual(fresh.handle(.interruptionEnded(shouldResume: true), breakIsActive: false), .none)
        XCTAssertFalse(fresh.mayAutoResume)

        var paused = playing()
        _ = paused.userPause()
        XCTAssertEqual(paused.handle(.interruptionEnded(shouldResume: true), breakIsActive: false), .none)
        XCTAssertFalse(paused.mayAutoResume)
    }

    /// An end without `shouldResume` holds until the user presses play; that play clears it, and a
    /// later route change does not bring the hold back.
    func testUserPlayClearsAHoldTheSystemDidNotReturn() {
        var p = playing()
        _ = p.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(p.handle(.interruptionEnded(shouldResume: false), breakIsActive: false), .none)
        XCTAssertTrue(p.pausedBySystem)
        p.userPlay()
        XCTAssertTrue(p.mayAutoResume)
        XCTAssertEqual(p.handle(.routeChanged(.other), breakIsActive: false), .none)
        XCTAssertTrue(p.mayAutoResume)
    }

    /// Two begins before one end (a call while Siri is up) leave one hold, released by one end.
    func testOverlappingBeginsNeedOnlyOneEnd() {
        var p = playing()
        _ = p.handle(.interruptionBegan, breakIsActive: false)
        _ = p.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(p.handle(.interruptionEnded(shouldResume: true), breakIsActive: false), .resumeIfPermitted)
        XCTAssertFalse(p.interruptionOngoing)
    }

    /// A call that ends with permission while headphones are unplugged still holds: only the user
    /// clears a route hold, and the song-end hook does not either.
    func testCallEndingWhileUnpluggedStillHoldsAtTheSongEnd() {
        var p = playing()
        _ = p.handle(.interruptionBegan, breakIsActive: false)
        _ = p.handle(.routeChanged(.oldDeviceUnavailable), breakIsActive: false)
        XCTAssertEqual(p.handle(.interruptionEnded(shouldResume: true), breakIsActive: false), .none)
        XCTAssertFalse(p.naturalEndReached(interruptionBeganNearEnd: true, queueFinishedSinceInterruption: true,
                                           otherAudioPlaying: false, secondaryHint: false, callActive: false))
        XCTAssertFalse(p.mayAutoResume)
    }

    /// The song-end hook is a no-op for an interruption that did not begin near the end, even when
    /// MusicKit finished the queue afterwards.
    func testMidSongInterruptionIsNotReleasedAtTheSongEnd() {
        var p = playing()
        _ = p.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertFalse(p.naturalEndReached(interruptionBeganNearEnd: false, queueFinishedSinceInterruption: true,
                                           otherAudioPlaying: false, secondaryHint: false, callActive: false))
        XCTAssertTrue(p.pausedBySystem)
    }
}
