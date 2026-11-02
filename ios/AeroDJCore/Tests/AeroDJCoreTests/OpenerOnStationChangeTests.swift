import XCTest
@testable import AeroDJCore

/// Echo's #359 show opener, per station (-Fry): `queueStarted` for a different station opens the
/// show again, once. "Different" is the seed part of the feed's `StationQueueKey` (#362 P1, Echo):
/// reach and discovery are tuning sliders on the same station. A restart or re-queue on the same station, a skip, or a genre, mood
/// or personality edit never replays it. The live path through `StationQueueFeed` is in
/// `OpenerThroughStationQueueFeedTests`. Deterministic: no render runs (every song start is
/// inside the boundary margin) and station edits are awaited through `testOnStationChangeHandled`.
private struct SilentVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class OpenerOnStationChangeTests: XCTestCase {
    private static func seeded(_ id: String) -> [StationSeed] {
        [StationSeed(kind: .artist, catalogID: id, name: "Artist \(id)")]
    }

    private func rig(seed: UInt64, tagsOnly: Bool = false) async -> (DJBreakSession, StationConfigurationModel) {
        var config = StationConfiguration(genres: ["jazz", "soul"], moods: ["mellow"], commentary: .frequent)
        if !tagsOnly { config.seeds = Self.seeded("first") }
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: SilentVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed, hour: { 14 })
        await session.start()
        return (session, station)
    }

    private func openers(_ session: DJBreakSession) -> [Int] {
        session.testPlannedBreaks.filter { $0.value.shape == .showOpener }.keys.sorted()
    }

    /// The queue opens the show and its opener airs: the song after it is playing. `remaining`
    /// is inside the boundary margin, so nothing renders.
    private func airTheOpener(_ session: DJBreakSession, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let opened = openers(session)
        XCTAssertEqual(opened.count, 1, "\(label): the queue opens the show", file: file, line: line)
        guard let k = opened.first else { return }
        await session.songStarted(index: k + 1, remaining: .seconds(1))
    }

    /// Saves `edit` and waits until the session's observer has handled it (any replan done).
    private func save(_ session: DJBreakSession, _ station: StationConfigurationModel,
                      _ edit: () async -> Void) async {
        await edit()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.testOnStationChangeHandled = { _ in
                session.testOnStationChangeHandled = nil
                done.resume()
            }
            Task { @MainActor in await station.saveChanges() }
        }
        XCTAssertFalse(station.hasPendingChanges)
    }

    // (a) A station change replays the opener, once.
    func testAStationChangeReplaysTheOpenerOnce() async {
        for seed in UInt64(0)..<10 {
            let (session, station) = await rig(seed: seed)
            await session.queueStarted(djTracks(30))
            await airTheOpener(session, "seed \(seed) first station")

            await save(session, station) { await station.setSeeds(Self.seeded("second")) }
            XCTAssertEqual(station.committedDisplayed.seeds.map(\.catalogID), ["second"])
            await session.queueStarted(djTracks(30))
            XCTAssertEqual(openers(session).count, 1, "seed \(seed): the new station opens the show once")
            XCTAssertEqual(openers(session).first, session.plannedBoundaries.first, "seed \(seed): as its first break")

            await airTheOpener(session, "seed \(seed) second station")
            await session.queueStarted(djTracks(30))
            XCTAssertEqual(openers(session), [], "seed \(seed): a re-queue on the new station does not open it again")
            await session.stop()
        }
    }

    // (b) A restart on the same station (stop, then the same station again), a skip, or a
    // re-queue does not replay it.
    func testASameStationRestartDoesNotReplayTheOpener() async {
        for seed in UInt64(0)..<10 {
            let (session, _) = await rig(seed: seed)
            await session.queueStarted(djTracks(30))
            await airTheOpener(session, "seed \(seed)")

            await session.songStarted(index: 5, remaining: .seconds(1))      // a skip ahead
            XCTAssertEqual(openers(session).count, 1, "seed \(seed): a skip re-plans nothing")
            await session.queueStarted(djTracks(30))
            XCTAssertEqual(openers(session), [], "seed \(seed): re-queue on the same station")

            await session.stop()
            await session.queueStarted(djTracks(30))
            XCTAssertEqual(openers(session), [], "seed \(seed): restart on the same station")
            await session.stop()
        }
    }

    // (c) A personality change on the same station does not replay it: not in the re-plan the
    // edit causes, and not on the next queue.
    func testAPersonalityChangeOnTheSameStationDoesNotReplayTheOpener() async {
        for seed in UInt64(0)..<10 {
            let (session, station) = await rig(seed: seed)
            await session.queueStarted(djTracks(30))
            await airTheOpener(session, "seed \(seed)")
            let kept = openers(session)

            await save(session, station) { await station.setPersonality(.upbeat) }
            XCTAssertEqual(session.testWriterTone, .forPersonality(.upbeat), "seed \(seed): the edit re-planned")
            XCTAssertEqual(openers(session), kept, "seed \(seed): the aired opener stays; no new one")

            await session.queueStarted(djTracks(30))
            XCTAssertEqual(openers(session), [], "seed \(seed): next queue, same station, new personality")
            await session.stop()
        }
    }

    // (d) Genre tags are not in the feed's key, so a genre edit never starts a new station queue;
    // a later re-queue (a tap) on the same station does not re-greet either. Seeded and tags-only.
    func testAGenreEditDoesNotReGreetOnTheNextQueue() async {
        for tagsOnly in [false, true] {
            for seed in UInt64(0)..<10 {
                let (session, station) = await rig(seed: seed, tagsOnly: tagsOnly)
                await session.queueStarted(djTracks(30))
                await airTheOpener(session, "seed \(seed) tagsOnly \(tagsOnly)")

                await save(session, station) { await station.setGenres(["house", "disco"]) }
                XCTAssertEqual(station.committedDisplayed.genres, ["house", "disco"])
                await session.queueStarted(djTracks(30))
                XCTAssertEqual(openers(session), [], "seed \(seed) tagsOnly \(tagsOnly): genres are not in the feed's key")
                await session.stop()
            }
        }
    }

    // (f) Reach and discovery are in the feed's key (the feed builds a new queue for them), but they
    // tune the same station (Echo, #362): only the key's seeds count, so no opener.
    func testAReachOrDiscoveryEditDoesNotReGreet() async {
        for edit in ["reach", "discovery"] {
            for seed in UInt64(0)..<5 {
                let (session, station) = await rig(seed: seed)
                await session.queueStarted(djTracks(30))
                await airTheOpener(session, "seed \(seed) \(edit)")
                let before = StationQueueKey(station.committedDisplayed)
                await save(session, station) {
                    if edit == "reach" { await station.setReach(.broad) } else { await station.setDiscovery(0.9) }
                }
                XCTAssertNotEqual(StationQueueKey(station.committedDisplayed), before, "\(edit) is in the key")
                await session.queueStarted(djTracks(30))
                XCTAssertEqual(openers(session), [], "seed \(seed) \(edit): a tuning slider, not a new station")
                await session.stop()
            }
        }
    }

    // (e) A mood-only edit does not re-greet, on a seeded or a tags-only station.
    func testAMoodOnlyEditDoesNotReGreet() async {
        for tagsOnly in [false, true] {
            for seed in UInt64(0)..<10 {
                let (session, station) = await rig(seed: seed, tagsOnly: tagsOnly)
                await session.queueStarted(djTracks(30))
                await airTheOpener(session, "seed \(seed) tagsOnly \(tagsOnly)")

                await save(session, station) { await station.setMoods(["upbeat", "late night"]) }
                XCTAssertEqual(station.committedDisplayed.moods, ["upbeat", "late night"])
                await session.queueStarted(djTracks(30))
                XCTAssertEqual(openers(session), [], "seed \(seed) tagsOnly \(tagsOnly): mood is tone, not a new station")
                await session.stop()
            }
        }
    }
}
