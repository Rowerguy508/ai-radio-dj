#if DEBUG
import XCTest
@testable import AeroDJCore

/// Counts calls; stands in for a paid provider that must never be reached.
final class CountingVoice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { _calls += 1 }
        let words = text.split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: text.count, provider: "counting", cacheKey: nil)
    }
}

final class TestStationTests: XCTestCase {
    private let newYork: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c
    }()
    private var now: Date { newYork.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 7))! }

    func testUsesFinalBetaDefaults() {
        XCTAssertEqual(TestStation.paidDailyCapMicrodollars, 0)
        XCTAssertEqual(TestStation.cadence.talkFraction, 0.3)
        XCTAssertEqual(TestStation.cadence.maxTransitionSeconds, 12)
        XCTAssertEqual(TestStation.cadence.maxBriefingBreakSeconds, 45)
        XCTAssertEqual(TestStation.cadence, DJCadence(), "same as the shipped defaults")
        XCTAssertEqual(TestStation.cacheRetention, 7 * 24 * 3600)
        XCTAssertEqual(TestStation.configuration.commentary, .occasional)
        XCTAssertEqual(TestStation.configuration.cadence(base: TestStation.cadence), TestStation.cadence)
    }

    func testEnabledOnlyByExplicitFlag() throws {
        let suite = "TestStationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(TestStation.isEnabled(defaults: defaults), "off unless asked for")
        defaults.set(true, forKey: TestStation.defaultsKey)
        XCTAssertTrue(TestStation.isEnabled(defaults: defaults))
    }

    func testZeroBudgetRefusesAnyPaidReservation() async {
        let budget = TestStation.makeBudget()
        let r = await budget.reserve(userID: TestStation.userID, microdollars: 1)
        XCTAssertNil(r)
    }

    func testPaidRoutesAreDroppedAndNeverCalled() async {
        let paid = CountingVoice(), free = CountingVoice()
        let renderer = TestStation.makeRenderer(routes: [
            VoiceRoute(providerID: "cartesia", provider: paid, voice: .init(id: "p", name: "Paid"),
                       microdollarsPerThousandCharacters: 50_000),
            VoiceRoute(providerID: "avspeech", provider: free, voice: .init(id: "d", name: "Device")),
        ], cache: InMemoryAudioCache())
        XCTAssertEqual(renderer.routes.map(\.providerID), ["avspeech"])
        XCTAssertTrue(renderer.routes.allSatisfy { !$0.isPaid })

        let sources = TestStation.fixtureSources(now: now, calendar: newYork)
        let fixed = now
        let engine = MorningBriefingEngine(calendar: newYork, now: { fixed })
        let handoff = await engine.briefing(from: sources).handoff(maxSpokenSeconds: engine.configuration.maxSpokenSeconds)
        let rendered = await renderer.render(handoff, userID: TestStation.userID, stationID: TestStation.stationID)
        XCTAssertFalse(rendered.clips.isEmpty)
        XCTAssertEqual(paid.calls, 0)
        XCTAssertGreaterThan(free.calls, 0)
        let spent = await renderer.budget.committed(userID: TestStation.userID)
        XCTAssertEqual(spent, 0)
    }

    func testFixturesAreSyntheticLabeledAndInMemoryOnly() async throws {
        let sources = TestStation.fixtureSources(now: now, calendar: newYork)
        XCTAssertTrue(sources.allSatisfy { $0 is FixtureContextSource }, "no EventKit, Obsidian file or share-inbox reader")
        XCTAssertFalse(sources.contains { $0 is CalendarContextSource || $0 is ObsidianContextSource })
        // FixtureContextSource stores only a kind and items: no reader, URL or framework handle.
        let fields = Mirror(reflecting: sources[0]).children.compactMap(\.label)
        XCTAssertEqual(fields, ["source", "items"])
        var items: [ContextItem] = []
        for s in sources { items += try await s.fetchItems() }
        XCTAssertEqual(Set(items.map { StationIntegration(source: $0.source) }), Set(StationIntegration.allCases))
        for item in items {
            XCTAssertTrue(item.title.hasPrefix("[TEST] "), item.title)
            XCTAssertTrue(item.provenance.hasPrefix(TestStation.provenancePrefix), item.provenance)
            XCTAssertEqual(item.sensitivity, .low)
            XCTAssertTrue(item.isNarratable(at: now))
            XCTAssertFalse(item.isNarratable(at: now.addingTimeInterval(86_400)), "expires end of day")
        }
    }

    func testFixtureBriefingIsAttributedToSyntheticProvenanceOnly() async {
        let fixed = now
        let engine = MorningBriefingEngine(calendar: newYork, now: { fixed })
        let script = await engine.briefing(from: TestStation.fixtureSources(now: now, calendar: newYork))
        let sourced = script.segments.filter { $0.sourceItemID != nil }
        XCTAssertFalse(sourced.isEmpty)
        XCTAssertTrue(sourced.allSatisfy { $0.provenance?.hasPrefix(TestStation.provenancePrefix) == true })
        XCTAssertTrue(script.unavailableSources.isEmpty)

        var writer = DJScriptWriter(cadence: TestStation.cadence, seed: 1)
        let tracks = (0..<8).map { DJTrack(id: "t\($0)", title: "Song \($0)", artist: "Artist \($0)") }
        let plan = writer.plan(tracks: tracks, briefing: script.handoff(maxSpokenSeconds: engine.configuration.maxSpokenSeconds), hour: 7)
        for b in plan.breaks {
            XCTAssertLessThanOrEqual(b.estimatedSeconds, Double(b.hasBriefing ? 45 : 12) + 0.001)
            for case .personalContext(_, _, let provenance) in b.attributions.values {
                XCTAssertTrue(provenance.hasPrefix(TestStation.provenancePrefix))
            }
        }
    }

    @MainActor
    func testStationModelLoadsWithFixtureConsentOnly() async {
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: TestStation.configuration))),
            consent: TestStation.fixtureConsent)
        await model.load()
        XCTAssertEqual(model.usableIntegrations, Set(StationIntegration.allCases))
        XCTAssertEqual(model.active.cadence(), TestStation.cadence)
    }
}
#endif

#if DEBUG
@MainActor
final class TestStationFixtureConnectionTests: XCTestCase {
    func testConnectionsShowTheNarratedFixturesAndRevokeRemovesThemFromTheBriefing() async throws {
        let fixtures = TestStationFixtures()
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: TestStation.configuration))),
            consent: TestStation.fixtureConsent)
        await station.load()
        let connections = ConnectionsModel(station: station, sourceReader: fixtures.sourceReader(),
                                           providers: fixtures.providers(), purger: NoopNarrationPurger())
        await connections.refresh()

        XCTAssertTrue(connections.sources.allSatisfy(\.mayShowConnected), "fixture sources are truthfully connected")
        let shown = Set(StationIntegration.allCases.flatMap { connections.items(for: $0).map(\.id) })
        XCTAssertEqual(shown, Set(fixtures.items.map(\.id)), "Connections lists exactly the narrated fixtures")
        XCTAssertTrue(fixtures.items.allSatisfy { $0.provenance.hasPrefix(TestStation.provenancePrefix) })

        let note = try XCTUnwrap(fixtures.items.first { $0.source == .obsidian })
        _ = await connections.perform(.revoke, on: note.id)
        var narrated: [ContextItem] = []
        for source in fixtures.contextSources() { narrated += try await source.fetchItems() }
        XCTAssertFalse(narrated.contains { $0.id == note.id }, "a revoked fixture leaves the next briefing")
        XCTAssertEqual(connections.items(for: .obsidian).first?.state, .revoked)
    }
}

#endif
