import XCTest
@testable import AeroDJCore

/// Build 9 no-audio P0, transport proofs for #120 (-Atlas). Covers #113 and #116: the #109
/// confirm watchdog cannot kill a buffering start, a failed start never skips, and a late
/// result of an older start (watchdog, throw, refusal, boundary) cannot touch a newer one.
/// Deterministic: status sequences and generations, no sleeps and no clocks. Logic only, so
/// these do not prove audio on the device; a TestFlight run on the Duo decides "fixed".
final class P0TransportAttemptTests: XCTestCase {
    // MARK: Helpers

    /// Feeds one status per 0.5 s poll and returns every step, stopping when the watchdog stops.
    private func run(_ statuses: [ConfirmStatus], preparing: [Bool]? = nil,
                     attempt: PlaybackAttemptID, current: (Int) -> PlaybackAttemptID?) -> [ConfirmStep] {
        var watchdog = PlaybackConfirmWatchdog(attempt: attempt)
        var steps: [ConfirmStep] = []
        for (i, status) in statuses.enumerated() where !watchdog.isFinished {
            steps.append(watchdog.observe(status: status,
                                          transportIsPreparing: preparing?[i] ?? true,
                                          currentAttempt: current(i)))
        }
        return steps
    }

    private func onlyAttempt() -> (PlaybackAttempts, PlaybackAttemptID) {
        var attempts = PlaybackAttempts()
        let a = attempts.beginStart()
        return (attempts, a)
    }

    private let threeSongs = [
        TrackInfo(id: "s0", title: "Zero", artistName: "A", artworkURL: nil),
        TrackInfo(id: "s1", title: "One", artistName: "A", artworkURL: nil),
        TrackInfo(id: "s2", title: "Two", artistName: "A", artworkURL: nil),
    ]

    /// Applies a failure's events to an engine that just started `threeSongs` at index 0.
    private func engineAfter(_ effect: StartFailureEffect) -> PlaybackSnapshot {
        var engine = PlaybackEngine()
        engine.apply(.queueStarted(tracks: threeSongs, startIndex: 0, station: nil))
        for event in effect.events { engine.apply(event) }
        return engine.snapshot
    }

    // MARK: Watchdog: a buffering start is never killed

    /// 15 `.paused` reads then `.playing` at poll 16: confirmed, nothing reported.
    func testFifteenPausedThenPlayingConfirms() {
        let (attempts, a) = onlyAttempt()
        let steps = run(Array(repeating: .paused, count: 15) + [.playing], attempt: a) { _ in attempts.current }
        XCTAssertEqual(steps, Array(repeating: .keepWaiting, count: 15) + [.confirmed])
    }

    /// 16 `.paused` reads: the deadline reports once, the player is not paused, and the
    /// watchdog keeps watching. 4 more `.paused` reads stay quiet.
    func testSixteenPausedReportsOnceAndKeepsWatching() {
        let (attempts, a) = onlyAttempt()
        var watchdog = PlaybackConfirmWatchdog(attempt: a)
        var steps: [ConfirmStep] = []
        for _ in 0..<20 {
            steps.append(watchdog.observe(status: .paused, transportIsPreparing: true, currentAttempt: attempts.current))
        }
        XCTAssertEqual(steps.filter { $0 == .reportTimeoutKeepPlayer }.count, 1)
        XCTAssertEqual(steps[15], .reportTimeoutKeepPlayer)
        XCTAssertFalse(watchdog.isFinished)
        XCTAssertTrue(watchdog.reported)
        XCTAssertFalse(steps.contains { PlaybackConfirmPolicy.pausesPlayer($0) })
    }

    /// Fry's case: a stream buffering past 8 s on cellular starts at poll 24. The same attempt
    /// is confirmed, and `reported` tells the app to clear the timeout error.
    func testLatePlayingAfterTheDeadlineConfirmsTheSameAttempt() {
        let (attempts, a) = onlyAttempt()
        let statuses: [ConfirmStatus] = Array(repeating: .paused, count: 23) + [.playing]
        var watchdog = PlaybackConfirmWatchdog(attempt: a)
        var steps: [ConfirmStep] = []
        for s in statuses { steps.append(watchdog.observe(status: s, transportIsPreparing: true, currentAttempt: attempts.current)) }
        XCTAssertEqual(steps[15], .reportTimeoutKeepPlayer)
        XCTAssertEqual(steps.last, .confirmed)
        XCTAssertTrue(watchdog.reported, "the app clears the reported error on this confirm")
        XCTAssertEqual(watchdog.result, .confirmed)
    }

    /// A late `.playing` after the deadline does not confirm an attempt a second tap replaced.
    func testLatePlayingDoesNotConfirmASupersededAttempt() {
        var attempts = PlaybackAttempts()
        let first = attempts.beginStart()
        var watchdog = PlaybackConfirmWatchdog(attempt: first)
        for _ in 0..<16 { _ = watchdog.observe(status: .paused, transportIsPreparing: true, currentAttempt: attempts.current) }
        XCTAssertTrue(watchdog.reported)
        let second = attempts.beginStart()
        XCTAssertEqual(watchdog.observe(status: .playing, transportIsPreparing: true, currentAttempt: attempts.current), .superseded)
        XCTAssertEqual(watchdog.observe(status: .playing, transportIsPreparing: true, currentAttempt: attempts.current), .stopWaiting)
        XCTAssertEqual(StartFailurePolicy.effect(.confirmDeadline(last: .paused), attempt: first, current: attempts.current), .none)
        XCTAssertTrue(attempts.isCurrent(second))
    }

    /// `.stopped` reads while buffering are not a failure either.
    func testStoppedReadsThenPlayingConfirms() {
        let (attempts, a) = onlyAttempt()
        let steps = run([.stopped, .stopped, .paused, .stopped, .seeking, .playing], attempt: a) { _ in attempts.current }
        XCTAssertEqual(steps, [.keepWaiting, .keepWaiting, .keepWaiting, .keepWaiting, .keepWaiting, .confirmed])
    }

    /// `.interrupted` is the only early report, and it does not pause either. A later
    /// `.playing` still confirms the attempt.
    func testInterruptedReportsEarlyThenLatePlayingConfirms() {
        let (attempts, a) = onlyAttempt()
        let steps = run([.interrupted, .interrupted, .paused, .playing], attempt: a) { _ in attempts.current }
        XCTAssertEqual(steps, [.failInterrupted, .keepWaiting, .keepWaiting, .confirmed])
    }

    /// The transport left `.preparing` (user pause, refusal): the watchdog stops and reports nothing.
    func testTransportLeftPreparingStopsTheWatchdog() {
        let (attempts, a) = onlyAttempt()
        let steps = run([.paused, .paused, .paused] + Array(repeating: .paused, count: 20),
                        preparing: [true, true, false] + Array(repeating: false, count: 20),
                        attempt: a) { _ in attempts.current }
        XCTAssertEqual(steps, [.keepWaiting, .keepWaiting, .stopWaiting])
    }

    /// #113 / #116 race: a second tap at poll 10 supersedes the first watchdog. The stale
    /// watchdog stops before its deadline and never reports against the new attempt, and the
    /// new attempt's own watchdog runs its full 8 s from its own start.
    func testSecondTapCancelsTheFirstWatchdogAndTheNewAttemptGetsItsOwnDeadline() {
        var attempts = PlaybackAttempts()
        let first = attempts.beginStart()
        var old = PlaybackConfirmWatchdog(attempt: first)
        for _ in 0..<10 { XCTAssertEqual(old.observe(status: .paused, transportIsPreparing: true, currentAttempt: attempts.current), .keepWaiting) }
        let second = attempts.beginStart()
        var new = PlaybackConfirmWatchdog(attempt: second)
        // Both keep receiving `.paused` (the new song is buffering). The old one would have hit
        // its deadline at its poll 16, i.e. the new attempt's poll 6.
        var oldSteps: [ConfirmStep] = []
        var newSteps: [ConfirmStep] = []
        for _ in 0..<15 {
            oldSteps.append(old.observe(status: .paused, transportIsPreparing: true, currentAttempt: attempts.current))
            newSteps.append(new.observe(status: .paused, transportIsPreparing: true, currentAttempt: attempts.current))
        }
        XCTAssertEqual(oldSteps.first, .superseded)
        XCTAssertFalse(oldSteps.contains(.reportTimeoutKeepPlayer))
        XCTAssertEqual(newSteps, Array(repeating: .keepWaiting, count: 15), "no report before the new attempt's own 8 s")
        XCTAssertEqual(new.observe(status: .playing, transportIsPreparing: true, currentAttempt: attempts.current), .confirmed)
    }

    // MARK: A failed start never skips

    func testEveryStartFailureLeavesTheQueueIndexAndSendsNoBoundary() {
        let (attempts, a) = onlyAttempt()
        let failures: [StartFailure] = [
            .confirmDeadline(last: .paused),
            .confirmInterrupted,
            .threw(PlaybackErrorCode(typeName: "MPMusicPlayerControllerError", domain: "MPErrorDomain", code: 6)),
            .threw(PlaybackErrorCode(typeName: "NSError", domain: "MPErrorDomain", code: 4)),
            .noProgressEnd,
            .refused(pausedBySystem: false),
            .refused(pausedBySystem: true),
        ]
        for failure in failures {
            let effect = StartFailurePolicy.effect(failure, attempt: a, current: attempts.current)
            XCTAssertFalse(effect.advancesQueue, "\(failure)")
            XCTAssertFalse(effect.pausesPlayer, "\(failure): a failed start never pauses MusicKit")
            XCTAssertFalse(effect.events.contains(.naturalBoundary(nextIndex: 1)), "\(failure)")
            XCTAssertFalse(effect.events.contains(.userSkipped(nextIndex: 1)), "\(failure)")
            let snapshot = engineAfter(effect)
            XCTAssertEqual(snapshot.nowPlaying?.id, "s0", "\(failure): still on the song the user tapped")
            XCTAssertEqual(snapshot.upNext.map(\.id), ["s1", "s2"], "\(failure)")
            XCTAssertNotEqual(snapshot.transport, .playing, "\(failure): never a false .playing")
        }
    }

    /// The deadline and an interruption report but keep `.preparing`, so a late `.playing`
    /// can still be confirmed; a throw, a no-progress end and a refusal leave `.paused`.
    func testReportedConfirmKeepsPreparingAndHardFailuresPause() {
        let (attempts, a) = onlyAttempt()
        for failure in [StartFailure.confirmDeadline(last: .paused), .confirmInterrupted] {
            let effect = StartFailurePolicy.effect(failure, attempt: a, current: attempts.current)
            XCTAssertFalse(effect.cancelsConfirm)
            XCTAssertEqual(engineAfter(effect).transport, .preparing)
            XCTAssertEqual(engineAfter(effect).error?.kind, .playbackFailed)
        }
        let code = PlaybackErrorCode(typeName: "T", domain: "D", code: 1)
        for failure in [StartFailure.threw(code), .noProgressEnd, .refused(pausedBySystem: false)] {
            let effect = StartFailurePolicy.effect(failure, attempt: a, current: attempts.current)
            XCTAssertTrue(effect.cancelsConfirm)
            XCTAssertEqual(engineAfter(effect).transport, .paused)
        }
        var engine = PlaybackEngine()
        engine.apply(.queueStarted(tracks: threeSongs, startIndex: 0, station: nil))
        for event in StartFailurePolicy.effect(.confirmDeadline(last: .paused), attempt: a, current: attempts.current).events {
            engine.apply(event)
        }
        engine.apply(.playbackConfirmed)
        engine.apply(.errorCleared)
        XCTAssertEqual(engine.snapshot.transport, .playing, "late .playing after the report")
        XCTAssertNil(engine.snapshot.error)
        XCTAssertEqual(engine.snapshot.nowPlaying?.id, "s0")
    }

    /// The video's shape through the boundary detector: the entry changes and clears at 0:00.
    /// No step is returned (so no `naturalBoundary`, no `queueIndex += 1`, no `onBoundary`,
    /// no `startNextTrack`), the no-progress flag is raised, and its effect does not advance.
    func testNoProgressEntryChangeAndClearNeverAdvance() {
        let (attempts, a) = onlyAttempt()
        var boundaries = BoundaryInterpreter()
        boundaries.userRequestedChange()
        var queueIndex = 0
        let samples = [
            PlaybackObservation(entryID: "e0", isPlaying: true, position: 0, duration: 200),
            PlaybackObservation(entryID: "e0-reid", isPlaying: true, position: 0.4, duration: 200),
            PlaybackObservation(entryID: nil, isPlaying: false, position: 0, duration: nil),
        ]
        var noProgress = 0
        for sample in samples {
            if let step = boundaries.interpret(sample, queueIndex: queueIndex, queueCount: 3) {
                XCTFail("no boundary for a start that never progressed: \(step)")
                queueIndex += 1
            }
            if boundaries.takeNoProgressEnd() { noProgress += 1 }
        }
        XCTAssertEqual(queueIndex, 0)
        XCTAssertEqual(noProgress, 2, "the change and the clear are each surfaced once")
        XCTAssertFalse(StartFailurePolicy.effect(.noProgressEnd, attempt: a, current: attempts.current).advancesQueue)
    }

    /// A throw, a refusal or a report from an attempt a newer tap replaced does nothing: no
    /// error, no pause, no cancel of the new watchdog.
    func testStaleFailureHasNoEffectOnTheNewAttempt() {
        var attempts = PlaybackAttempts()
        let first = attempts.beginStart()
        _ = attempts.beginStart()
        let code = PlaybackErrorCode(typeName: "T", domain: "D", code: 1)
        for failure in [StartFailure.threw(code), .refused(pausedBySystem: true), .noProgressEnd,
                        .confirmDeadline(last: .paused), .confirmInterrupted] {
            XCTAssertEqual(StartFailurePolicy.effect(failure, attempt: first, current: attempts.current), .none, "\(failure)")
        }
    }

    // MARK: Boundary vs new queue load (Fry's review, PlayerView boundary task)

    /// A natural end arms the next song before the boundary task awaits the break. A tap
    /// during that await bumps the queue generation, so `startNextTrack` after the await
    /// loads nothing and the tapped song stays.
    func testTapDuringTheBreakMakesTheBoundaryStale() {
        var attempts = PlaybackAttempts()
        attempts.userChangedQueue()
        attempts.beginStart()
        attempts.armNext(after: 2)           // poll: natural end of song 2
        attempts.userChangedQueue()          // user taps a song while the break is awaited
        attempts.beginStart()
        XCTAssertFalse(attempts.takeNext(after: 2), "stale boundary must not replace the tapped song")
    }

    func testSkipDuringTheBreakMakesTheBoundaryStale() {
        var attempts = PlaybackAttempts()
        attempts.armNext(after: 0)
        attempts.userChangedQueue()          // skip already loaded the next song
        XCTAssertFalse(attempts.takeNext(after: 0))
    }

    func testUntouchedBoundaryStartsTheNextSongOnce() {
        var attempts = PlaybackAttempts()
        attempts.userChangedQueue()
        attempts.armNext(after: 0)
        attempts.beginStart()                // a break resume is a new attempt, not a queue change
        XCTAssertTrue(attempts.takeNext(after: 0))
        XCTAssertFalse(attempts.takeNext(after: 0), "one boundary loads one song")
        XCTAssertFalse(attempts.takeNext(after: 5), "a call for another index never armed loads nothing")
    }

    /// A break's follow-up resume while a tap's start is preparing does not start (and so
    /// does not supersede) that start.
    func testBreakResumeDoesNotRestartAStartInFlight() {
        XCTAssertFalse(PlaybackAttempts.breakResumeMayStart(transport: .preparing))
        XCTAssertTrue(PlaybackAttempts.breakResumeMayStart(transport: .paused))
        XCTAssertTrue(PlaybackAttempts.breakResumeMayStart(transport: .playing))
    }

    // MARK: Diagnostics: type, domain and code only

    func testErrorCodeCarriesNoDescription() {
        struct Secretive: LocalizedError {
            var errorDescription: String? { "Kiss of Life by Sade, storefront us" }
        }
        let code = PlaybackErrorCode(Secretive())
        XCTAssertEqual(code.typeName, "Secretive")
        XCTAssertFalse(code.description.contains("Kiss"))
        XCTAssertFalse(code.description.contains("storefront"))
        let ns = PlaybackErrorCode(NSError(domain: "MPErrorDomain", code: 6,
                                           userInfo: [NSLocalizedDescriptionKey: "Kiss of Life"]))
        XCTAssertEqual(ns.domain, "MPErrorDomain")
        XCTAssertEqual(ns.code, 6)
        XCTAssertEqual(ns.description, "NSError MPErrorDomain code 6")
        let (attempts, a) = onlyAttempt()
        let message = StartFailurePolicy.effect(.threw(ns), attempt: a, current: attempts.current).message ?? ""
        XCTAssertEqual(message, "Apple Music couldn't start this song. Try again.")
        XCTAssertFalse(message.contains("MPErrorDomain"))
        XCTAssertFalse(message.contains("Kiss"))
    }
}
