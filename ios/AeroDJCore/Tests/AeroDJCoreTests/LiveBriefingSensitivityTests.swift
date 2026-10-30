import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AeroDJCore

// Nigel's report (relayed by Orion): the live `StudioPresentationModel.liveQueueBriefing` passed
// an empty `sensitivityByItemID`, and a missing id is `.blocked`, so the live briefing was silent.
// These tests run the path exactly as the app wires it: a real `ConnectionsModel` inside a real
// `StudioPresentationModel`, read through `LiveQueueBriefing.provider(studio:days:)`.
// Fixture titles only; assertion messages print counts and ids, never cue text.

private struct FixtureProvider: ConnectionItemProvider {
    let integration: StationIntegration
    let list: [ConnectionItem]
    func items(now: Date) async throws -> [ConnectionItem] { list }
    func perform(_ action: ConnectionAction, on id: UUID) async throws {}
}

private struct NoPurge: NarrationPurging {
    func purge(sourceItemIDs: Set<UUID>) async {}
}

/// Mutable clock and time zone for `BriefingDayLedger` (the device "flies").
final class DayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var zone: TimeZone
    init(_ date: Date, _ zone: TimeZone) { self.date = date; self.zone = zone }
    var now: Date { get { lock.withLock { date } } set { lock.withLock { date = newValue } } }
    var timeZone: TimeZone { get { lock.withLock { zone } } set { lock.withLock { zone = newValue } } }
    func ledger(_ store: any BriefingDayStore = InMemoryBriefingDayStore()) -> BriefingDayLedger {
        BriefingDayLedger(store: store, now: { [unowned self] in self.now }, timeZone: { [unowned self] in self.timeZone })
    }
}

@MainActor
class LiveBriefingFixture: XCTestCase {
    let utcZone = TimeZone(identifier: "UTC")!
    let newYork = TimeZone(identifier: "America/New_York")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let honolulu = TimeZone(identifier: "Pacific/Honolulu")!

    func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    func at(_ zone: TimeZone, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// 08:00 UTC on a fixed day.
    var eight: Date { at(utcZone, 2026, 10, 26, 8) }

    func liveStudio(_ items: [ConnectionItem]) async -> StudioPresentationModel {
        var config = StationConfiguration.sampleMorningMix
        config.briefing = BriefingPreferences(enabled: true, window: BriefingWindow(startMinute: 7 * 60, durationMinutes: 120),
                                              sections: Set(BriefingSection.allCases))
        config.requestedIntegrations = Set(StationIntegration.allCases)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([.calendar: .granted, .shareInbox: .granted, .obsidian: .granted]))
        await station.load()
        let providers: [any ConnectionItemProvider] = StationIntegration.allCases.map { integration in
            FixtureProvider(integration: integration, list: items.filter { $0.integration == integration })
        }
        let refreshAt = eight
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(),
                                           providers: providers, purger: NoPurge(), now: { refreshAt })
        let studio = StudioPresentationModel(station: station, recipes: StationRecipeLibrary(store: InMemoryStationRecipeStore()),
                                             connections: connections, dj: DJPresentationStore())
        await studio.connections.refresh()
        return studio
    }

    func contentIDs(_ handoff: NarrationHandoff?) -> [UUID] {
        (handoff?.cues ?? []).filter(\.isContent).compactMap(\.sourceItemID)
    }

    /// The live provider at 08:00 UTC with a fresh ledger: what the app would queue.
    func liveQueued(_ studio: StudioPresentationModel) -> NarrationHandoff? {
        let now = eight
        return LiveQueueBriefing.provider(studio: studio, days: .inMemory(now: { now }), now: { now },
                                          calendar: calendar(utcZone))().forQueue()
    }
}

final class LiveBriefingSensitivityTests: LiveBriefingFixture {
    /// Red on ec26f89 (0 of 2 content cues): the live input carried `[:]`, so both rows were blocked.
    func testLiveStudioBriefingSpeaksUnblockedCalendarAndSharedItems() async throws {
        let event = UUID(), reminder = UUID()
        let studio = await liveStudio([
            ConnectionItem(id: event, integration: .calendar, title: "Fixture standup", state: .approved, sensitivity: .low),
            ConnectionItem(id: reminder, integration: .shareInbox, title: "Fixture reminder", state: .approved, sensitivity: .medium),
        ])
        let spoken = Set(contentIDs(liveQueued(studio)))
        XCTAssertEqual(spoken, [event, reminder],
                       "unblocked approved rows are spoken (\(spoken.count) of 2 content cues)")
    }

    /// One builder: the live briefing input is exactly the map `ConnectionsModel` builds,
    /// which is `ConnectionItem.sensitivityMap` of its rows. Fails if either side drifts.
    func testLiveBriefingMapIsTheConnectionsModelMap() async throws {
        let ids = (0..<6).map { _ in UUID() }
        let studio = await liveStudio([
            ConnectionItem(id: ids[0], integration: .calendar, title: "Fixture a", state: .approved, sensitivity: .low),
            ConnectionItem(id: ids[1], integration: .calendar, title: "Fixture b", state: .approved, sensitivity: .high),
            ConnectionItem(id: ids[2], integration: .shareInbox, title: "Fixture c", state: .pendingApproval, sensitivity: .medium),
            ConnectionItem(id: ids[3], integration: .obsidian, title: "Fixture d", state: .unavailable(.markedPrivate), sensitivity: .blocked),
            ConnectionItem(id: ids[4], integration: .obsidian, title: "Fixture e", state: .approved, sensitivity: nil),
            ConnectionItem(id: ids[5], integration: .shareInbox, title: "Fixture f", state: .revoked, sensitivity: .low),
        ])
        let live = studio.liveQueueBriefing.sensitivityByItemID
        XCTAssertEqual(live, studio.connections.sensitivityByItemID)
        XCTAssertEqual(live, ConnectionItem.sensitivityMap(studio.connections.items))
        XCTAssertEqual(live.count, 5, "every row with a sensitivity, none invented")
        XCTAssertNil(live[ids[4]], "no sensitivity: left out, never defaulted")
        XCTAssertEqual(live[ids[1]], .high)
        XCTAssertEqual(live[ids[3]], .blocked)
        XCTAssertEqual(studio.liveQueueBriefing.items, studio.connections.items)
    }

    // MARK: Sentinel gate 1: a row missing from the map defaults to blocked

    func testRowMissingFromTheMapStaysBlockedOnTheLivePath() async throws {
        let control = UUID(), unknown = UUID()
        let studio = await liveStudio([
            ConnectionItem(id: control, integration: .calendar, title: "Fixture standup", state: .approved, sensitivity: .low),
            ConnectionItem(id: unknown, integration: .obsidian, title: "Fixture unclassified", state: .approved, sensitivity: nil),
        ])
        XCTAssertNil(studio.liveQueueBriefing.sensitivityByItemID[unknown])
        let spoken = contentIDs(liveQueued(studio))
        XCTAssertEqual(spoken, [control], "only the classified row (\(spoken.count) content cues)")
    }

    // MARK: Sentinel gate 2: blocked, revoked and expired rows stay silent

    /// Gate 2, row layer pinned on its own: the consent mapping alone would still silence a
    /// revoked or expired row, so without this a row-layer regression would hide behind it.
    func testOnlyApprovedRowsMayBeNarrated() {
        XCTAssertTrue(ConnectionItemState.approved.mayBeNarrated)
        for state: ConnectionItemState in [.revoked, .expired, .pendingApproval, .flaggedForReview] {
            XCTAssertFalse(state.mayBeNarrated, "\(state) must stay silent")
        }
    }

    func testBlockedRevokedAndExpiredRowsStaySilentOnTheLivePath() async throws {
        let control = UUID(), blocked = UUID(), revoked = UUID(), expired = UUID(), lapsed = UUID()
        let studio = await liveStudio([
            ConnectionItem(id: control, integration: .calendar, title: "Fixture standup", state: .approved, sensitivity: .low),
            // Approved row whose source is marked blocked (sensitivity outranks approval).
            ConnectionItem(id: blocked, integration: .obsidian, title: "Fixture private", state: .approved, sensitivity: .blocked),
            ConnectionItem(id: revoked, integration: .shareInbox, title: "Fixture revoked", state: .revoked, sensitivity: .low),
            ConnectionItem(id: expired, integration: .calendar, title: "Fixture expired", state: .expired, sensitivity: .low),
            // Still `.approved` from the last refresh, but its expiry has passed by play time.
            ConnectionItem(id: lapsed, integration: .calendar, title: "Fixture lapsed", state: .approved,
                           expiresAt: eight.addingTimeInterval(-60), sensitivity: .low),
        ])
        let spoken = contentIDs(liveQueued(studio))
        XCTAssertEqual(spoken, [control], "only the control row (\(spoken.count) content cues)")
        for silent in [blocked, revoked, expired, lapsed] { XCTAssertFalse(spoken.contains(silent), "\(silent)") }
    }

    // MARK: Sentinel gate 3: calendar, share and notes cues stay on-device with cloud voice on

    private struct BodyRecorder: HTTPTransport {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var bodies: [Data] = []
        }
        let box = Box()
        var bodies: [Data] { box.lock.withLock { box.bodies } }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            box.lock.withLock { box.bodies.append(request.httpBody ?? Data()) }
            let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "1.0", "X-Billed-Characters": "20"]
            return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
        }
    }

    private struct DeviceVoice: VoiceProvider {
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            VoiceArtifact(data: Data("d".utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
        }
    }

    func testBriefingCuesFromCalendarShareAndNotesRenderOnDeviceWithCloudVoiceOn() async throws {
        let event = UUID(), shared = UUID(), note = UUID()
        let titles = ["Fixture standup", "Fixture reminder", "Fixture grocery"]
        let studio = await liveStudio([
            ConnectionItem(id: event, integration: .calendar, title: titles[0], state: .approved, sensitivity: .low),
            ConnectionItem(id: shared, integration: .shareInbox, title: titles[1], state: .approved, sensitivity: .medium),
            ConnectionItem(id: note, integration: .obsidian, title: titles[2], state: .approved, sensitivity: .medium),
        ])
        let handoff = try XCTUnwrap(liveQueued(studio))
        XCTAssertEqual(Set(contentIDs(handoff)), [event, shared, note])

        // Cloud voice on: every gate of `PremiumVoiceRoutes.compose` passes, ElevenLabs is first.
        let transport = BodyRecorder()
        let device = VoiceRoute(providerID: "avspeech", provider: DeviceVoice(), voice: VoiceProfile(id: "standard", name: "Host"))
        let composed = PremiumVoiceRoutes.compose(
            onDevice: [device], paidProvidersEnabled: true, selectedVoiceID: "g7LVvkPWALzPxOQbF6OE",
            credentials: PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "fixture-token"),
            pinnedHosts: ["aerodj-tts.vercel.app"], transport: transport)
        guard case .included = composed.decision else { return XCTFail("cloud voice must be on for this gate") }
        let renderer = VoiceRenderer(routes: composed.routes, budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache(), revocations: NarrationRevocations())

        let tracks = djTracks(8, origin: .catalog)
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 2, stationName: "OnAirly")
        let plan = writer.plan(tracks: tracks, briefing: handoff, hour: 14)
        let briefingBreaks = plan.breaks.filter(\.hasBriefing)
        XCTAssertEqual(Set(briefingBreaks.flatMap(\.cues).filter(\.isContent).compactMap(\.sourceItemID)), [event, shared, note])

        var deviceRendered: Set<UUID> = []
        for djBreak in briefingBreaks {
            let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", talkOverEnabled: { false })
            let done = AsyncStream<Void>.makeStream()
            await preparer.observe { event in
                switch event {
                case .prepared, .skipped: done.continuation.yield()
                case .preparing: break
                }
            }
            await preparer.prepare(djBreak, deadline: .seconds(5), onDeviceOnly: false)
            for await _ in done.stream { break }
            guard case .ready(let ready) = await preparer.takeBreak(afterTrack: djBreak.afterTrack) else {
                return XCTFail("the briefing break renders on the device voice")
            }
            for cue in djBreak.cues where cue.isContent {
                let clip = try XCTUnwrap(ready.clips.first { $0.cueID == cue.id })
                XCTAssertEqual(clip.audio.providerID, "avspeech", "briefing cue \(cue.source.map { "\($0)" } ?? "?") stays on-device")
                if let id = cue.sourceItemID { deviceRendered.insert(id) }
            }
        }
        XCTAssertEqual(deviceRendered, [event, shared, note])
        let sent = transport.bodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertFalse(sent.isEmpty, "the cloud route is live: catalog lines in the same breaks used it")
        for title in titles {
            XCTAssertFalse(sent.contains { $0.contains(title) }, "no personal text reached the cloud route")
        }
    }
}

// MARK: Once a day, at any hour (owner, Oct 29)

final class BriefingOncePerDayTests: LiveBriefingFixture {
    private func oneRowStudio() async -> (StudioPresentationModel, UUID) {
        let id = UUID()
        let studio = await liveStudio([
            ConnectionItem(id: id, integration: .calendar, title: "Fixture standup", state: .approved, sensitivity: .low),
        ])
        return (studio, id)
    }

    private func fires(_ studio: StudioPresentationModel, _ days: BriefingDayLedger, _ clock: DayClock) -> Bool {
        let handoff = LiveQueueBriefing.provider(studio: studio, days: days, calendar: calendar(clock.timeZone))()
        return !contentIDs(handoff.forQueue()).isEmpty
    }

    func testFiresOnTheFirstSessionOfTheDayAtAnyHour() async {
        let (studio, _) = await oneRowStudio()
        for hour in [3, 14, 23] {
            let clock = DayClock(at(newYork, 2026, 10, 29, hour), newYork)
            XCTAssertTrue(fires(studio, clock.ledger(), clock), "first session at \(hour):00 briefs")
        }
    }

    func testDoesNotFireASecondTimeTheSameDay() async {
        let (studio, _) = await oneRowStudio()
        let clock = DayClock(at(newYork, 2026, 10, 29, 3), newYork)
        let days = clock.ledger()
        XCTAssertTrue(fires(studio, days, clock))
        days.markBriefedToday()
        for hour in [3, 9, 14, 23] {
            clock.now = at(newYork, 2026, 10, 29, hour, 59)
            XCTAssertFalse(fires(studio, days, clock), "already briefed: \(hour):59 stays quiet")
        }
    }

    func testFiresAgainAfterLocalMidnight() async {
        let (studio, _) = await oneRowStudio()
        let clock = DayClock(at(newYork, 2026, 10, 29, 23, 30), newYork)
        let days = clock.ledger()
        days.markBriefedToday()
        XCTAssertFalse(fires(studio, days, clock))
        clock.now = at(newYork, 2026, 10, 30, 0, 10)   // 40 minutes later, a new local day
        XCTAssertTrue(fires(studio, days, clock), "a new local day briefs again")
    }

    func testFlyingEastPastMidnightIsANewDay() async {
        let (studio, _) = await oneRowStudio()
        // Briefed 20:00 Oct 29 in New York (00:00Z Oct 30).
        let clock = DayClock(at(newYork, 2026, 10, 29, 20), newYork)
        let days = clock.ledger()
        days.markBriefedToday()
        XCTAssertEqual(days.today, LocalDay(year: 2026, month: 10, day: 29))
        // Three hours later the phone is in Tokyo: 12:00 Oct 30 there.
        clock.now = clock.now.addingTimeInterval(3 * 3600)
        clock.timeZone = tokyo
        XCTAssertEqual(days.today, LocalDay(year: 2026, month: 10, day: 30))
        XCTAssertTrue(fires(studio, days, clock), "past local midnight in the new zone: a new day")
    }

    func testGoingBackWestIntoABriefedDayDoesNotBriefAgain() async {
        let (studio, _) = await oneRowStudio()
        // Briefed 08:00 Oct 30 in Tokyo (23:00Z Oct 29).
        let clock = DayClock(at(tokyo, 2026, 10, 30, 8), tokyo)
        let days = clock.ledger()
        days.markBriefedToday()
        // Three hours later in Honolulu: 16:00 Oct 29 there, a day that is already behind us.
        clock.now = clock.now.addingTimeInterval(3 * 3600)
        clock.timeZone = honolulu
        XCTAssertEqual(days.today, LocalDay(year: 2026, month: 10, day: 29))
        XCTAssertFalse(fires(studio, days, clock), "west into an already-briefed day: no second briefing")
        days.markBriefedToday()
        XCTAssertEqual(days.today < LocalDay(year: 2026, month: 10, day: 30), true)
        // The next local day after the briefed one still briefs.
        clock.now = at(honolulu, 2026, 10, 31, 7)
        XCTAssertTrue(fires(studio, days, clock))
    }

    func testStoresOnlyTheLocalDayInUserDefaults() {
        let suite = "onairly.briefing.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = DayClock(at(newYork, 2026, 10, 29, 23, 45), newYork)
        let days = clock.ledger(UserDefaultsBriefingDayStore(defaults: defaults))
        XCTAssertFalse(days.hasBriefedToday)
        days.markBriefedToday()
        XCTAssertEqual(defaults.string(forKey: UserDefaultsBriefingDayStore.defaultKey), "2026-10-29",
                       "the local calendar day, not a timestamp")
        let reread = clock.ledger(UserDefaultsBriefingDayStore(defaults: defaults))
        XCTAssertTrue(reread.hasBriefedToday, "survives a relaunch")
    }

    // The marker is set when the briefing's audio starts, not when it is planned or handed out.

    private func session(_ days: BriefingDayLedger) async -> (DJBreakSession, DJPresentationStore) {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([.calendar: .granted]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 },
                                     now: { days.now() }, briefingDays: days)
        await session.start()
        return (session, dj)
    }

    private func briefing(_ item: UUID) -> NarrationHandoff {
        let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: "From your calendar: fixture standup.",
                               estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .calendar, provenance: "fixture:c1")
        return NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600)
    }

    private func readyBreak(_ s: DJBreakSession, _ dj: DJPresentationStore, item: UUID, source: ConnectionItem) async {
        await s.queueStarted(djTracks(8), briefing: briefing(item), sources: [source])
        await s.songStarted(index: 0, remaining: .seconds(180))
        for await state in dj.updates() { if case .ready = state { return } }
    }

    func testMarkerIsSetOnlyWhenTheBriefingStartsPlaying() async {
        let clock = DayClock(at(newYork, 2026, 10, 29, 14), newYork)
        let days = clock.ledger()
        let (s, dj) = await session(days)
        let item = UUID()
        let source = ConnectionItem(id: item, integration: .calendar, title: "Fixture standup", state: .approved, sensitivity: .low)

        // Planned, rendered, handed out, then the audio fails: not briefed, it may run later today.
        await readyBreak(s, dj, item: item, source: source)
        XCTAssertFalse(days.hasBriefedToday, "planned and rendered is not played")
        let failed = await s.naturalBoundary(afterTrack: 0)
        XCTAssertTrue(failed?.includesBriefing ?? false)
        XCTAssertFalse(days.hasBriefedToday, "handed out is not played")
        s.playbackFailed(afterTrack: 0)
        XCTAssertFalse(days.hasBriefedToday, "a failed briefing can still run later today")

        // Planned and cut before its boundary (skipped): still not briefed.
        await readyBreak(s, dj, item: item, source: source)
        await s.songCut(afterTrack: 0)
        XCTAssertFalse(days.hasBriefedToday, "a skipped briefing can still run later today")

        // Later the same day it plays: now it is briefed.
        await readyBreak(s, dj, item: item, source: source)
        _ = await s.naturalBoundary(afterTrack: 0)
        s.playbackStarted(afterTrack: 0)
        XCTAssertTrue(days.hasBriefedToday, "audible briefing marks the day")
        s.playbackFinished(afterTrack: 0)
    }

    func testAPlainBreakDoesNotMarkTheDay() async {
        let clock = DayClock(at(newYork, 2026, 10, 29, 14), newYork)
        let days = clock.ledger()
        let (s, dj) = await session(days)
        await s.queueStarted(djTracks(8))
        await s.songStarted(index: 0, remaining: .seconds(180))
        guard s.plannedBoundaries.first == 0 else { return XCTFail("seed 1 plans break 0") }
        for await state in dj.updates() { if case .ready = state { break } }
        _ = await s.naturalBoundary(afterTrack: 0)
        s.playbackStarted(afterTrack: 0)
        XCTAssertFalse(days.hasBriefedToday, "only a briefing break marks the day")
    }

    /// Provider and session share one ledger, as `PlayerView` wires it.
    func testPlayedBriefingSilencesTheProviderForTheRestOfTheDay() async {
        let (studio, row) = await oneRowStudio()
        let clock = DayClock(at(newYork, 2026, 10, 29, 3), newYork)
        let days = clock.ledger()
        let (s, dj) = await session(days)
        let handoff = LiveQueueBriefing.provider(studio: studio, days: days, calendar: calendar(newYork))().forQueue()
        XCTAssertEqual(contentIDs(handoff), [row])
        let source = studio.connections.items[0]
        await s.queueStarted(djTracks(8), briefing: handoff, sources: [source])
        await s.songStarted(index: 0, remaining: .seconds(180))
        for await state in dj.updates() { if case .ready = state { break } }
        _ = await s.naturalBoundary(afterTrack: 0)
        s.playbackStarted(afterTrack: 0)
        clock.now = at(newYork, 2026, 10, 29, 22)
        XCTAssertFalse(fires(studio, days, clock), "second session the same day: no briefing")
        clock.now = at(newYork, 2026, 10, 30, 6)
        XCTAssertTrue(fires(studio, days, clock), "next day: briefs again")
    }
}
