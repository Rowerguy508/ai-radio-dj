import XCTest
@testable import AeroDJCore

/// Build 9: a tapped song must stay on the station that was opened, and a start
/// that never gets going must not be paused by the poll or skipped ahead.
final class Build9NoAudioTests: XCTestCase {
    func testUserTapRecordsIntentAndPollDoesNotPauseIt() {
        var tap = AudioSessionPolicy()
        tap.userPlay()
        XCTAssertTrue(tap.userWantsPlayback)
        XCTAssertFalse(tap.pausedBySystem)
        XCTAssertEqual(
            RemotePlayGate.admit(mayAutoResume: tap.mayAutoResume, userWantsPlayback: tap.userWantsPlayback),
            .keepPlaying,
            "play() and resume() both call userPlay before the poll")

        var call = AudioSessionPolicy()
        call.userPlay()
        _ = call.handle(.interruptionBegan, breakIsActive: false)
        XCTAssertEqual(
            RemotePlayGate.admit(mayAutoResume: call.mayAutoResume, userWantsPlayback: call.userWantsPlayback),
            .pauseBecauseHeld,
            "a call hold still pauses")

        var unplug = AudioSessionPolicy()
        unplug.userPlay()
        _ = unplug.handle(.routeChange(deviceRemoved: true), breakIsActive: false)
        XCTAssertEqual(
            RemotePlayGate.admit(mayAutoResume: unplug.mayAutoResume, userWantsPlayback: unplug.userWantsPlayback),
            .pauseBecauseHeld,
            "an unplug still pauses")
    }

    func testSpeechPrepDoesNotActivateTheSharedSession() {
        XCTAssertFalse(SpeechPrepSession.usesApplicationAudioSession)
        XCTAssertFalse(SpeechPrepSession.activatesSharedSession(
            usesApplicationAudioSession: SpeechPrepSession.usesApplicationAudioSession,
            setsCategory: false,
            setsActive: false))
        XCTAssertTrue(SpeechPrepSession.activatesSharedSession(
            usesApplicationAudioSession: true, setsCategory: false, setsActive: false))
        XCTAssertTrue(SpeechPrepSession.activatesSharedSession(
            usesApplicationAudioSession: false, setsCategory: false, setsActive: true))
    }

    func testFailedStartDoesNotSkip() {
        var boundary = BoundaryInterpreter()
        let stuck = PlaybackObservation(entryID: "a", isPlaying: true, position: 0, duration: 200)
        XCTAssertNil(boundary.interpret(stuck, queueIndex: 0, queueCount: 4))
        let jumped = PlaybackObservation(entryID: "b", isPlaying: true, position: 0, duration: 200)
        let step = boundary.interpret(jumped, queueIndex: 0, queueCount: 4)
        XCTAssertNil(step, "a start at 0:00 is not a natural end")
        XCTAssertTrue(FailedStartReport.shouldReport(step: step, noProgress: boundary.takeNoProgressEnd()))
        XCTAssertFalse(boundary.takeNoProgressEnd())

        var played = BoundaryInterpreter()
        _ = played.interpret(PlaybackObservation(entryID: "a", isPlaying: true, position: 0, duration: 200),
                             queueIndex: 0, queueCount: 4)
        _ = played.interpret(PlaybackObservation(entryID: "a", isPlaying: true, position: 40, duration: 200),
                             queueIndex: 0, queueCount: 4)
        XCTAssertEqual(
            played.interpret(PlaybackObservation(entryID: "b", isPlaying: true, position: 0, duration: 200),
                             queueIndex: 0, queueCount: 4),
            .advancedEntry(finishedIndex: 0, boundary: .naturalEnd(finishedEntryID: "a")))
        XCTAssertFalse(played.takeNoProgressEnd())
    }

    func testSongTapKeepsTheOpenedStation() {
        var opened = OpenedStation()
        let calm = StationRef(id: "morning-calm", name: "Morning Calm")
        let late = StationRef(id: "late-night", name: "Late Night")
        opened.open(calm)
        XCTAssertEqual(opened.stationForSongTap(), calm)
        XCTAssertEqual(opened.stationForSongTap(), calm, "a second song tap still plays Morning Calm")
        opened.open(late)
        XCTAssertEqual(opened.stationForSongTap(), late, "only an explicit station open changes it")
    }
}
