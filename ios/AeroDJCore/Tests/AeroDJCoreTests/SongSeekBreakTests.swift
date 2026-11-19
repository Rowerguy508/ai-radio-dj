import XCTest
@testable import AeroDJCore

/// A voice that never finishes on its own: a render stays in flight until it is cancelled.
/// Cancellation ends the wait (the stream finishes), so nothing outlives the test. No sleeps.
private struct HangingVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
        throw CancellationError()
    }
}

/// Records the preparer's events in order. The preparer emits synchronously inside the
/// awaited actor call, so a test reads them right after the await.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DJBreakPreparer.DJBreakEvent] = []
    func append(_ e: DJBreakPreparer.DJBreakEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [DJBreakPreparer.DJBreakEvent] { lock.lock(); defer { lock.unlock() }; return events }
    func preparing(_ k: Int) -> Int {
        all.filter { if case .preparing(k, _) = $0 { true } else { false } }.count
    }
}

/// Song scrubbing (-Atlas): a committed seek re-times the playing song's break without ever
/// moving the boundary. `songSeeked` is what `MusicKitService.seek(to:)` reports (via
/// `onSongSeeked`) with the new time left.
@MainActor
final class SongSeekBreakTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let preparer: DJBreakPreparer
        let log: EventLog
    }

    /// `frequent` talks at boundaries 0, 3, 6, … (see DJBreakSessionTests).
    private func rig() async -> Rig {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: HangingVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let log = EventLog()
        await preparer.observe { log.append($0) }
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await session.start()
        await session.queueStarted(djTracks(8))
        XCTAssertEqual(session.plannedBoundaries.first, 0)
        return Rig(session: session, preparer: preparer, log: log)
    }

    private static let emptyReady = DJBreakOutcome.ready(
        PreparedDJBreak(afterTrack: 0, cues: [], clips: [], attributions: [:]))

    func testSeekBackWhileTheBreakRendersKeepsItAndRendersOnce() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        let inFlight = await r.preparer.testInFlight
        XCTAssertEqual(inFlight, [0])
        await r.session.songSeeked(index: 0, remaining: .seconds(190))
        let stillInFlight = await r.preparer.testInFlight
        XCTAssertEqual(stillInFlight, [0], "kept, not restarted")
        XCTAssertEqual(r.log.preparing(0), 1, "no second render")
        await r.session.stop()
    }

    func testSeekBackAfterTheBreakIsReadyKeepsItForTheRealBoundary() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(Self.emptyReady, afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(195))
        let result = await r.preparer.testResult(afterTrack: 0)
        XCTAssertEqual(result, Self.emptyReady, "the ready break waits for the real end: not fired, not lost")
        XCTAssertEqual(r.log.preparing(0), 1)
        let inFlight = await r.preparer.testInFlight
        XCTAssertTrue(inFlight.isEmpty)
        await r.session.stop()
    }

    func testSeekBackAfterTheRenderTimedOutReArmsIt() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        let inFlight = await r.preparer.testInFlight
        XCTAssertEqual(inFlight, [0], "the seek gave the render time again")
        XCTAssertEqual(r.log.preparing(0), 2)
        await r.session.stop()
    }

    func testSeekBackAfterAStartInsideTheMarginStartsTheRender() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(2))     // too late to render
        XCTAssertEqual(r.log.preparing(0), 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(120))
        let inFlight = await r.preparer.testInFlight
        XCTAssertEqual(inFlight, [0])
        XCTAssertEqual(r.log.preparing(0), 1)
        await r.session.stop()
    }

    func testFinalSkipsAreNotReArmedBySeeking() async {
        for reason in [DJBreakSkipReason.sourceRevoked, .costCap, .renderFailed, .notNaturalBoundary, .overBreakBudget] {
            let r = await rig()
            await r.session.songStarted(index: 0, remaining: .seconds(180))
            await r.preparer.testRecord(.skipped(reason), afterTrack: 0)
            await r.session.songSeeked(index: 0, remaining: .seconds(150))
            let result = await r.preparer.testResult(afterTrack: 0)
            XCTAssertEqual(result, .skipped(reason), "\(reason) stays final")
            XCTAssertEqual(r.log.preparing(0), 1, "\(reason): no second render")
            await r.session.stop()
        }
    }

    func testForwardSeekNearTheEndWithTheRenderInFlightSkipsAtTheBoundaryWithoutWaiting() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.session.songSeeked(index: 0, remaining: .seconds(1))       // inside the margin
        let inFlight = await r.preparer.testInFlight
        XCTAssertEqual(inFlight, [0], "kept: it may still finish before the end")
        XCTAssertEqual(r.log.preparing(0), 1)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(handed, "not ready: music plays at once")
        XCTAssertTrue(r.log.all.contains(.skipped(afterTrack: 0, .notReadyAtBoundary)))
    }

    func testForwardSeekNearTheEndWithTheBreakReadyStillHandsItOut() async throws {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(Self.emptyReady, afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(1))
        let result = await r.preparer.testResult(afterTrack: 0)
        XCTAssertEqual(result, Self.emptyReady)
        XCTAssertEqual(r.log.preparing(0), 1)
        await r.session.stop()
    }

    func testForwardSeekBeforeQueueSetupFinishesRetimesTheHeldStart() async {
        let r = await rig()
        let reservation = r.session.reserveQueueSetup()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        XCTAssertEqual(r.session.testHeldSongStartIndex, 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(2))       // inside the margin
        await r.session.beginQueueInBackground(reservation, djTracks(8)).value
        XCTAssertEqual(r.log.preparing(0), 0, "replayed with the time left after the seek")
        let inFlight = await r.preparer.testInFlight
        XCTAssertTrue(inFlight.isEmpty)
        await r.session.stop()
    }

    func testSeekBackBeforeQueueSetupFinishesStillRendersOnce() async {
        let r = await rig()
        let reservation = r.session.reserveQueueSetup()
        await r.session.songStarted(index: 0, remaining: .seconds(5))
        await r.session.songSeeked(index: 0, remaining: .seconds(170))
        await r.session.beginQueueInBackground(reservation, djTracks(8)).value
        XCTAssertEqual(r.log.preparing(0), 1)
        await r.session.stop()
    }

    func testSeekOnASongThatIsNotPlayingOrHasNoBreakDoesNothing() async {
        let r = await rig()
        await r.session.songStarted(index: 1, remaining: .seconds(2))      // no break after song 1
        await r.session.songSeeked(index: 1, remaining: .seconds(150))
        await r.session.songSeeked(index: 0, remaining: .seconds(150))     // not the playing song
        XCTAssertTrue(r.log.all.isEmpty)
        let inFlight = await r.preparer.testInFlight
        XCTAssertTrue(inFlight.isEmpty)
        await r.session.stop()
    }

    // MARK: One re-arm per boundary (Echo's review: scrubbing must not respend voice characters)

    func testTwoSeeksAfterATimeoutGiveExactlyOneReRender() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        await r.session.songSeeked(index: 0, remaining: .seconds(170))
        XCTAssertEqual(r.log.preparing(0), 2, "the first render plus exactly one re-render")
        let inFlight = await r.preparer.testInFlight
        XCTAssertEqual(inFlight, [0])
        await r.session.stop()
    }

    func testASecondTimeoutAfterTheReArmStaysSkippedWithNoThirdRender() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(150))     // the one re-arm
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)    // it timed out again
        await r.session.songSeeked(index: 0, remaining: .seconds(170))
        await r.session.songSeeked(index: 0, remaining: .seconds(120))
        XCTAssertEqual(r.log.preparing(0), 2, "no third render")
        let result = await r.preparer.testResult(afterTrack: 0)
        XCTAssertEqual(result, .skipped(.timedOut), "final for this boundary")
        let inFlight = await r.preparer.testInFlight
        XCTAssertTrue(inFlight.isEmpty)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(handed, "music plays at once")
        await r.session.stop()
    }

    func testStartingABreakThatNeverRenderedIsTheOneReArm() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(2))      // too late to render
        await r.session.songSeeked(index: 0, remaining: .seconds(120))     // starts it: the one re-arm
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        XCTAssertEqual(r.log.preparing(0), 1, "no second render")
        await r.session.stop()
    }

    func testTheReArmAllowanceResetsOnTheNextSongAndBoundary() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        let first = await r.preparer.mayRearm(afterTrack: 0)
        XCTAssertFalse(first, "spent for boundary 0")
        _ = await r.session.naturalBoundary(afterTrack: 0)
        for index in 1...3 { await r.session.songStarted(index: index, remaining: .seconds(180)) }
        XCTAssertEqual(r.log.preparing(3), 1)
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 3)
        await r.session.songSeeked(index: 3, remaining: .seconds(150))
        XCTAssertEqual(r.log.preparing(3), 2, "the next boundary gets its own re-arm")
        await r.session.stop()
    }

    func testTheReArmAllowanceResetsWhenTheSameBoundaryComesAgainInANewQueue() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.queueStarted(djTracks(8))                           // new queue: boundary 0 again
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        XCTAssertEqual(r.log.preparing(0), 4, "two renders per song 0: its first and its one re-arm")
        await r.session.stop()
    }

    // MARK: Fry's race: a seek suspended across the boundary must not start an orphan render

    func testASeekThatResumesAfterTheBoundaryWasTakenStartsNoRender() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)    // re-arm would be allowed
        let preparer = r.preparer
        r.session.testSeekResumed = { _ = await preparer.takeBreak(afterTrack: 0) }  // the song ended meanwhile
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        XCTAssertEqual(r.log.preparing(0), 1, "no orphan render for a boundary that went by")
        let inFlight = await r.preparer.testInFlight
        XCTAssertTrue(inFlight.isEmpty)
        let reopened = await r.preparer.mayRearm(afterTrack: 0)
        XCTAssertFalse(reopened, "closed until song 0 starts again")
        await r.session.stop()
    }

    func testASeekThatResumesAfterCancelAllStartsNoRender() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        let preparer = r.preparer
        r.session.testSeekResumed = { await preparer.cancelAll() }          // queue replaced or stopped meanwhile
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        XCTAssertEqual(r.log.preparing(0), 1, "no orphan render after cancelAll")
        let inFlight = await r.preparer.testInFlight
        XCTAssertTrue(inFlight.isEmpty)
        let reopened = await r.preparer.mayRearm(afterTrack: 0)
        XCTAssertFalse(reopened)
        await r.session.stop()
    }

    func testADuplicateStartReportDoesNotBuyASecondReArm() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songSeeked(index: 0, remaining: .seconds(150))     // the one re-arm
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.session.songStarted(index: 0, remaining: .seconds(140))    // repeated start report
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        XCTAssertEqual(r.log.preparing(0), 2)
        await r.session.stop()
    }

    // MARK: cancelAll(except:) clears re-arm state for every boundary it drops (Fry's #167 note)

    func testASeekThatResumesAfterANarrowedCancelStartsNoRenderForADroppedBoundary() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        let preparer = r.preparer
        r.session.testSeekResumed = { await preparer.cancelAll(except: [3]) }  // station change dropped 0
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        XCTAssertEqual(r.log.preparing(0), 1, "no orphan render for a dropped boundary")
        let reopened = await r.preparer.mayRearm(afterTrack: 0)
        XCTAssertFalse(reopened, "closed until song 0 starts again")
        await r.session.stop()
    }

    func testANarrowedCancelKeepsTheReArmStateOfAKeptBoundary() async {
        let r = await rig()
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.preparer.cancelAll(except: [0])
        let open = await r.preparer.mayRearm(afterTrack: 0)
        XCTAssertTrue(open, "a kept boundary keeps its one re-arm")
        await r.session.songSeeked(index: 0, remaining: .seconds(150))     // spends it
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)
        await r.preparer.cancelAll(except: [0])
        let spent = await r.preparer.mayRearm(afterTrack: 0)
        XCTAssertFalse(spent, "a narrowed cancel never buys a second re-arm")
        await r.session.stop()
    }
}
