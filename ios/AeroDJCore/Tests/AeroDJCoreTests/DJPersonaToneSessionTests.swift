import XCTest
@testable import AeroDJCore

/// Persona tone hook (-Fry, agreed with Echo): the live session's writer speaks in the station's
/// DJ personality (`EditorialTone.forPersonality`), warm by default, and follows a personality
/// change on the next replan. Async methods throughout: Swift 6.2 Linux test discovery needs
/// them in a @MainActor test class.
private struct ToneVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class DJPersonaToneSessionTests: XCTestCase {
    /// A session that is not `start()`ed: tests hand it station changes themselves, so nothing
    /// races the change stream.
    private func rig(_ config: StationConfiguration, seed: UInt64 = 7) async -> (DJBreakSession, StationConfigurationModel) {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: ToneVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        return (DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed, hour: { 14 }), station)
    }

    /// A template as a whole-line pattern: each `{placeholder}` matches any text.
    private static func pattern(_ template: String) -> NSRegularExpression {
        let parts = template.components(separatedBy: "{").enumerated().map { i, part -> String in
            guard i > 0, let close = part.firstIndex(of: "}") else { return NSRegularExpression.escapedPattern(for: part) }
            return ".+" + NSRegularExpression.escapedPattern(for: String(part[part.index(after: close)...]))
        }
        return try! NSRegularExpression(pattern: "^" + parts.joined() + "$")
    }

    private static func matches(_ text: String, _ patterns: [NSRegularExpression]) -> Bool {
        patterns.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }

    /// The spoken presenter lines planned after `afterTrack` (no briefing content, no time check:
    /// that line is written at render time from its own pools).
    private func lines(_ session: DJBreakSession, after afterTrack: Int = -1) -> [String] {
        session.testPlannedBreaks.filter { $0.key > afterTrack }.values.flatMap { b in
            b.cues.filter { !$0.isContent && $0.id != b.timeCheckCueID }.map(\.text)
        }
    }

    private func bank(_ p: DJPersonality) -> [NSRegularExpression] {
        EditorialTone.forPersonality(p).allLines.map(Self.pattern)
    }

    func testDefaultStationSpeaksWarm() async {
        let (session, _) = await rig(StationConfiguration(commentary: .frequent))
        XCTAssertEqual(session.testWriterTone, .warm, "a station with no personality set keeps warm")
        await session.queueStarted(djTracks(40))
        let spoken = lines(session)
        XCTAssertFalse(spoken.isEmpty)
        for text in spoken { XCTAssertTrue(Self.matches(text, bank(.warm)), "warm line: \(text)") }
        await session.stop()
    }

    func testTheSessionWriterUsesEachPersonalitysTone() async {
        for p in DJPersonality.allCases {
            let (session, _) = await rig(StationConfiguration(personality: p, commentary: .frequent))
            XCTAssertEqual(session.testWriterTone, .forPersonality(p), "\(p)")
            await session.queueStarted(djTracks(40))
            let spoken = lines(session)
            XCTAssertFalse(spoken.isEmpty, "\(p): breaks planned")
            for text in spoken { XCTAssertTrue(Self.matches(text, bank(p)), "\(p) line from another bank: \(text)") }
            if p != .warm {
                XCTAssertTrue(spoken.contains { !Self.matches($0, bank(.warm)) }, "\(p): speaks lines warm never would")
            }
            await session.stop()
        }
    }

    /// Warm -> upbeat has the same cadence, so before the hook nothing re-planned and the
    /// breaks still to come stayed warm. The playing song's break is kept as planned.
    func testAPersonalityChangeRePlansTheBreaksToComeInTheNewTone() async {
        for target in DJPersonality.allCases where target != .warm {
            let (session, station) = await rig(StationConfiguration(commentary: .frequent))
            await session.queueStarted(djTracks(60))
            await session.songStarted(index: 12, remaining: .seconds(180))
            let kept = session.testPlannedBreaks.filter { $0.key <= 12 }
            let changes = station.changes()
            await station.setPersonality(target)
            await station.saveChanges()
            var handled = false
            for await change in changes where change.active.personality == target {
                await session.stationChanged(change)
                handled = true
                break
            }
            XCTAssertTrue(handled, "\(target): the save published a change")
            XCTAssertEqual(session.testWriterTone, .forPersonality(target), "\(target): writer follows the station")
            XCTAssertEqual(session.testPlannedBreaks.filter { $0.key <= 12 }.mapValues(\.cues.count),
                           kept.mapValues(\.cues.count), "\(target): breaks through the playing song are kept")
            let after = lines(session, after: 12)
            XCTAssertFalse(after.isEmpty, "\(target): breaks re-planned after the playing song")
            for text in after { XCTAssertTrue(Self.matches(text, bank(target)), "\(target) after change: \(text)") }
            XCTAssertTrue(after.contains { !Self.matches($0, bank(.warm)) }, "\(target): no longer warm")
            await session.stop()
        }
    }

    /// A new queue after a personality change (station switch) plans in the new tone too.
    func testANewQueueAfterAChangeUsesTheStationsPersonality() async {
        let (session, station) = await rig(StationConfiguration(commentary: .frequent))
        await session.queueStarted(djTracks(30))
        let changes = station.changes()
        await station.setPersonality(.laidBack)
        await station.saveChanges()
        for await change in changes where change.active.personality == .laidBack {
            await session.stationChanged(change)
            break
        }
        await session.queueStarted(djTracks(30))
        XCTAssertEqual(session.testWriterTone, .laidBack)
        for text in lines(session) { XCTAssertTrue(Self.matches(text, bank(.laidBack)), "laid-back: \(text)") }
        await session.stop()
    }

    /// The same personality re-planned (a cadence-only change) keeps the writer's tone, so the
    /// pools' rotation is not reset.
    func testSetToneIsANoOpForTheSameTone() async {
        var writer = DJScriptWriter(seed: 3, tone: .upbeat, shapes: .natural)
        let before = writer.plan(tracks: djTracks(20), briefing: nil, hour: 14).breaks.flatMap(\.cues).map(\.text)
        var control = DJScriptWriter(seed: 3, tone: .upbeat, shapes: .natural)
        _ = control.plan(tracks: djTracks(20), briefing: nil, hour: 14)
        writer.setTone(.upbeat)
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(writer.plan(tracks: djTracks(20), briefing: nil, hour: 14).breaks.flatMap(\.cues).map(\.text),
                       control.plan(tracks: djTracks(20), briefing: nil, hour: 14).breaks.flatMap(\.cues).map(\.text))
    }
}
