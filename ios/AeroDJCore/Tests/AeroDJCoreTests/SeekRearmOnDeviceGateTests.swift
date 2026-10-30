import XCTest
@testable import AeroDJCore

// Library-seed gate (#154) on the seek re-arm path (Sentinel): `songSeeked` re-arms a timed-out
// break through `DJBreakPreparer.rearm`, which must keep a library-seeded station on-device.

/// Records which route each render reached, in order, then hangs until cancelled (so the
/// renderer never falls through to the next route). No sleeps: a test awaits the next call.
private final class RouteCalls: @unchecked Sendable {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    init() { (stream, continuation) = AsyncStream<String>.makeStream() }
    func record(_ id: String) { continuation.yield(id) }
}

private struct RecordingHangingVoice: VoiceProvider {
    let id: String
    let calls: RouteCalls
    let failIfCalled: Bool
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        if failIfCalled { XCTFail("library-seeded break text reached the off-device route '\(id)'") }
        calls.record(id)
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
        throw CancellationError()
    }
}

@MainActor
final class SeekRearmOnDeviceGateTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let preparer: DJBreakPreparer
        let calls: RouteCalls
    }

    /// Routes: an off-device spy ("cloud", `leavesDevice: true`) first, then an on-device one.
    private func rig(seed: StationSeed, cloudFailsIfCalled: Bool) async -> Rig {
        let config = StationConfiguration(commentary: .frequent, seeds: [seed])
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let calls = RouteCalls()
        let cloud = VoiceRoute(providerID: "cloud",
                               provider: RecordingHangingVoice(id: "cloud", calls: calls, failIfCalled: cloudFailsIfCalled),
                               voice: djVoice, leavesDevice: true)
        let device = VoiceRoute(providerID: "device",
                                provider: RecordingHangingVoice(id: "device", calls: calls, failIfCalled: false),
                                voice: djVoice)
        let renderer = VoiceRenderer(routes: [cloud, device], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache(), cloudConsent: .inMemory(.accepted))
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await session.start()
        await session.queueStarted(djTracks(8))
        XCTAssertEqual(session.plannedBoundaries.first, 0)
        return Rig(session: session, preparer: preparer, calls: calls)
    }

    private func nextRoute(_ calls: RouteCalls) async -> String? {
        for await id in calls.stream { return id }
        return nil
    }

    /// Break 0 starts, times out, then a seek back re-arms it. Returns the route each render reached.
    private func startTimeOutAndSeek(_ r: Rig) async -> (start: String?, rearm: String?) {
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        let start = await nextRoute(r.calls)
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: 0)   // cancels the first render
        await r.session.songSeeked(index: 0, remaining: .seconds(150))
        let inFlight = await r.preparer.testInFlight
        XCTAssertEqual(inFlight, [0], "the seek re-armed the timed-out break")
        let rearm = await nextRoute(r.calls)
        return (start, rearm)
    }

    func testSeekReArmOfALibrarySeededStationStaysOnDevice() async {
        let library = StationSeed(kind: .playlist, catalogID: "p.lib1", name: "Road Trip", source: .library)
        let r = await rig(seed: library, cloudFailsIfCalled: true)
        let routes = await startTimeOutAndSeek(r)
        XCTAssertEqual(routes.start, "device", "first render: on-device only")
        XCTAssertEqual(routes.rearm, "device", "re-armed render: on-device only, never the leavesDevice route")
        await r.session.stop()
    }

    func testSeekReArmOfACatalogStationStillUsesTheFullRenderer() async {
        let catalog = StationSeed(kind: .artist, catalogID: "123", name: "Artist", source: .catalog)
        let r = await rig(seed: catalog, cloudFailsIfCalled: false)
        let routes = await startTimeOutAndSeek(r)
        XCTAssertEqual(routes.start, "cloud")
        XCTAssertEqual(routes.rearm, "cloud", "no library seed: the re-arm keeps the full route chain")
        await r.session.stop()
    }
}
