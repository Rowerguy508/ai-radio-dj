import XCTest
@testable import AeroDJCore

/// #332 wiring (-Fry): one ledger shared by song taps and station starts, recorded only when a
/// break's audio actually starts, and kept in a store that survives a relaunch.
@MainActor
final class PersonalUpdateLedgerWiringTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(_ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: hour))!
    }

    private struct Rig {
        let session: DJBreakSession
        let dj: DJPresentationStore
        let studio: WiringStudio
        let clock: Clock
        let id: UUID
    }

    private func rig(store: any PersonalUpdatePlayStore = InMemoryPersonalUpdatePlayStore()) async -> Rig {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: WiringVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let clock = Clock(at(10))
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 10 },
                                     now: { clock.now },
                                     personalUpdates: PersonalUpdateLedger(store: store, calendar: calendar))
        await session.start()
        let id = UUID()
        let studio = WiringStudio(items: [ConnectionItem(id: id, integration: .calendar, title: "Design review",
                                                         state: .approved, sensitivity: .low)],
                                  sensitivity: [id: .low])
        return Rig(session: session, dj: dj, studio: studio, clock: clock, id: id)
    }

    private func provider(_ r: Rig) -> @MainActor () -> ApprovedShowHandoff {
        r.session.briefingProvider(studio: r.studio, now: { r.clock.now }, calendar: calendar)
    }

    private func offeredIDs(_ r: Rig, _ kind: StationHandOffKind) -> [UUID?] {
        StationStartBriefing.offer(for: kind, briefing: provider(r)).briefing?.cues.filter(\.isContent).map(\.sourceItemID) ?? []
    }

    private func tapIDs(_ r: Rig) -> [UUID?] {
        provider(r)().forQueue()?.cues.filter(\.isContent).map(\.sourceItemID) ?? []
    }

    /// Station start, then the start break is handed out at boundary 0. Returns its personal ids.
    private func startAndHandOut(_ r: Rig) async throws -> [UUID?] {
        let offer = StationStartBriefing.offer(for: .idlePlayStart, briefing: provider(r))
        XCTAssertEqual(offer.briefing?.cues.filter(\.isContent).map(\.sourceItemID), [r.id])
        await r.session.queueStarted(djTracks(8), briefing: offer.briefing, sources: offer.sources)
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        for _ in 0..<500 { if case .ready = r.dj.studioState { break }; try? await Task.sleep(for: .milliseconds(10)) }
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        return try XCTUnwrap(handed).cues.filter(\.isContent).map(\.sourceItemID)
    }

    func testAnUpdateAiredAtAStationStartIsNotOfferedAgainThatDay() async throws {
        let r = await rig()
        let handedR = try await startAndHandOut(r)
        XCTAssertEqual(handedR, [r.id])
        r.session.playbackStarted(afterTrack: 0)
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertTrue(r.session.personalUpdates.hasReachedLimit(r.id, at: r.clock.now))

        r.clock.now = at(15)
        XCTAssertEqual(tapIDs(r), [], "a later song tap that day does not repeat it")
        XCTAssertEqual(offeredIDs(r, .createdStationStart), [], "nor the next station start")
        XCTAssertEqual(offeredIDs(r, .stationSwitchAtBoundary), [])
        r.clock.now = at(23)
        XCTAssertEqual(tapIDs(r), [])
    }

    func testAPreparedOrHandedOutBreakThatNeverAiredIsNotRecorded() async throws {
        // Handed out, then dropped before audio (talk-over drop) or failed: not recorded.
        let dropped = await rig()
        let handedDropped = try await startAndHandOut(dropped)
        XCTAssertEqual(handedDropped, [dropped.id])
        dropped.session.talkoverDropped(afterTrack: 0)
        dropped.session.playbackStarted(afterTrack: 0)   // a stale event for the dropped break
        XCTAssertFalse(dropped.session.personalUpdates.hasReachedLimit(dropped.id, at: dropped.clock.now))
        XCTAssertEqual(tapIDs(dropped), [dropped.id], "keeps its chance later that day")

        let failed = await rig()
        let handedFailed = try await startAndHandOut(failed)
        XCTAssertEqual(handedFailed, [failed.id])
        failed.session.playbackFailed(afterTrack: 0)
        XCTAssertFalse(failed.session.personalUpdates.hasReachedLimit(failed.id, at: failed.clock.now))

        // Prepared, then the queue was replaced (break cancelled) before its boundary.
        let cancelled = await rig()
        let offer = StationStartBriefing.offer(for: .idlePlayStart, briefing: provider(cancelled))
        await cancelled.session.queueStarted(djTracks(8), briefing: offer.briefing, sources: offer.sources)
        await cancelled.session.songStarted(index: 0, remaining: .seconds(180))
        await cancelled.session.queueStarted(djTracks(8))
        cancelled.session.playbackStarted(afterTrack: 0)
        XCTAssertFalse(cancelled.session.personalUpdates.hasReachedLimit(cancelled.id, at: cancelled.clock.now))
        XCTAssertEqual(tapIDs(cancelled), [cancelled.id])
    }

    func testTheLimitSurvivesALedgerRecreatedFromTheSameStore() async throws {
        let suite = "fry332.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let r = await rig(store: UserDefaultsPersonalUpdatePlayStore(defaults: defaults))
        let handedR = try await startAndHandOut(r)
        XCTAssertEqual(handedR, [r.id])
        r.session.playbackStarted(afterTrack: 0)

        // "Relaunch": a new ledger over the same store, used by a song tap later that day.
        let relaunched = PersonalUpdateLedger(store: UserDefaultsPersonalUpdatePlayStore(defaults: defaults),
                                              calendar: calendar)
        XCTAssertTrue(relaunched.hasReachedLimit(r.id, at: at(18)))
        let tap = LiveQueueBriefing.provider(studio: r.studio, now: { self.at(18) }, calendar: calendar, ledger: relaunched)
        XCTAssertNil(tap().forQueue(), "not repeated after a relaunch the same day")
        let nextDay = calendar.date(byAdding: .day, value: 1, to: at(9))!
        XCTAssertFalse(relaunched.hasReachedLimit(r.id, at: nextDay), "a new day starts empty")
    }
}

@MainActor
private final class WiringStudio: LiveQueueStudio {
    var items: [ConnectionItem]
    var sensitivity: [UUID: Sensitivity]
    var liveQueueBriefing: LiveQueueBriefingInput {
        LiveQueueBriefingInput(items: items, preferences: BriefingPreferences(), sensitivityByItemID: sensitivity)
    }
    init(items: [ConnectionItem], sensitivity: [UUID: Sensitivity]) {
        self.items = items
        self.sensitivity = sensitivity
    }
}

private struct WiringVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}
