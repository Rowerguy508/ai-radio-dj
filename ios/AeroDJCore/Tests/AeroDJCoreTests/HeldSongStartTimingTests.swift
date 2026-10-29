import XCTest
@testable import AeroDJCore

/// Build 22 P0 (-Fry): song 1 starts before tap-time queue setup finishes, so its
/// `songStarted` is held and replayed. The replay must use the time actually left in the song,
/// not the catalog duration from when it was held, or the afterTrack 0 render deadline lands
/// past the real boundary and the break is lost as `notReadyAtBoundary`.
@MainActor
final class HeldSongStartTimingTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { date += seconds }
    }

    private final class CountingVoice: VoiceProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        private func record() { lock.lock(); _calls += 1; lock.unlock() }
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            record()
            return VoiceArtifact(data: Data(text.utf8), durationSeconds: 1, billableUnits: 0,
                                 provider: "device", cacheKey: nil)
        }
    }

    private func tracks(_ n: Int) -> [DJTrack] {
        (0..<n).map { DJTrack(id: "t\($0)", title: "T\($0)", artist: "A\($0)") }
    }

    private func makeSession(voice: CountingVoice, clock: Clock) async -> DJBreakSession {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: voice, voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(),
                                     seed: 1, hour: { 14 }, now: { clock.date })
        await session.start()
        return session
    }

    /// Holds song 0's start, lets `setupSeconds` pass during setup, then replays it.
    private func heldStart(remaining: Duration, setupSeconds: TimeInterval,
                           voice: CountingVoice) async -> DJBreakSession {
        let clock = Clock()
        let session = await makeSession(voice: voice, clock: clock)
        let reservation = session.reserveQueueSetup()
        await session.songStarted(index: 0, remaining: remaining)
        XCTAssertEqual(session.testHeldSongStartIndex, 0, "song 0 started before setup: held")
        session.testBeforeQueueStarted = { clock.advance(setupSeconds) }
        await session.beginQueueInBackground(reservation, tracks(8)).value
        return session
    }

    func testReplayedStartSubtractsTimeSpentInSetup() async {
        let session = await heldStart(remaining: .seconds(180), setupSeconds: 30, voice: CountingVoice())
        XCTAssertNil(session.testHeldSongStartIndex)
        XCTAssertEqual(session.testLastSongStartRemaining, .seconds(150),
                       "deadline is measured from the song's real start, not the replay")
        await session.stop()
    }

    func testReplayedStartWithNoSetupDelayKeepsFullRemaining() async {
        let session = await heldStart(remaining: .seconds(180), setupSeconds: 0, voice: CountingVoice())
        XCTAssertEqual(session.testLastSongStartRemaining, .seconds(180))
        await session.stop()
    }

    func testSetupOutlastingRenderMarginStartsNoRender() async throws {
        let voice = CountingVoice()
        // 10 s song, 8 s of setup: 2 s left, under the 3 s preparation margin.
        let session = await heldStart(remaining: .seconds(10), setupSeconds: 8, voice: voice)
        XCTAssertEqual(session.testLastSongStartRemaining, .seconds(2))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(voice.calls, 0, "too late to prepare: nothing renders past the boundary")
        let outcome = await session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome)
        await session.stop()
    }

    func testUnheldStartIsUnchanged() async {
        let clock = Clock()
        let session = await makeSession(voice: CountingVoice(), clock: clock)
        await session.queueStarted(tracks(8))
        clock.advance(30)
        await session.songStarted(index: 0, remaining: .seconds(180))
        XCTAssertEqual(session.testLastSongStartRemaining, .seconds(180))
        await session.stop()
    }
}
