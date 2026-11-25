import Foundation
import XCTest
@testable import AeroDJCore

/// #358 (-Fry): a station change re-opens the show in `queueStarted`, in the new station's name,
/// without fighting #472's aired-line memory. Same seeds do not re-greet. A second switch before
/// the first new opener airs leaves one greeting, for the final station. Revoked consent still
/// drops personal lines. Deterministic: fixed seed, fixed clock, no sleeps. A handed-out break
/// is injected as already rendered so nothing waits on a voice.
@MainActor
final class StationChangeRegreetTests: XCTestCase {
    private let seed: UInt64 = 1

    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// 2:10 PM, clear of a daylight-saving fold, so a time check can be said and spacing is real.
    private var fixedNow: Date {
        eastern.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 14, minute: 10))!
    }

    private func seeds(_ id: String) -> [StationSeed] {
        [StationSeed(kind: .artist, catalogID: id, name: "Artist \(id)")]
    }

    private func rig() async -> (DJBreakSession, StationConfigurationModel, InMemorySpokenLineMemoryStore) {
        var config = StationConfiguration(genres: ["jazz"], moods: ["mellow"], commentary: .frequent)
        config.seeds = seeds("first")
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let now = fixedNow
        let calendar = eastern
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: RegreetVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence(),
                                       now: { now })
        let memory = InMemorySpokenLineMemoryStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(),
                                     seed: seed, hour: { 14 }, now: { now },
                                     calendar: calendar, lineMemory: memory)
        await session.start()
        return (session, station, memory)
    }

    private func openers(_ session: DJBreakSession) -> [Int] {
        session.testPlannedBreaks.filter { $0.value.shape == .showOpener }.keys.sorted()
    }

    private func opener(_ session: DJBreakSession, _ label: String,
                        file: StaticString = #filePath, line: UInt = #line) -> DJBreak? {
        let keys = openers(session)
        XCTAssertEqual(keys.count, 1, "\(label): one show opener", file: file, line: line)
        return keys.first.flatMap { session.testPlannedBreaks[$0] }
    }

    /// Saves `edit` and waits until the session's observer has handled it.
    private func save(_ session: DJBreakSession, _ station: StationConfigurationModel,
                      _ edit: () async -> Void) async {
        await edit()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.testOnStationChangeHandled = { _ in
                session.testOnStationChangeHandled = nil
                done.resume()
            }
            Task { @MainActor in await station.saveChanges() }
        }
    }

    /// Moves `playing` past the opener so a later queue keeps it in the anti-repeat memory.
    /// Inside the boundary margin, so nothing renders.
    private func passTheOpener(_ session: DJBreakSession, _ label: String) async -> Int {
        let planned = opener(session, label)
        let k = planned?.afterTrack ?? 0
        await session.songStarted(index: k + 1, remaining: .seconds(1))
        return k
    }

    /// Hands the opener out as if its audio were ready, without waiting on a render.
    private func handOutOpener(_ session: DJBreakSession, _ label: String) async -> (Int, PreparedDJBreak)? {
        guard let planned = opener(session, label) else { return nil }
        let k = planned.afterTrack
        await session.songStarted(index: k, remaining: .seconds(6))
        var ready = PreparedDJBreak(afterTrack: k, cues: planned.cues, clips: [], attributions: planned.attributions)
        ready.talkOverCueID = planned.talkOverCueID
        await session.testPreparer.testRecord(.ready(ready), afterTrack: k)
        guard let handed = await session.naturalBoundary(afterTrack: k) else {
            XCTFail("\(label): the opener was not handed out")
            return nil
        }
        return (k, handed)
    }

    func testAStationChangeReGreetsAndNamesTheNewStation() async {
        let (session, station, memory) = await rig()
        await session.queueStarted(djTracks(30), stationName: "Kitchen Radio")
        guard let (k, handed) = await handOutOpener(session, "first station") else { return }
        let first = handed.cues[0].text
        XCTAssertTrue(first.contains("Kitchen Radio"), first)
        XCTAssertNotNil(session.testPlannedBreaks[k]?.timeCheck, "the first opener gives the time")
        session.playbackFinished(afterTrack: k)
        let remembered = memory.load().recent
        XCTAssertFalse(remembered.isEmpty, "the aired opener is in the line memory")

        await save(session, station) { await station.setSeeds(seeds("second")) }
        await session.queueStarted(djTracks(30), stationName: "Porch Radio")
        guard let again = opener(session, "new station") else { return }
        let welcome = again.cues[0].text
        XCTAssertTrue(welcome.contains("Porch Radio"), welcome)
        XCTAssertFalse(welcome.contains("Kitchen Radio"), welcome)
        XCTAssertNotEqual(first.replacingOccurrences(of: "Kitchen Radio", with: "Porch Radio"), welcome,
                          "anti-repeat keeps the aired opener out of the new one")
        XCTAssertNil(again.timeCheck, "within 30 minutes the new opener leaves the time out")
        XCTAssertEqual(session.testOpenerTimeOmissions[again.afterTrack], .spacing)
        XCTAssertEqual(memory.load().recent, remembered, "the re-greet does not wipe aired line memory")
        XCTAssertEqual(again.attributions[again.cues[0].id], .stationName)
        await session.stop()
    }

    func testTheSameStationRequeuedDoesNotReGreet() async {
        let (session, _, _) = await rig()
        await session.queueStarted(djTracks(30), stationName: "Kitchen Radio")
        _ = await passTheOpener(session, "first queue")
        await session.queueStarted(djTracks(30), stationName: "Kitchen Radio Late")
        XCTAssertEqual(openers(session), [], "same seeds: a new name is not a new station")
        await session.stop()
    }

    func testARapidDoubleSwitchGreetsOnlyTheFinalStation() async {
        let (session, station, _) = await rig()
        await session.queueStarted(djTracks(30), stationName: "Kitchen Radio")
        _ = await passTheOpener(session, "first station")

        await save(session, station) { await station.setSeeds(seeds("second")) }
        await session.queueStarted(djTracks(30), stationName: "Harbor FM")
        await save(session, station) { await station.setSeeds(seeds("third")) }
        await session.queueStarted(djTracks(30), stationName: "Porch Radio")

        guard let again = opener(session, "final station") else { return }
        let spoken = again.cues.map(\.text).joined(separator: " ")
        XCTAssertTrue(spoken.contains("Porch Radio"), spoken)
        XCTAssertFalse(spoken.contains("Harbor FM"), "the station we passed through is not greeted")
        XCTAssertEqual(again.talkOverCueID, again.cues.last?.id, "the greeting is not the talk-over line")
        XCTAssertNotEqual(again.cues.first?.id, again.talkOverCueID)
        await session.stop()
    }

    /// No owner (`StationQueueOwner.tag` is nil): the UI says "OnAirly", and so does the opener.
    func testAStationChangeWithNoNameUsesTheOnAirlyFallback() async {
        let (session, station, _) = await rig()
        await session.queueStarted(djTracks(30), stationName: "Kitchen Radio")
        _ = await passTheOpener(session, "named station")

        await save(session, station) { await station.setSeeds(seeds("second")) }
        await session.queueStarted(djTracks(30), stationName: nil)
        guard let again = opener(session, "unnamed station") else { return }
        let spoken = again.cues.map(\.text).joined(separator: " ")
        XCTAssertFalse(spoken.contains("Kitchen Radio"), spoken)
        XCTAssertTrue(spoken.contains(DJScriptWriter.builtInStationName), spoken)
        XCTAssertEqual(again.attributions[again.cues[0].id], .presenter, "the brand is not a typed station name")
        await session.stop()
    }

    /// A name the opener must not speak (braces) is the same as no name: the fallback, not the last station.
    func testAStationChangeWithAnUnusableNameUsesTheOnAirlyFallback() async {
        let (session, station, _) = await rig()
        await session.queueStarted(djTracks(30), stationName: "Kitchen Radio")
        _ = await passTheOpener(session, "named station")

        await save(session, station) { await station.setSeeds(seeds("second")) }
        await session.queueStarted(djTracks(30), stationName: "{not a name}")
        guard let again = opener(session, "unusable name") else { return }
        let spoken = again.cues.map(\.text).joined(separator: " ")
        XCTAssertFalse(spoken.contains("Kitchen Radio"), spoken)
        XCTAssertFalse(spoken.contains("{not a name}"), spoken)
        XCTAssertTrue(spoken.contains(DJScriptWriter.builtInStationName), spoken)
        XCTAssertEqual(again.attributions[again.cues[0].id], .presenter)
        await session.stop()
    }

    func testAStationChangeMidBreakStopsTheTalkOverAndGreetsOnce() async {
        let (session, station, _) = await rig()
        await session.queueStarted(djTracks(30), stationName: "Kitchen Radio")
        guard let (_, handed) = await handOutOpener(session, "on air") else { return }
        XCTAssertEqual(handed.talkOverCueID, handed.cues.last?.id, "the line on air is the closing talk-over")
        XCTAssertNotEqual(handed.cues.first?.id, handed.talkOverCueID, "the greeting is not over that talk-over")

        var stops: [InterludeStopReason] = []
        session.onBreakMustStop = { reason, _ in stops.append(reason) }
        await save(session, station) { await station.setSeeds(seeds("second")) }
        await session.queueStarted(djTracks(30), stationName: "Porch Radio")

        XCTAssertEqual(stops, [.interruption], "the talk-over stops before the new station is planned")
        guard let again = opener(session, "after the switch") else { return }
        XCTAssertTrue(again.cues[0].text.contains("Porch Radio"), again.cues[0].text)
        XCTAssertFalse(again.cues[0].text.isEmpty)
        XCTAssertNotEqual(again.cues.first?.id, again.talkOverCueID, "the new greeting is not a talk-over")
        XCTAssertEqual(again.talkOverCueID, again.cues.last?.id)
        await session.stop()
    }

    func testRevokedConsentKeepsPersonalContentOutOfTheReGreet() async {
        let (session, station, _) = await rig()
        await session.queueStarted(djTracks(30), stationName: "Kitchen Radio")
        _ = await passTheOpener(session, "first station")

        let revokedID = UUID()
        let revoked = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note,
                                   text: "From your notes. Revoked dentist note.",
                                   estimatedSeconds: 4, maxSeconds: 12, sourceItemID: revokedID,
                                   source: .obsidian, provenance: "note:revoked")
        let revokedItem = ConnectionItem(id: revokedID, integration: .obsidian, title: "Revoked dentist note",
                                         state: .revoked, sensitivity: .low)
        await save(session, station) { await station.setSeeds(seeds("second")) }
        await session.queueStarted(djTracks(30),
                                  briefing: NarrationHandoff(cues: [revoked], maxSpokenSeconds: 60, experienceSeconds: 300),
                                  sources: [revokedItem], stationName: "Porch Radio")
        let revokedPlan = session.testPlannedBreaks.values.flatMap(\.cues).map(\.text).joined(separator: " ")
        XCTAssertFalse(revokedPlan.contains("Revoked dentist"), revokedPlan)
        XCTAssertFalse(session.testPlannedBreaks.values.contains { $0.cues.contains { $0.sourceItemID == revokedID } })
        guard let again = opener(session, "revoked briefing is not a greeting") else { return }
        XCTAssertTrue(again.cues[0].text.contains("Porch Radio"), again.cues[0].text)

        let approvedID = UUID()
        let approved = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note,
                                    text: "From your notes. Grocery list has milk.",
                                    estimatedSeconds: 4, maxSeconds: 12, sourceItemID: approvedID,
                                    source: .obsidian, provenance: "note:grocery")
        let approvedItem = ConnectionItem(id: approvedID, integration: .obsidian, title: "Grocery list",
                                          state: .approved, sensitivity: .low)
        let stillRevoked = NarrationCue(id: UUID(), order: 2, group: 1, kind: .note,
                                        text: "From your notes. Revoked dentist note.",
                                        estimatedSeconds: 4, maxSeconds: 12, sourceItemID: revokedID,
                                        source: .obsidian, provenance: "note:revoked-2")
        await save(session, station) { await station.setSeeds(seeds("third")) }
        await session.queueStarted(djTracks(30),
                                  briefing: NarrationHandoff(cues: [approved, stillRevoked], maxSpokenSeconds: 60,
                                                             experienceSeconds: 300),
                                  sources: [approvedItem, revokedItem], stationName: "Harbor FM")
        let texts = session.testPlannedBreaks.values.flatMap(\.cues).map(\.text).joined(separator: " ")
        XCTAssertTrue(texts.contains("Grocery list has milk"), "an approved line still needs its consent, and keeps it")
        XCTAssertFalse(texts.contains("Revoked dentist"), texts)
        XCTAssertFalse(session.testPlannedBreaks.values.contains { $0.cues.contains { $0.sourceItemID == revokedID } })
        await session.stop()
    }
}

private struct RegreetVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}
