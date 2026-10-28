import XCTest
@testable import AeroDJCore

/// Build 16 P0 (-Atlas): song 1 of a one-song-at-a-time queue ends naturally, and song 2 must be
/// loaded, with a break and without one. MusicKit may keep the entry and rewind its playhead.
final class SongEndAdvanceTests: XCTestCase {
    private func obs(_ id: String?, playing: Bool, at position: Double? = nil) -> PlaybackObservation {
        PlaybackObservation(entryID: id, isPlaying: playing, position: position, duration: id == nil ? nil : 200)
    }

    /// Feeds song 1's polls and returns the step for its end, plus the attempts after `armNext`.
    private func endSong1(final: PlaybackObservation) -> (BoundaryStep?, PlaybackAttempts) {
        var boundaries = BoundaryInterpreter()
        var attempts = PlaybackAttempts()
        attempts.beginStart()
        for t in stride(from: 0.0, through: 199.0, by: 1.0) {
            XCTAssertNil(boundaries.interpret(obs("s1", playing: true, at: t), queueIndex: 0, queueCount: 3))
        }
        let step = boundaries.interpret(final, queueIndex: 0, queueCount: 3)
        if case let .plannedHandoff(finished, _, _)? = step { attempts.armNext(after: finished) }
        return (step, attempts)
    }

    private let handoff = BoundaryStep.plannedHandoff(
        finishedIndex: 0, nextIndex: 1, boundary: .naturalEnd(finishedEntryID: "s1"))

    func testKeptEntryRewoundToZeroIsStillTheEndOfSong1() {
        let (step, _) = endSong1(final: obs("s1", playing: false, at: 0))
        XCTAssertEqual(step, handoff, "a rewound playhead must not hide the end of song 1")
    }

    func testKeptEntryStoppedAtItsEndIsTheEndOfSong1() {
        XCTAssertEqual(endSong1(final: obs("s1", playing: false, at: 200)).0, handoff)
    }

    func testClearedEntryIsTheEndOfSong1() {
        XCTAssertEqual(endSong1(final: obs(nil, playing: false)).0, handoff)
    }

    /// Without a break PlayerView calls `startNextTrack(after: 0)` straight away.
    func testSong2LoadsWithoutABreak() {
        var (step, attempts) = endSong1(final: obs("s1", playing: false, at: 0))
        XCTAssertEqual(step, handoff)
        XCTAssertEqual(BreakHandoffPolicy.decide(prepared: nil), .continueMusic)
        XCTAssertTrue(attempts.takeNext(after: 0), "song 2 must load")
        XCTAssertFalse(attempts.takeNext(after: 0), "and only once")
    }

    /// With a break the start waits for it; a new attempt for the break does not cancel song 2.
    func testSong2LoadsAfterABreak() {
        var (step, attempts) = endSong1(final: obs("s1", playing: false, at: 0))
        XCTAssertEqual(step, handoff)
        attempts.beginStart() // any non-user start during the break, e.g. a resume
        XCTAssertTrue(attempts.takeNext(after: 0), "song 2 must load after the break")
    }

    /// A user pause in the last second is still not an end, with the furthest-position check.
    func testUserPauseAtTheVeryEndIsNotAnEnd() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("s1", playing: true, at: 199))
        d.pausedByApp(.userPause)
        XCTAssertNil(d.consume(obs("s1", playing: false, at: 199)))
    }

    /// A stop mid-song that later reads position 0 is not an end: the furthest point was mid-song.
    func testStopMidSongThenRewindIsNotAnEnd() {
        var d = PlaybackBoundaryDetector()
        _ = d.consume(obs("s1", playing: true, at: 90))
        XCTAssertNil(d.consume(obs("s1", playing: false, at: 0)))
    }
}
