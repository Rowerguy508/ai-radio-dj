import XCTest
@testable import AeroDJCore

/// #332 (-Fry): a station start offers a personal update when the planner has one; a boundary
/// hand-off does not; consent stays fail-closed; and the start break carries at most one.
/// Eligibility (time of day, once-a-day, expiry) is the planner's and is not asserted here.
@MainActor
final class StationStartBriefingTests: XCTestCase {
    private func cue(_ item: UUID, order: Int, _ text: String) -> NarrationCue {
        NarrationCue(id: UUID(), order: order, group: 0, kind: .note, text: text,
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .obsidian,
                     provenance: "fixture:\(order)")
    }

    private func row(_ id: UUID, _ state: ConnectionItemState = .approved) -> ConnectionItem {
        ConnectionItem(id: id, integration: .obsidian, title: "[TEST] item", state: state, sensitivity: .medium)
    }

    private struct Fixture {
        var ids: [UUID]
        var cues: [NarrationCue]
        var handoff: ApprovedShowHandoff
    }

    /// Three approved personal updates the planner already chose (orders 1, 2, 3).
    private func threeApproved(states: [ConnectionItemState] = [.approved, .approved, .approved]) -> Fixture {
        let ids = (0..<3).map { _ in UUID() }
        let texts = ["From your notes: water the plants.", "From your notes: call the dentist.",
                     "From your notes: pack the charger."]
        // Reverse input order: the offer must pick by `order`, not by array position.
        let cues = (0..<3).reversed().map { cue(ids[$0], order: $0 + 1, texts[$0]) }
        let rows = zip(ids, states).map { row($0, $1) }
        let handoff = ApprovedShowHandoff(
            isMorningShow: true,
            approved: NarrationHandoff(cues: cues, maxSpokenSeconds: 60, experienceSeconds: 600),
            revokedOrUnapproved: false, connectionItems: rows)
        return Fixture(ids: ids, cues: cues, handoff: handoff)
    }

    func testStationStartsOfferTheFirstAvailableUpdateWithItsSources() throws {
        let f = threeApproved()
        for kind in [StationHandOffKind.idlePlayStart, .createdStationStart] {
            let offer = StationStartBriefing.offer(for: kind, briefing: { f.handoff })
            let content = try XCTUnwrap(offer.briefing, "\(kind)").cues.filter(\.isContent)
            XCTAssertEqual(content.map(\.sourceItemID), [f.ids[0]], "\(kind): the planner's first item")
            XCTAssertEqual(Set(offer.sources.map(\.id)), Set(f.ids), "\(kind): rows go to queueStarted's re-check")
        }
    }

    func testStartOfferCarriesAtMostOnePersonalUpdate() throws {
        XCTAssertEqual(StationStartBriefing.maxPersonalUpdatesOnStart, 1)
        let offer = StationStartBriefing.offer(for: .idlePlayStart, briefing: { self.threeApproved().handoff })
        XCTAssertEqual(try XCTUnwrap(offer.briefing).cues.filter(\.isContent).count, 1)
    }

    func testBoundaryHandOffNeverReadsOrOffersABriefing() {
        var reads = 0
        let f = threeApproved()
        let offer = StationStartBriefing.offer(for: .boundary, briefing: { reads += 1; return f.handoff })
        XCTAssertEqual(offer, .none)
        XCTAssertEqual(reads, 0, "a refill or boundary switch is not a station start")
        XCTAssertEqual(StationStartBriefing.offer(for: .idlePlayStart, briefing: nil), .none, "no provider: fails closed")
    }

    func testStartOfferStaysFailClosedOnConsent() throws {
        // Revoked / unapproved handoffs: nothing.
        let f = threeApproved()
        let revoked = ApprovedShowHandoff(isMorningShow: true, approved: f.handoff.approved,
                                          revokedOrUnapproved: true, connectionItems: f.handoff.connectionItems)
        XCTAssertEqual(StationStartBriefing.offer(for: .idlePlayStart, briefing: { revoked }), .none)
        XCTAssertEqual(StationStartBriefing.offer(for: .createdStationStart, briefing: { .unapproved }), .none)
        // The first item's row is no longer approved: it is skipped, never offered.
        let mixed = threeApproved(states: [.revoked, .pendingApproval, .approved])
        let offer = StationStartBriefing.offer(for: .idlePlayStart, briefing: { mixed.handoff })
        let content = try XCTUnwrap(offer.briefing).cues.filter(\.isContent)
        XCTAssertEqual(content.map(\.sourceItemID), [mixed.ids[2]])
        let none = threeApproved(states: [.revoked, .pendingApproval, .flaggedForReview])
        XCTAssertEqual(StationStartBriefing.offer(for: .idlePlayStart, briefing: { none.handoff }), .none)
    }

    /// The same provider a song tap uses (`LiveQueueBriefing.provider`), read at station start.
    /// Uses 08:00 so the test does not depend on the planner's time gate (Echo, #332).
    func testStationStartReadsTheSongTapProvider() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let at = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8))!
        let id = UUID()
        let studio = StartFixtureStudio(
            items: [ConnectionItem(id: id, integration: .calendar, title: "Design review", state: .approved)],
            preferences: BriefingPreferences(enabled: true, window: BriefingWindow(startMinute: 7 * 60, durationMinutes: 120)),
            sensitivity: [id: .low])
        let provider = LiveQueueBriefing.provider(studio: studio, now: { at }, calendar: calendar)
        let offer = StationStartBriefing.offer(for: .createdStationStart, briefing: provider)
        let content = try XCTUnwrap(offer.briefing).cues.filter(\.isContent)
        XCTAssertEqual(content.map(\.sourceItemID), [id])
        studio.sensitivity = [:]   // unknown sensitivity is blocked by the engine
        XCTAssertNil(StationStartBriefing.offer(for: .createdStationStart, briefing: provider).briefing?
            .cues.filter(\.isContent).first)
    }

    // MARK: - Through the DJ session: the start break

    private func session() async -> (DJBreakSession, DJPresentationStore) {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: StartPacedVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 3 })
        await session.start()
        return (session, dj)
    }

    private func startBreakContent(_ offer: StationStartOffer) async throws -> [NarrationCue] {
        let (session, dj) = await session()
        await session.queueStarted(djTracks(8), briefing: offer.briefing, sources: offer.sources)
        XCTAssertEqual(session.plannedBoundaries.first, 0, "the start break is the first boundary")
        await session.songStarted(index: 0, remaining: .seconds(180))
        for _ in 0..<500 { if case .ready = dj.studioState { break }; try? await Task.sleep(for: .milliseconds(10)) }
        let boundary = await session.naturalBoundary(afterTrack: 0)
        let handed = try XCTUnwrap(boundary)
        return handed.cues.filter(\.isContent)
    }

    func testStartBreakAirsExactlyOnePersonalUpdateWhenSeveralAreAvailable() async throws {
        let f = threeApproved()
        let offer = StationStartBriefing.offer(for: .idlePlayStart, briefing: { f.handoff })
        let aired = try await startBreakContent(offer)
        XCTAssertEqual(aired.count, 1, "at most one personal update on the start break")
        XCTAssertEqual(aired.first?.sourceItemID, f.ids[0])
    }

    // MARK: - Boundary hand-offs through the real feed (Orion, #332)

    private func feedStation(_ id: String) -> StationConfiguration {
        var c = StationConfiguration.default
        c.seeds = [StationSeed(kind: .artist, catalogID: id, name: "Station \(id)", source: .catalog)]
        c.reach = .related
        return c.validated()
    }

    private func feed() -> StationQueueFeed<String> {
        StationQueueFeed<String>(resolver: CatalogStationSeedResolver(catalog: StartFakeCatalog()),
                                 materialize: { $0.map(\.id) }, options: .init(limit: 10), day: { 42 },
                                 recentlyPlayed: { [] }, refillLead: 3, log: { _ in })
    }

    /// The kind the player derives right after `queueForNextSong` hands out a queue.
    private func boundaryKind(_ feed: StationQueueFeed<String>, after finished: Int, in queue: [String],
                              active: StationConfiguration) throws -> StationHandOffKind {
        _ = try XCTUnwrap(feed.queueForNextSong(after: finished, in: queue, active: active,
                                                playbackMayStart: true, sameSong: ==), "a hand-off happened")
        return StationHandOffKind(boundaryHandOff: feed.pendingHandOffTrigger)
    }

    func testBoundaryTakeoverByADifferentStationOffersExactlyOneUpdate() async throws {
        let feed = feed()
        let a = feedStation("a"), b = feedStation("b")
        feed.queueStarted(for: a)
        _ = await feed.prepare(b)
        let kind = try boundaryKind(feed, after: 0, in: ["a-0", "a-1", "a-2", "a-3", "a-4", "a-5"], active: b)
        XCTAssertEqual(kind, .stationSwitchAtBoundary)
        let f = threeApproved()
        let offer = StationStartBriefing.offer(for: kind, briefing: { f.handoff })
        XCTAssertEqual(try XCTUnwrap(offer.briefing).cues.filter(\.isContent).map(\.sourceItemID), [f.ids[0]])
        let aired = try await startBreakContent(offer)
        XCTAssertEqual(aired.map(\.sourceItemID), [f.ids[0]], "exactly one update on the takeover's first break")
    }

    func testBoundaryRefillOnTheSameStationOffersNone() async throws {
        let feed = feed()
        let a = feedStation("a")
        feed.queueStarted(for: a)
        _ = await feed.prepare(a)
        let kind = try boundaryKind(feed, after: 1, in: ["mine-0", "mine-1", "mine-2"], active: a)
        XCTAssertEqual(feed.pendingHandOffTrigger, .refill)
        XCTAssertEqual(kind, .boundary)
        var reads = 0
        let f = threeApproved()
        XCTAssertEqual(StationStartBriefing.offer(for: kind, briefing: { reads += 1; return f.handoff }), .none)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(StationHandOffKind(boundaryHandOff: nil), .boundary, "unknown trigger fails closed")
    }

    func testStartBreakAfterABoundaryHandOffHasNoPersonalUpdate() async throws {
        let f = threeApproved()
        let aired = try await startBreakContent(StationStartBriefing.offer(for: .boundary, briefing: { f.handoff }))
        XCTAssertTrue(aired.isEmpty)
    }
}

@MainActor
private final class StartFixtureStudio: LiveQueueStudio {
    var items: [ConnectionItem]
    var preferences: BriefingPreferences
    var sensitivity: [UUID: Sensitivity]
    var liveQueueBriefing: LiveQueueBriefingInput {
        LiveQueueBriefingInput(items: items, preferences: preferences, sensitivityByItemID: sensitivity)
    }
    init(items: [ConnectionItem], preferences: BriefingPreferences, sensitivity: [UUID: Sensitivity]) {
        self.items = items
        self.preferences = preferences
        self.sensitivity = sensitivity
    }
}

private struct StartPacedVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private struct StartFakeCatalog: StationSeedCatalog {
    private func songs(_ seed: StationSeed, _ tier: String, _ limit: Int) -> [StationCandidate] {
        (0..<min(limit, 8)).map { n in
            StationCandidate(track: TrackInfo(id: "\(seed.catalogID)-\(tier)-\(n)", title: "Title \(n)",
                                              artistName: "\(seed.catalogID)-artist-\(tier)-\(n % 3)"))
        }
    }
    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "core", limit) }
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "related", limit) }
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate] { songs(seed, "broad", limit) }
}
