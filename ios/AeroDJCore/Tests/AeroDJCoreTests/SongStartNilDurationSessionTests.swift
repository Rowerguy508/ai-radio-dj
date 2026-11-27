import XCTest
@testable import AeroDJCore

private struct FixedVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

/// #304 R3 (-Echo): a song with no usable duration gets no break, and that is never silent.
/// The app (`PlayerView.onSongStarted`) asks `PlaybackLog.songStartSkipReason` first; a non-nil
/// reason is logged as a skip and the session is not told the song started. These tests drive the
/// session the same way and pin that the missed break is reported, never aired, and never leaves
/// the DJ stuck: the next planned break still prepares and hands out.
@MainActor
final class SongStartNilDurationSessionTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let dj: DJPresentationStore
    }

    /// `frequent` with default spacing plans breaks after songs 0, 3, 6, ...
    private func rig() async -> Rig {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: FixedVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await session.start()
        return Rig(session: session, dj: dj)
    }

    /// Mirrors `PlayerView.onSongStarted`: the skip reason (logged by the app) or a session start.
    private func appSongStarted(_ r: Rig, index: Int, duration: TimeInterval?) async -> DJBreakSkipReason? {
        if let skip = PlaybackLog.songStartSkipReason(duration: duration) { return skip }
        guard let duration else { return nil }
        // `.seconds` traps on NaN or infinity: fail here instead of crashing the runner.
        guard duration.isFinite else { XCTFail("duration \(duration) reached the session"); return nil }
        await r.session.songStarted(index: index, remaining: .seconds(duration))
        return nil
    }

    private func until(_ condition: @escaping @MainActor () -> Bool, _ message: String = "") async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    func testNilDurationSongWithAPlannedBreakLogsASkipAndAirsNothing() async throws {
        let r = await rig()
        await r.session.queueStarted(djTracks(8))
        XCTAssertEqual(r.session.plannedBoundaries.first, 0, "a break is planned after song 0")

        let skip = await appSongStarted(r, index: 0, duration: nil)
        XCTAssertEqual(skip, .durationUnknown, "the missed break is reported at song start")
        let logged = try XCTUnwrap(skip, "a nil duration is never a silent no-break")
        XCTAssertEqual(PlaybackLog.breakSkipped(after: 0, reason: logged), "break skipped after=0 reason=durationUnknown")
        XCTAssertEqual(r.dj.studioState, .idle, "nothing is prepared or shown as coming up")

        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(handed, "no break airs after a song with no duration")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .notPlanned)
        XCTAssertEqual(r.session.lastNoBreak?.cadencePlanned, true,
                       "the boundary trace still shows the cadence had planned a break here")
        XCTAssertEqual(r.dj.studioState, .idle, "not stuck in ready or preparing")
    }

    func testTheNextPlannedBreakStillAirsAfterANilDurationSong() async throws {
        let r = await rig()
        await r.session.queueStarted(djTracks(8))
        XCTAssertEqual(Array(r.session.plannedBoundaries.prefix(2)), [0, 3])

        _ = await appSongStarted(r, index: 0, duration: nil)
        _ = await r.session.naturalBoundary(afterTrack: 0)
        for k in 1...2 {
            let skip = await appSongStarted(r, index: k, duration: 180)
            XCTAssertNil(skip)
            let none = await r.session.naturalBoundary(afterTrack: k)
            XCTAssertNil(none, "no break planned after song \(k)")
        }
        let skip = await appSongStarted(r, index: 3, duration: 180)
        XCTAssertNil(skip, "a song with a duration plans its break as usual")
        await until({ if case .ready = r.dj.studioState { true } else { false } }, "song 3's break is ready before its boundary")
        let handed = await r.session.naturalBoundary(afterTrack: 3)
        let prepared = try XCTUnwrap(handed, "the DJ is not left silent for the rest of the queue")
        XCTAssertEqual(prepared.afterTrack, 3)
        XCTAssertFalse(prepared.clips.isEmpty)
    }

    func testZeroAndNonFiniteDurationsTakeTheSameReportedSkip() async {
        for duration: TimeInterval in [0, -1, .nan, .infinity] {
            let r = await rig()
            await r.session.queueStarted(djTracks(8))
            let skip = await appSongStarted(r, index: 0, duration: duration)
            XCTAssertEqual(skip, .durationUnknown, "duration \(duration) is reported, not planned against")
            let handed = await r.session.naturalBoundary(afterTrack: 0)
            XCTAssertNil(handed)
            XCTAssertEqual(r.dj.studioState, .idle)
        }
    }
}
