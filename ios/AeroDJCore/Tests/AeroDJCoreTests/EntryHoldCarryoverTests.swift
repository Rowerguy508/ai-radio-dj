import XCTest
@testable import AeroDJCore

/// #585 (-Atlas): per-entry holds and flags must not leak into the next entry (or the next play of
/// the same entry): a user pause, an interruption, the interrupted-near-end flags, a seek baseline,
/// and the ended-entry guard. Each test sets the fact on one entry, moves on, and asserts the next
/// entry is judged on its own.
final class EntryHoldCarryoverTests: XCTestCase {
    private func sample(_ entry: String?, playing: Bool = false, _ position: TimeInterval?, duration: TimeInterval? = 200,
                        _ t: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(entryID: entry, isPlaying: playing, position: position, duration: entry == nil ? nil : duration, uptime: t)
    }

    private func play(_ d: inout PlaybackBoundaryDetector, _ entry: String, from: TimeInterval = 0, through: TimeInterval,
                      duration: TimeInterval = 200, _ t: inout TimeInterval) {
        for position in stride(from: from, through: through, by: 1.0) {
            _ = d.consume(sample(entry, playing: true, position, duration: duration, t))
            t += 1
        }
    }

    // MARK: a user pause does not hold the next entry

    func testAUserPauseDoesNotHoldTheNextEntry() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 30, &t)
        d.pausedByApp(.userPause)
        _ = d.consume(sample("song-1", playing: true, 0, duration: 3, t))
        t += 1
        XCTAssertEqual(d.consume(sample("song-1", 2.5, duration: 3, t)), .queueFinished(lastEntryID: "song-1"),
                       "song-1 was never paused: its stop at the end is its end")
    }

    // MARK: an interruption does not leak into the next entry

    func testAnInterruptionOnTheLastEntryDoesNotMakeTheNextEntrysSkipANaturalEnd() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 30, &t)
        d.pausedByApp(.systemInterruption)
        _ = d.consume(sample("song-1", playing: true, 30, t))
        t += 1
        XCTAssertNil(d.consume(sample(nil, nil, t)))
        XCTAssertTrue(d.takeRemoteSkip(), "song-1 was playing when the queue was cleared mid-song: a remote skip")
    }

    func testTheInterruptedNearEndFlagDoesNotCarryIntoTheNextEntry() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 195, &t)
        d.pausedByApp(.systemInterruption)
        XCTAssertTrue(d.interruptionBeganNearEnd, "the interruption began inside song-0's end window")
        d.pausedByApp(.userPause)
        _ = d.consume(sample("song-1", playing: true, 0, t))
        XCTAssertFalse(d.interruptionBeganNearEnd, "song-1 has had no interruption")
    }

    func testTheQueueFinishedUnderInterruptionFlagDoesNotCarryIntoTheNextQueue() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 97, duration: 100, &t)
        d.pausedByApp(.systemInterruption)
        XCTAssertEqual(d.consume(sample(nil, nil, t)), .queueFinished(lastEntryID: "song-0"))
        XCTAssertTrue(d.queueFinishedSinceInterruption, "MusicKit cleared the queue after the interruption")
        t += 1
        _ = d.consume(sample("song-1", playing: true, 0, t))
        XCTAssertFalse(d.queueFinishedSinceInterruption, "a new queue's first entry starts with no finish evidence")
    }

    // MARK: a new press or a seek clears the interrupted-near-end flags

    func testANewChangeClearsTheInterruptedNearEndFlag() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 195, &t)
        d.pausedByApp(.systemInterruption)
        XCTAssertTrue(d.interruptionBeganNearEnd)
        d.userRequestedChange()
        XCTAssertFalse(d.interruptionBeganNearEnd, "the app is changing what plays: the old interruption is not this song's")
    }

    func testASeekClearsTheInterruptedNearEndFlag() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 195, &t)
        d.pausedByApp(.systemInterruption)
        XCTAssertTrue(d.interruptionBeganNearEnd)
        d.userSeeked(to: 10, uptime: t)
        XCTAssertFalse(d.interruptionBeganNearEnd, "the user moved the playhead away from the end")
    }

    func testAReportedEndDoesNotMarkTheNextSongsInterruptionNearEnd() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 97, duration: 100, &t)
        XCTAssertEqual(d.consume(sample("song-0", 99, duration: 100, t)), .queueFinished(lastEntryID: "song-0"))
        d.userRequestedChange()
        t += 1
        play(&d, "song-1", through: 10, &t)
        d.pausedByApp(.systemInterruption)
        XCTAssertFalse(d.interruptionBeganNearEnd, "song-1 is 10 s in; song-0's reported end is not its end")
    }

    // MARK: a seek baseline does not leak into the next entry

    func testASeekBaselineDoesNotCarryIntoTheNextEntry() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 30, &t)
        d.userSeeked(to: 100, uptime: t)
        t += 5
        _ = d.consume(sample("song-1", playing: true, 0, t))
        t += 1
        _ = d.consume(sample("song-1", playing: true, 0.5, t))
        t += 1
        XCTAssertNil(d.consume(sample(nil, nil, t)))
        XCTAssertTrue(d.takeNoProgressEnd(), "song-1 never got going: the clear is refused as a failed start")
        XCTAssertFalse(d.takeRemoteSkip())
    }

    // MARK: the ended-entry guard does not outlive an entry change

    func testAnEntryChangeClearsTheEndedEntryGuard() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        play(&d, "song-0", through: 97, duration: 100, &t)
        XCTAssertEqual(d.consume(sample("song-0", 99, duration: 100, t)), .queueFinished(lastEntryID: "song-0"))
        t += 1
        play(&d, "song-1", through: 5, duration: 100, &t)
        play(&d, "song-0", from: 3, through: 97, duration: 100, &t)
        XCTAssertEqual(d.consume(sample("song-0", 99, duration: 100, t)), .queueFinished(lastEntryID: "song-0"),
                       "song-0 came back after another entry played: its end is reported again")
    }
}
