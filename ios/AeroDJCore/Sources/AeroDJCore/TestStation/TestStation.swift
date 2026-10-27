#if DEBUG
import Foundation

// Safe test station for development builds on the owner's device.
// Compiled only when DEBUG is set: it does not exist in Release builds
// (checked by ios/scripts/check-release-excludes-test-station.sh in CI).
//
// - Voice: on-device only, $0 paid cap; paid routes are removed before the renderer is built.
// - Context: synthetic fixtures only, labeled "[TEST]", provenance "fixture:synthetic/...".
//   No EventKit, no files, no share inbox. Consent is granted for these fixtures only.
// - Settings: final beta defaults (30% cadence, 12 s breaks, 45 s briefing cap, 7-day cache).

public enum TestStation {
    /// Launch argument (`-AeroDJTestStation YES` in the Xcode scheme) or debug setting
    /// (`UserDefaults` bool under the same key). Launch arguments populate UserDefaults.
    public static let defaultsKey = "AeroDJTestStation"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static let stationID = "test-station"
    public static let userID = "test-user"
    public static let provenancePrefix = "fixture:synthetic/"

    // MARK: Beta defaults

    public static let paidDailyCapMicrodollars = 0
    public static let cadence = DJCadence(talkFraction: 0.3, minSongsBetweenBreaks: 2,
                                          maxTransitionSeconds: 12, maxBriefingBreakSeconds: 45)
    public static let cacheRetention: TimeInterval = AudioCacheRetention.maximum

    /// Beta-default settings, with only the fixture-backed integrations requested.
    public static let configuration = StationConfiguration(
        genres: ["pop", "indie"],
        moods: ["bright"],
        personality: .warm,
        commentary: .occasional,
        briefing: .init(enabled: true, window: .init(startMinute: 0, durationMinutes: 240), targetSeconds: 300),
        requestedIntegrations: Set(StationIntegration.allCases)
    )

    /// Consent for the fixture sources only. Never pair this with a real context source.
    public static let fixtureConsent = StaticIntegrationConsent(
        Dictionary(uniqueKeysWithValues: StationIntegration.allCases.map { ($0, ConsentState.granted) }))

    // MARK: Voice

    /// $0 budget: any paid reservation is refused.
    public static func makeBudget() -> VoiceBudget {
        VoiceBudget(dailyCapMicrodollars: paidDailyCapMicrodollars)
    }

    /// Renderer with free routes only. Paid routes passed in are dropped, never called.
    /// Pass the app's `OnDeviceSpeechProvider` (AVSpeechSynthesizer) route.
    public static func makeRenderer(routes: [VoiceRoute], cache: any AudioCache) -> VoiceRenderer {
        VoiceRenderer(routes: routes.filter { !$0.isPaid }, budget: makeBudget(), cache: cache)
    }

    // MARK: Fixtures

    /// Synthetic, in-memory context sources. They read nothing from the device.
    public static func fixtureSources(now: Date = Date(), calendar: Calendar = .current) -> [any ContextSource] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        func item(_ kind: ContextSourceKind, _ title: String, _ summary: String, _ path: String, eventIn minutes: Double? = nil) -> ContextItem {
            ContextItem(source: kind, createdAt: now, eventAt: minutes.map { now.addingTimeInterval($0 * 60) },
                        title: "[TEST] " + title, summary: summary, sensitivity: .low, consent: .granted,
                        expiresAt: dayEnd, provenance: provenancePrefix + path)
        }
        return [
            FixtureContextSource(source: .calendar, items: [
                item(.calendar, "Fixture standup", "A sample meeting for testing the DJ.", "calendar/standup", eventIn: 90),
                item(.calendar, "Fixture lunch", "A sample lunch for testing the DJ.", "calendar/lunch", eventIn: 240),
            ]),
            FixtureContextSource(source: .userShared, items: [
                item(.userShared, "Fixture shared article", "A sample shared link about tide pools.", "share/article"),
            ]),
            FixtureContextSource(source: .obsidian, items: [
                item(.obsidian, "Fixture note", "Water the sample ferns.", "notes/ferns"),
            ]),
        ]
    }
}

/// Returns fixed items. Holds no reader, store, URL or framework handle.
public struct FixtureContextSource: ContextSource {
    public let source: ContextSourceKind
    public let items: [ContextItem]
    public init(source: ContextSourceKind, items: [ContextItem]) {
        self.source = source
        self.items = items
    }
    public func fetchItems() async throws -> [ContextItem] { items }
}
/// One synthetic fixture set shared by the briefing and the Connections screen, so the test
/// station shows the same items it narrates and a revoke or delete in Connections removes the
/// item from the next briefing. Holds no reader, store, URL or framework handle.
public actor TestStationFixtures {
    public nonisolated let items: [ContextItem]
    private var states: [UUID: ConnectionItemState]

    public init(now: Date = Date(), calendar: Calendar = .current) {
        items = TestStation.fixtureSources(now: now, calendar: calendar)
            .compactMap { ($0 as? FixtureContextSource)?.items }.flatMap { $0 }
        states = Dictionary(uniqueKeysWithValues: items.map { ($0.id, ConnectionItemState.approved) })
    }

    /// Context sources for the briefing: only items still approved in Connections.
    /// With `reader`, a source the listener stopped using (selection cleared) contributes
    /// nothing, as a live source with no picked calendars or notes would.
    public nonisolated func contextSources(reader: StaticConnectionSourceReader? = nil) -> [any ContextSource] {
        Dictionary(grouping: items, by: \.source).keys.sorted { $0.rawValue < $1.rawValue }
            .map { FixtureBackedSource(source: $0, fixtures: self, reader: reader) }
    }

    /// One provider per integration, backed by the same items.
    public nonisolated func providers(reader: StaticConnectionSourceReader? = nil) -> [any ConnectionItemProvider] {
        Set(items.map { StationIntegration(source: $0.source) }).sorted { $0.rawValue < $1.rawValue }
            .map { FixtureConnectionProvider(integration: $0, fixtures: self, reader: reader) }
    }

    /// Calendar and notes report the fixture selection; nothing on the device is read.
    public nonisolated func sourceReader() -> StaticConnectionSourceReader {
        StaticConnectionSourceReader(
            calendar: .init(access: .fullAccess, calendars: [.init(id: "fixture", title: "[TEST] Fixture calendar")],
                            selectedCalendarIDs: ["fixture"]),
            obsidian: .valid(fileCount: items.filter { $0.source == .obsidian }.count))
    }

    func narratable(_ source: ContextSourceKind) -> [ContextItem] {
        items.filter { $0.source == source && states[$0.id] == .approved }
    }

    func connectionItems(_ integration: StationIntegration, now: Date) -> [ConnectionItem] {
        items.filter { StationIntegration(source: $0.source) == integration }.compactMap { item in
            guard let state = states[item.id] else { return nil }
            let shown = item.expiresAt.map { $0 <= now } == true ? ConnectionItemState.expired : state
            return ConnectionItem(id: item.id, integration: integration, title: item.title, state: shown,
                                  expiresAt: item.expiresAt, sensitivity: item.sensitivity)
        }
    }

    func perform(_ action: ConnectionAction, on id: UUID) {
        guard states[id] != nil else { return }
        switch action {
        case .approve, .readAnyway: states[id] = .approved
        case .revoke: states[id] = .revoked
        case .delete: states[id] = nil
        default: break
        }
    }
}

/// Whether the fixture selection for `integration` is still in use (Stop using clears it).
private func fixtureSelectionInUse(_ integration: StationIntegration, reader: StaticConnectionSourceReader?) async -> Bool {
    guard let reader else { return true }
    switch integration {
    case .calendar: return await !reader.calendar.selectedCalendarIDs.isEmpty
    case .obsidian: if case .notSelected = await reader.obsidian { return false } else { return true }
    case .shareInbox: return true
    }
}

struct FixtureBackedSource: ContextSource {
    let source: ContextSourceKind
    let fixtures: TestStationFixtures
    var reader: StaticConnectionSourceReader? = nil
    func fetchItems() async throws -> [ContextItem] {
        guard await fixtureSelectionInUse(StationIntegration(source: source), reader: reader) else { return [] }
        return await fixtures.narratable(source)
    }
}

struct FixtureConnectionProvider: ConnectionItemProvider {
    let integration: StationIntegration
    let fixtures: TestStationFixtures
    var reader: StaticConnectionSourceReader? = nil
    func items(now: Date) async throws -> [ConnectionItem] {
        guard await fixtureSelectionInUse(integration, reader: reader) else { return [] }
        return await fixtures.connectionItems(integration, now: now)
    }
    func perform(_ action: ConnectionAction, on id: UUID) async throws { await fixtures.perform(action, on: id) }
}

extension ConnectionsComposition {
    /// Test station only: synthetic fixtures for every Connections source and the briefing.
    public static func testStationFixtures(_ fixtures: TestStationFixtures) -> ConnectionsComposition {
        // One reader shared with the providers: "Stop using" a source clears its fixture
        // selection, and its items then disappear and stop narrating, as they do live.
        let reader = fixtures.sourceReader()
        return ConnectionsComposition(sourceReader: reader, consent: TestStation.fixtureConsent,
                                      providers: fixtures.providers(reader: reader),
                                      contextSources: fixtures.contextSources(reader: reader), notes: nil)
    }
}
#endif
