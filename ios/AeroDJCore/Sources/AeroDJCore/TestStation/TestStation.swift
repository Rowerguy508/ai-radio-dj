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
#endif
