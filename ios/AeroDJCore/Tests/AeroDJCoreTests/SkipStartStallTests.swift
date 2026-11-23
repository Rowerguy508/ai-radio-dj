import XCTest
@testable import AeroDJCore

/// #586 (-Fry): after #585's one capped rewind cut, the skip path arms no #109 start-confirm
/// watchdog, so a cut target (C) that then also stalls at 0:00 was never reported. The detector now
/// watches that target itself and reports it once, after the same start-confirm deadline
/// (`PlaybackConfirmPolicy.deadlineSeconds`). The app routes the report through #109's
/// `reportTimeoutKeepPlayer` handling (`reportConfirmProblem(.confirmDeadline)`): a banner, the
/// transport kept out of `.playing`, the player never paused, a late `.playing` still confirms.
final class SkipStartStallTests: XCTestCase {
    private let deadline = PlaybackConfirmPolicy.deadlineSeconds

    /// Song 0 played 30 s, then a skip loaded song 1 and its `play()` returned.
    private func skipLoadedB() -> (BoundaryInterpreter, TimeInterval) {
        var b = BoundaryInterpreter()
        var t: TimeInterval = 100
        for position in stride(from: 0.0, through: 30.0, by: 1.0) {
            _ = b.interpret(sample("song-0", playing: true, position: position, t), queueIndex: 0, queueCount: 6)
            t += 1
        }
        loadSkipSong(&b)
        return (b, t)
    }

    /// The app's skip load (`startSkip` -> `startTrack`): open, the change, our `play()` returned.
    private func loadSkipSong(_ b: inout BoundaryInterpreter) {
        b.setSkipLoadInFlight(true)
        b.userRequestedChange()
        b.noteOwnPlayReturned()
    }

    /// B stalls at 0:00 past the window: #585's one capped rewind cut. The app advances to C
    /// through `startSkip` (no `noteUserSkip`), so the cap stays spent while C loads.
    private func cappedCutLoadsC() -> (BoundaryInterpreter, TimeInterval) {
        var (b, t) = skipLoadedB()
        var cuts = 0
        for _ in 0...Int(deadline) {
            XCTAssertNil(b.interpret(sample("song-1", playing: false, position: 0, t), queueIndex: 1, queueCount: 6))
            if b.takeSkipLoadCut() { cuts += 1 }
            XCTAssertFalse(b.takeSkipStartStalled(), "B's stall is the capped cut, never a start report too")
            t += 1
        }
        XCTAssertEqual(cuts, 1, "precondition: #585's one rewind cut")
        loadSkipSong(&b)
        return (b, t)
    }

    private func sample(_ entry: String?, playing: Bool, position: TimeInterval?, _ t: TimeInterval)
        -> PlaybackObservation {
        PlaybackObservation(entryID: entry, isPlaying: playing, position: position, duration: 200, uptime: t)
    }

    private struct Outcomes: Equatable {
        var reports = 0
        var cuts = 0
        var noProgressEnds = 0
        var remoteSkips = 0
        var boundaries = 0
    }

    /// One poll of `entry` and every one-shot the app's poll reads after it.
    private func poll(_ b: inout BoundaryInterpreter, _ entry: String?, playing: Bool = false,
                      position: TimeInterval? = 0, _ t: TimeInterval, into o: inout Outcomes) {
        if b.interpret(sample(entry, playing: playing, position: position, t), queueIndex: 2, queueCount: 6) != nil {
            o.boundaries += 1
        }
        if b.takeRemoteSkip() { o.remoteSkips += 1 }
        if b.takeSkipLoadCut() { o.cuts += 1 }
        if b.takeNoProgressEnd() { o.noProgressEnds += 1 }
        if b.takeSkipStartStalled() { o.reports += 1 }
    }

    func testCappedCutTargetStallingPastTheStartDeadlineIsReportedExactlyOnce() {
        var (b, t) = cappedCutLoadsC()
        var o = Outcomes()
        // Polls 1 s apart from the first stopped sample: nothing until the deadline.
        for _ in 0..<Int(deadline) {
            poll(&b, "song-2", t, into: &o)
            t += 1
        }
        XCTAssertEqual(o.reports, 0, "inside the slow-start allowance: no report")
        poll(&b, "song-2", t, into: &o)
        t += 1
        XCTAssertEqual(o.reports, 1, "at the start-confirm deadline: one report")
        for _ in 0..<40 {
            poll(&b, "song-2", t, into: &o)
            t += 1
        }
        XCTAssertEqual(o, Outcomes(reports: 1), "one report, and no cut, failed start, remote skip or boundary")
    }

    func testCappedCutTargetThatStartsInsideTheDeadlineIsNotReported() {
        var (b, t) = cappedCutLoadsC()
        var o = Outcomes()
        for _ in 0..<Int(deadline) {
            poll(&b, "song-2", t, into: &o)
            t += 1
        }
        for position in 1...5 {
            poll(&b, "song-2", playing: true, position: TimeInterval(position) * 0.5, t, into: &o)
            t += 1
        }
        XCTAssertEqual(o, Outcomes(), "a slow start that plays is never reported")
    }

    func testALatePlayingAfterTheReportNeverReportsAgain() {
        var (b, t) = cappedCutLoadsC()
        var o = Outcomes()
        for _ in 0...Int(deadline) {
            poll(&b, "song-2", t, into: &o)
            t += 1
        }
        XCTAssertEqual(o.reports, 1)
        poll(&b, "song-2", playing: true, position: 0.5, t, into: &o)
        t += 1
        poll(&b, "song-2", playing: true, position: 1.5, t, into: &o)
        t += 1
        XCTAssertEqual(o, Outcomes(reports: 1), "a late .playing just confirms; nothing more is reported")
    }

    /// #585's cap and this report never both fire: the uncapped load is the rewind cut's, only the
    /// capped target is watched for a start that never begins.
    func testAnUncappedSkipLoadStallIsOnlyTheRewindCut() {
        var (b, t) = skipLoadedB()
        var o = Outcomes()
        for _ in 0..<30 {
            poll(&b, "song-1", t, into: &o)
            t += 1
        }
        XCTAssertEqual(o, Outcomes(cuts: 1), "the rewind cut, never a start report too")
    }

    func testAUserSkipAfterTheCapGoesBackToTheRewindCutNotAReport() {
        var (b, t) = cappedCutLoadsC()
        var o = Outcomes()
        poll(&b, "song-2", t, into: &o)
        t += 1
        // The user presses Next (`skip()`): the cap resets before D's load.
        b.noteUserSkip()
        loadSkipSong(&b)
        for _ in 0..<30 {
            poll(&b, "song-3", t, into: &o)
            t += 1
        }
        XCTAssertEqual(o, Outcomes(cuts: 1), "D's stall is a rewind cut again, not a start report")
    }

    func testAHoldOnTheCappedTargetIsNeverReported() {
        for cause in [PlaybackBoundaryDetector.HoldCause.userPause, .routeLoss, .systemInterruption] {
            var (b, t) = cappedCutLoadsC()
            var o = Outcomes()
            poll(&b, "song-2", t, into: &o)
            t += 1
            b.pausedByApp(cause)
            for _ in 0..<30 {
                poll(&b, "song-2", t, into: &o)
                t += 1
            }
            XCTAssertEqual(o, Outcomes(), "\(cause): a held start is not a start that never began")
        }
    }

    func testANewAppChangeOrAClearEndsTheWatch() {
        do {
            var (b, t) = cappedCutLoadsC()
            var o = Outcomes()
            poll(&b, "song-2", t, into: &o)
            t += 1
            // The app replaced the queue (a tap, a new station): that load has its own start confirm.
            b.userRequestedChange()
            for _ in 0..<30 {
                poll(&b, "song-2", t, into: &o)
                t += 1
            }
            XCTAssertEqual(o.reports, 0, "a newer app change owns the start")
        }
        do {
            var (b, t) = cappedCutLoadsC()
            var o = Outcomes()
            poll(&b, "song-2", t, into: &o)
            t += 1
            poll(&b, nil, position: nil, t, into: &o)
            t += 1
            for _ in 0..<30 {
                poll(&b, "song-2", t, into: &o)
                t += 1
            }
            XCTAssertEqual(o.reports, 0, "a clear is decided by the clear checks, not this report")
        }
    }

    /// The report needs both timing facts; without them it never guesses.
    func testUnknownPositionOrUptimeIsNeverReported() {
        var (b, t) = cappedCutLoadsC()
        var o = Outcomes()
        for _ in 0..<30 {
            poll(&b, "song-2", position: nil, t, into: &o)
            t += 1
        }
        XCTAssertEqual(o.reports, 0)
    }

    /// The app side: the report goes through #109's report-only handling and nothing else. It does
    /// not arm the start-confirm watchdog on the skip path (#585's pin), and never pauses the player.
    func testMusicKitServiceRoutesAStalledSkipStartThroughTheConfirmDeadlineReport() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("AeroDJ/MusicKitService.swift"), encoding: .utf8)
        let poll = source.split(separator: "private func pollPlaybackPosition()").dropFirst().first
            .flatMap { $0.split(separator: "private func noteSkipLoadCut(").first }.map(String.init) ?? ""
        let block = poll.split(separator: "boundaries.takeSkipStartStalled()").dropFirst().first
            .flatMap { $0.split(separator: "return").first }.map(String.init) ?? ""
        XCTAssertFalse(block.isEmpty, "the poll reads the stalled skip start")
        XCTAssertTrue(block.contains("reportConfirmProblem(.confirmDeadline("), "same report as #109's deadline")
        XCTAssertFalse(block.contains("pause()"), "never pauses the player")
        XCTAssertFalse(block.contains("armPlaybackConfirmTimeout"))
        XCTAssertFalse(block.contains("skip()"), "never advances")
        // #109's deadline report: banner and timed-out flag, no pause, no advance, watchdog kept.
        let effect = StartFailurePolicy.effect(.confirmDeadline(last: .paused), attempt: PlaybackAttemptID(number: 1),
                                               current: PlaybackAttemptID(number: 1))
        XCTAssertFalse(effect.pausesPlayer)
        XCTAssertFalse(effect.advancesQueue)
        XCTAssertTrue(effect.events.contains(.startConfirmTimedOut))
        XCTAssertNotNil(effect.message)
    }
}
