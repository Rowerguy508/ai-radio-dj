import Foundation
import XCTest
@testable import AeroDJCore

/// Lane 2 time checks through `DJBreakSession` (-Fry): the spoken time comes from the session's
/// injected `now()`, and a planned time check that would air more than 2 min from that reading is
/// dropped when its song starts. Async methods throughout: Swift 6.2 Linux test discovery needs
/// them in a @MainActor test class.
private struct TimeVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class DJTimeCheckSessionTests: XCTestCase {
    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private final class Clock: @unchecked Sendable { var now: Date; init(_ now: Date) { self.now = now } }

    private func rig(seed: UInt64, clock: Clock) async -> DJBreakSession {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: TimeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed,
                                     hour: { 7 }, now: { clock.now }, calendar: eastern, clockStyle: .twelveHour)
        await session.start()
        return session
    }

    /// A seed whose queue-start plan has a time check, and its boundary.
    private func seededTimeCheck(clock: Clock) async -> (DJBreakSession, Int, DJBreak)? {
        for seed in UInt64(0)..<60 {
            let session = await rig(seed: seed, clock: clock)
            await session.queueStarted(djTracks(90))
            if let (k, b) = session.testPlannedBreaks.first(where: { $0.value.timeCheckCueID != nil }) { return (session, k, b) }
        }
        return nil
    }

    func testSessionSpeaksItsInjectedNowAndAtMostOneTimeCheckPerPlan() async {
        let clock = Clock(eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7, minute: 40))!)
        var withOne = 0
        for seed in UInt64(0)..<30 {
            let session = await rig(seed: seed, clock: clock)
            await session.queueStarted(djTracks(90))
            let checks = session.testPlannedBreaks.values.filter { $0.timeCheckCueID != nil }
            XCTAssertLessThanOrEqual(checks.count, 1, "seed \(seed): one clock reading per plan")
            for b in checks {
                withOne += 1
                let cue = b.cues.first { $0.id == b.timeCheckCueID }
                XCTAssertTrue(cue?.text.contains("7:40") == true, cue?.text ?? "-")
                XCTAssertEqual(b.attributions[b.timeCheckCueID!], .presenter)
                XCTAssertEqual(b.timeCheckPlannedAt, clock.now)
            }
        }
        XCTAssertGreaterThan(withOne, 0, "some seeds plan a time check")
    }

    func testStaleTimeCheckIsDroppedWhenItsSongStarts() async {
        let clock = Clock(eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7, minute: 40))!)
        guard let (session, k, planned) = await seededTimeCheck(clock: clock) else { return XCTFail("no seed planned one") }
        // Songs played for a while: the break now airs 20 minutes after the planning reading.
        clock.now = clock.now.addingTimeInterval(20 * 60)
        await session.songStarted(index: k, remaining: .seconds(60))
        let aired = session.testPlannedBreaks[k]
        XCTAssertNil(aired?.timeCheckCueID, "stale: dropped")
        XCTAssertFalse(aired?.cues.contains { $0.id == planned.timeCheckCueID } ?? false)
        XCTAssertEqual(aired?.cues.last?.id, planned.cues.last?.id, "the closing line stays")
    }

    func testFreshTimeCheckIsKeptWhenItAirsWithinTwoMinutes() async {
        let clock = Clock(eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7, minute: 40))!)
        guard let (session, k, planned) = await seededTimeCheck(clock: clock) else { return XCTFail("no seed planned one") }
        await session.songStarted(index: k, remaining: .seconds(90))     // airs 1.5 min after the reading
        XCTAssertEqual(session.testPlannedBreaks[k]?.timeCheckCueID, planned.timeCheckCueID)
    }
}
