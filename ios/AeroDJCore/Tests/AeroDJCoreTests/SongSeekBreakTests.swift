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
}
