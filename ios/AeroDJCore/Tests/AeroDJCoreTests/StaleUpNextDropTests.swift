import XCTest
@testable import AeroDJCore

/// Stale "up next" (-Fry): a station change that changes what plays (seeds, reach, discovery)
/// makes the station queue feed hand off a new queue after this boundary's break. The break was
/// written during the old song, so its intro names `tracks[k + 1]` of the old queue. That intro
/// is dropped at the boundary; greetings and back-announces stay. Other edits leave it untouched.
private struct WordVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.3,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class StaleUpNextDropTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let station: StationConfigurationModel
        let dj: DJPresentationStore
        let preparer: DJBreakPreparer
    }

    private static func seeded(_ id: String) -> StationConfiguration {
        var config = StationConfiguration(commentary: .frequent)
        config.seeds = [StationSeed(kind: .artist, catalogID: id, name: "Artist \(id)")]
        return config
    }

    /// A seeded station, a song holding (edits wait for the boundary), and a planned queue.
    private func rig() async -> Rig {
        let config = Self.seeded("old")
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        await station.setPlaybackActivity(.holdingSong)
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: WordVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await session.start()
        await session.queueStarted(djTracks(8))
        return Rig(session: session, station: station, dj: dj, preparer: preparer)
    }

    private func until(_ condition: @MainActor () -> Bool, _ message: String = "") async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    /// Song 0 plays and its break renders, then the edit is saved mid-song (pending).
    private func readyBreakAfterSongZero(_ r: Rig, edit: () async -> Void) async {
        XCTAssertEqual(r.session.plannedBoundaries.first, 0)
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ if case .ready = r.dj.studioState { true } else { false } }, "ready before the boundary")
        await edit()
        await r.station.saveChanges()
        XCTAssertTrue(r.station.hasPendingChanges, "mid-song: waits for the boundary")
    }

    private func names(_ trackID: String, in prepared: PreparedDJBreak) -> [NarrationCue] {
        prepared.cues.filter {
            if case .trackMetadata(let ids)? = prepared.attributions[$0.id] { ids.contains(trackID) } else { false }
        }
    }

    // (1) Seeds change promoted at boundary 0: the intro for old t1 is dropped, the greeting stays.
    func testSeedsChangeDropsTheStaleIntroButKeepsTheGreeting() async throws {
        let r = await rig()
        await readyBreakAfterSongZero(r) { await r.station.setSeeds(Self.seeded("new").seeds) }

        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertEqual(r.station.active.seeds.map(\.catalogID), ["new"], "promoted at this boundary")
        let prepared = try XCTUnwrap(handed, "the greeting is still true: the break plays")
        XCTAssertNil(r.session.lastNoBreak)
        XCTAssertTrue(names("t1", in: prepared).isEmpty, "no 'up next' for a song that will not play")
        XCTAssertFalse(prepared.cues.isEmpty)
        XCTAssertTrue(prepared.cues.allSatisfy { prepared.attributions[$0.id] == .presenter },
                      "the greeting stays")
        let kept = Set(prepared.cues.map(\.id))
        XCTAssertTrue(prepared.clips.allSatisfy { kept.contains($0.cueID) }, "no clip for a dropped cue")
        XCTAssertEqual(Set(prepared.attributions.keys), kept)
    }

    // (2) An edit that does not change what plays (energy) leaves the break untouched.
    func testEnergyChangeKeepsTheIntro() async throws {
        let r = await rig()
        await readyBreakAfterSongZero(r) { await r.station.setEnergy(0.9) }

        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertEqual(r.station.active.energy, 0.9, "promoted at this boundary")
        let prepared = try XCTUnwrap(handed)
        XCTAssertEqual(names("t1", in: prepared).count, 1, "the intro still names the next song")
        XCTAssertTrue(prepared.cues.contains { prepared.attributions[$0.id] == .presenter })
        XCTAssertEqual(prepared.cues.count, prepared.clips.count)
    }

    // (3) A break whose only cue is the stale intro is skipped; music plays at once.
    func testABreakWithOnlyTheStaleIntroIsSkipped() async {
        let r = await rig()
        XCTAssertFalse(r.session.plannedBoundaries.contains(1))
        await r.session.songStarted(index: 1, remaining: .seconds(180))
        let intro = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "Up next, Song 2 by Artist 2.",
                                 estimatedSeconds: 2, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        await r.preparer.testRecord(.ready(PreparedDJBreak(
            afterTrack: 1, cues: [intro], clips: [],
            attributions: [intro.id: .trackMetadata(trackIDs: ["t2"])])), afterTrack: 1)
        await r.station.setReach(.broad)
        await r.station.saveChanges()
        XCTAssertTrue(r.station.hasPendingChanges)

        let handed = await r.session.naturalBoundary(afterTrack: 1)
        XCTAssertNil(handed, "nothing true left to say: music plays at once")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .cancelled)
        XCTAssertFalse(r.dj.studioState.isOnAir)
    }

    // The predicate mirrors the feed's hand-off rule and fails closed.
    func testNextSongMayChangePredicate() {
        let a = StationQueueKey(Self.seeded("a")), b = StationQueueKey(Self.seeded("b"))
        typealias S = DJBreakSession
        XCTAssertFalse(S.nextSongMayChange(queue: .known(a), before: a, after: a), "same station")
        XCTAssertTrue(S.nextSongMayChange(queue: .known(a), before: a, after: b), "promoted here")
        XCTAssertTrue(S.nextSongMayChange(queue: .known(a), before: b, after: b), "promoted earlier, not handed off yet")
        XCTAssertFalse(S.nextSongMayChange(queue: .known(b), before: b, after: b), "queue already on the new station")
        XCTAssertFalse(S.nextSongMayChange(queue: .known(nil), before: a, after: a), "feed adopts, no hand-off")
        XCTAssertFalse(S.nextSongMayChange(queue: .known(a), before: nil, after: nil), "no seeds: queue kept")
        XCTAssertTrue(S.nextSongMayChange(queue: .unknown, before: a, after: a), "unknown fails closed")
    }
}
