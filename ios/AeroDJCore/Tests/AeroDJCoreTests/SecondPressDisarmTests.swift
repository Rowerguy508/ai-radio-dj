import XCTest
@testable import AeroDJCore

/// #585 (-Atlas): what a second press, a closed load, or a natural finish must do to the state the
/// first skip armed (the unobserved-clear report, the rewind watch, the capped-start report, the
/// ended-entry guard, the open skip load). Each test sets up the first skip, then the second event,
/// and asserts the detector reports nothing for the first one.
final class SecondPressDisarmTests: XCTestCase {
    private let window = PlaybackBoundaryDetector.rewoundBeforePlayingStallSeconds

    private func sample(_ entry: String?, playing: Bool = false, _ position: TimeInterval?, duration: TimeInterval? = 200,
                        _ t: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(entryID: entry, isPlaying: playing, position: position, duration: entry == nil ? nil : duration, uptime: t)
    }

    private func playSong0(_ d: inout PlaybackBoundaryDetector) -> TimeInterval {
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = d.consume(sample("song-0", playing: true, position, t))
            t += 1
        }
        return t
    }

    /// Rewind cut taken for song-1, the cap spent, the app reloads: the capped-start watch is armed.
    private func armedCappedWatch(_ d: inout PlaybackBoundaryDetector) -> TimeInterval {
        var t = playSong0(&d)
        d.setSkipLoadInFlight(true)
        d.userRequestedChange()
        d.noteOwnPlayReturned()
        _ = d.consume(sample("song-1", 0, t))
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertTrue(d.takeSkipLoadCut())
        d.userRequestedChange()
        d.setSkipLoadInFlight(true)
        d.noteOwnPlayReturned()
        return t + 1
    }

    // MARK: a second press disarms the first skip's reports

    func testASecondPressDisarmsTheUnobservedClearReport() {
        var d = PlaybackBoundaryDetector()
        var t = playSong0(&d)
        d.setSkipLoadInFlight(true)
        d.userRequestedChange()
        d.noteOwnPlayReturned()
        d.userRequestedChange()
        t += 1
        _ = d.consume(sample(nil, nil, t))
        XCTAssertNil(d.pendingSkipLoadCut, "the clear belongs to the second press, not to the first load")
        XCTAssertFalse(d.takeSkipLoadCut())
    }

    func testASecondPressDisarmsTheRewindWatchForTheFirstTarget() {
        var d = PlaybackBoundaryDetector()
        var t = playSong0(&d)
        d.setSkipLoadInFlight(true)
        d.userRequestedChange()
        d.noteOwnPlayReturned()
        d.userRequestedChange()
        _ = d.consume(sample("song-1", 0, t))
        t += window
        _ = d.consume(sample("song-1", 0, t))
        XCTAssertNil(d.pendingSkipLoadCut, "the first target's stall is not reported once a second press is in")
    }

    func testASecondPressDropsAnUntakenCappedStartReport() {
        var d = PlaybackBoundaryDetector()
        var t = armedCappedWatch(&d)
        _ = d.consume(sample("song-2", 0, t))
        t += window
        _ = d.consume(sample("song-2", 0, t))
        d.userRequestedChange()
        XCTAssertFalse(d.takeSkipStartStalled(), "a new press supersedes the untaken start-stall report")
    }

    func testAReplayAfterAReportedEndEndsOnceMore() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 97.0, by: 1.0) {
            _ = d.consume(sample("song-0", playing: true, position, duration: 100, t))
            t += 1
        }
        XCTAssertEqual(d.consume(sample("song-0", 99, duration: 100, t)), .queueFinished(lastEntryID: "song-0"))
        // The user replays the finished song: an app change, the old queue is cleared, and the same
        // song plays again from the start as a new queue's first entry.
        d.userRequestedChange()
        t += 1
        XCTAssertNil(d.consume(sample(nil, nil, t)))
        for position in stride(from: 0.0, through: 97.0, by: 1.0) {
            t += 1
            _ = d.consume(sample("song-0", playing: true, position, duration: 100, t))
        }
        t += 1
        XCTAssertEqual(d.consume(sample("song-0", 99, duration: 100, t)), .queueFinished(lastEntryID: "song-0"),
                       "the replay is a new play of the entry, so its end is reported again")
    }

    // MARK: a poll that already saw the song ends the unobserved-clear report

    func testAClearAfterAPollSawTheSongIsNotAnUnobservedClear() {
        var d = PlaybackBoundaryDetector()
        var t = playSong0(&d)
        d.setSkipLoadInFlight(true)
        d.userRequestedChange()
        _ = d.consume(sample("song-1", playing: true, 0.5, t))
        t += 1
        d.noteOwnPlayReturned()
        _ = d.consume(sample(nil, nil, t))
        XCTAssertEqual(d.pendingSkipLoadCut, SkipLoadCut(shape: .clear, targetSeenPlaying: true),
                       "a poll saw song-1 playing before the clear, so it is not a song never seen")
    }

    // MARK: a closed load ends the reports

    func testAClosedLoadEndsTheCappedStartWatch() {
        var d = PlaybackBoundaryDetector()
        var t = armedCappedWatch(&d)
        _ = d.consume(sample("song-2", 0, t))
        d.setSkipLoadInFlight(false)
        t += window
        _ = d.consume(sample("song-2", 0, t))
        XCTAssertFalse(d.takeSkipStartStalled(), "the caller closed the load; the capped start watch is over")
    }

    func testAClearAfterTheLoadClosedIsNotAnUnobservedClear() {
        var d = PlaybackBoundaryDetector()
        var t = playSong0(&d)
        d.setSkipLoadInFlight(true)
        d.userRequestedChange()
        d.noteOwnPlayReturned()
        d.setSkipLoadInFlight(false)
        t += 1
        _ = d.consume(sample(nil, nil, t))
        XCTAssertNil(d.pendingSkipLoadCut, "no skip load is open, so there is no load to report cut")
    }

    // MARK: a natural finish closes the open load

    func testANaturalFinishClosesAnOpenSkipLoad() {
        var d = PlaybackBoundaryDetector()
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 97.0, by: 1.0) {
            _ = d.consume(sample("song-0", playing: true, position, duration: 100, t))
            t += 1
        }
        d.setSkipLoadInFlight(true)
        XCTAssertEqual(d.consume(sample(nil, nil, t)), .queueFinished(lastEntryID: "song-0"))
        XCTAssertFalse(d.isSkipLoadInFlight, "the queue finished naturally; no skip load is still open")
    }
}
