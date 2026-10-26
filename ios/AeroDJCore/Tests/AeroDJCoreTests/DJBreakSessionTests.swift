import XCTest
@testable import AeroDJCore

/// Voice whose measured duration is `secondsPerWord` per word.
private struct PacedVoice: VoiceProvider {
    var secondsPerWord: Double = 0.4
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * secondsPerWord,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

/// In-memory cache that remembers which keys were stored.
private actor RecordingCache: AudioCache {
    private let inner = InMemoryAudioCache()
    private(set) var keys: [String] = []
    func audio(for key: String) async -> CachedAudio? { await inner.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async { keys.append(key); await inner.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func purgeAllPersonal() async { await inner.purgeAllPersonal() }
    func remaining() async -> [CachedAudio] {
        var out: [CachedAudio] = []
        for key in keys { if let a = await inner.audio(for: key) { out.append(a) } }
        return out
    }
}

@MainActor
final class DJBreakSessionTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let station: StationConfigurationModel
        let dj: DJPresentationStore
        let preparer: DJBreakPreparer
        let cache: RecordingCache
    }

    /// `frequent` with the default spacing talks at every third boundary (0, 3, 6, …), so plans are predictable.
    private func rig(_ config: StationConfiguration = .init(commentary: .frequent), voice: PacedVoice = .init()) async -> Rig {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let cache = RecordingCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: voice, voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await session.start()
        return Rig(session: session, station: station, dj: dj, preparer: preparer, cache: cache)
    }

    private func until(_ condition: @MainActor () -> Bool, _ message: String = "") async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    func testBreakIsPreparedDuringTheSongAndHandedOverAtTheBoundary() async throws {
        let r = await rig()
        await r.session.queueStarted(djTracks(8))
        XCTAssertEqual(r.session.plannedBoundaries.first, 0)
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ if case .ready = r.dj.studioState { true } else { false } }, "ready before the boundary")
        XCTAssertFalse(r.dj.studioState.isOnAir, "ready is not On Air")

        let handed = await r.session.naturalBoundary(afterTrack: 0)
        let prepared = try XCTUnwrap(handed)
        XCTAssertFalse(prepared.clips.isEmpty)
        XCTAssertLessThanOrEqual(prepared.measuredSeconds, 12, "routine cap")
        XCTAssertTrue(prepared.clips.allSatisfy { $0.audio.providerID == "device" }, "$0 on-device voice")
        r.session.playbackStarted(afterTrack: 0)
        XCTAssertTrue(r.dj.studioState.isOnAir, "On Air only after the player confirms audio")
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertEqual(r.dj.studioState, .idle)

        let nothing = await r.session.naturalBoundary(afterTrack: 1)
        XCTAssertNil(nothing, "no break planned: music continues at once")
    }

    func testLateOrCutBreaksAreSkippedAndNeverWait() async {
        let r = await rig()
        await r.session.queueStarted(djTracks(8))
        await r.session.songStarted(index: 0, remaining: .seconds(2))     // inside the 3 s margin
        let late = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(late, "too late to render: skipped, not delayed")

        await r.session.songStarted(index: 3, remaining: .seconds(180))
        await until { if case .ready = r.dj.studioState { true } else { false } }
        await r.session.songCut(afterTrack: 3)
        let afterCut = await r.session.naturalBoundary(afterTrack: 3)
        XCTAssertNil(afterCut, "never talk after a cut song")
    }

    func testRoutineBreakOverTwelveSecondsIsSkipped() async {
        let r = await rig(voice: PacedVoice(secondsPerWord: 3))
        await r.session.queueStarted(djTracks(8))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .failed = r.dj.studioState { true } else { false } }
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome)
        XCTAssertEqual(r.dj.studioState, .failed(.voiceFailed))
    }

    func testBriefingBreakMayUseFortyFiveSecondsButNotMore() async throws {
        func handoff(_ itemID: UUID) -> NarrationHandoff {
            let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent,
                                   text: "Coming up: Standup at ten in room four. From your calendar.",
                                   estimatedSeconds: 5, maxSeconds: 30, sourceItemID: itemID, source: .calendar, provenance: "fixture:1")
            return NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600)
        }
        let ok = await rig(voice: PacedVoice(secondsPerWord: 0.8))
        let okBriefing = handoff(UUID())
        await ok.session.queueStarted(djTracks(8), briefing: okBriefing, sources: approvedSources(okBriefing))
        await ok.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = ok.dj.studioState { true } else { false } }
        let handed = await ok.session.naturalBoundary(afterTrack: 0)
        let briefing = try XCTUnwrap(handed)
        XCTAssertTrue(briefing.includesBriefing)
        XCTAssertGreaterThan(briefing.measuredSeconds, 12, "longer than a routine break is fine for a briefing")
        XCTAssertLessThanOrEqual(briefing.measuredSeconds, 45)

        let long = await rig(voice: PacedVoice(secondsPerWord: 2.5))
        let longBriefing = handoff(UUID())
        await long.session.queueStarted(djTracks(8), briefing: longBriefing, sources: approvedSources(longBriefing))
        await long.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .failed = long.dj.studioState { true } else { false } }
        let skipped = await long.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(skipped, "over 45 s: skipped, music continues")
    }

    func testTunerChangesApplyAtTheBoundaryAndNeverToThePlayingSong() async {
        let r = await rig()
        await r.session.queueStarted(djTracks(12))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = r.dj.studioState { true } else { false } }
        let before = r.session.plannedBoundaries

        await r.station.setCommentary(.rare)       // a cadence change: future breaks, after this song
        XCTAssertEqual(r.station.active.commentary, .frequent, "pending until the boundary")
        XCTAssertEqual(r.session.plannedBoundaries, before, "nothing re-planned mid-song")

        let played = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNotNil(played, "the break prepared for the playing song is untouched")
        XCTAssertEqual(r.station.active.commentary, .rare, "applied at the song boundary")
        XCTAssertEqual(r.station.active.cadence().talkFraction, 0.15)
    }

    func testTurningCommentaryOffDropsPreparedSpeechImmediately() async {
        let r = await rig()
        await r.session.queueStarted(djTracks(12))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = r.dj.studioState { true } else { false } }
        await r.station.setCommentary(.off)
        await until { r.session.plannedBoundaries.isEmpty }
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome, "off applies now: nothing prepared plays")
        XCTAssertEqual(r.dj.studioState, .idle)
    }

    func testRevokingAnItemRemovesItFromPlannedPreparedAndCachedNarration() async throws {
        let item = UUID()
        let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "From your notes: water the plants.",
                               estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .obsidian, provenance: "fixture:n1")
        let r = await rig()
        let briefing = NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600)
        await r.session.queueStarted(djTracks(12), briefing: briefing, sources: approvedSources(briefing))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ if case .ready(true, _) = r.dj.studioState { true } else { false } }, "the item is in the prepared break")

        // The path ConnectionsModel uses for revoke/delete.
        let provider = InMemoryConnectionItemProvider(integration: .obsidian, items: [
            ConnectionItem(id: item, integration: .obsidian, title: "[TEST] note", state: .approved)])
        let connections = ConnectionsModel(station: r.station, sourceReader: StaticConnectionSourceReader(),
                                           providers: [provider],
                                           purger: NarrationPurger(cache: r.cache, preparer: r.preparer, session: r.session))
        await connections.refresh()
        _ = await connections.perform(.revoke, on: item)

        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome, "the prepared break built from the item never plays")
        for k in 1..<11 {
            await r.session.songStarted(index: k, remaining: .seconds(180))
            if let b = await r.session.naturalBoundary(afterTrack: k) {
                XCTAssertFalse(b.cues.contains { $0.sourceItemID == item }, "never re-planned")
            }
        }
        let stored = await r.cache.keys
        XCTAssertFalse(stored.isEmpty)
        let cached = await r.cache.remaining()
        XCTAssertFalse(cached.contains { $0.sourceItemIDs.contains(item) }, "cached narration purged")
    }
}
