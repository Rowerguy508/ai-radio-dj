import XCTest
@testable import AeroDJCore

/// Sentinel's B1 on #603 (-Echo): the session's per-break outcomes for the cap report keep only
/// the dropped time check, the trimmed count and the over-budget flag. A taken break's personal
/// cue text and clip audio are never reachable through them, before or after
/// `purge(sourceItemIDs:)` / `purgeAllPersonal()`, and `ordinaryCapReport` is unchanged by
/// the purges. Fixture titles only.
@MainActor
final class BreakOutcomePurgeTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func session(itemID: UUID, title: String) async -> (DJBreakSession, DJPresentationStore, PurgeStudio) {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: TextEchoVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 10))!
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 10 },
                                     now: { now }, calendar: calendar)
        await session.start()
        let studio = PurgeStudio(
            items: [ConnectionItem(id: itemID, integration: .calendar, title: title, state: .approved, sensitivity: .low)],
            sensitivity: [itemID: .low])
        return (session, dj, studio)
    }

    /// Every stored value reachable from `value`, depth first.
    private func reachable(_ value: Any) -> [Any] {
        var out: [Any] = [value]
        for child in Mirror(reflecting: value).children { out += reachable(child.value) }
        return out
    }

    private func assertNoPersonalContent(_ session: DJBreakSession, text: String, audio: [Data],
                                         _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let outcomes: [Int: DJBreakCapOutcome] = session.testBreakOutcomes
        for value in reachable(outcomes) {
            XCTAssertFalse(value is String, "\(step): a string is stored", file: file, line: line)
            XCTAssertFalse(value is Data, "\(step): audio bytes are stored", file: file, line: line)
            XCTAssertFalse(value is NarrationCue, "\(step): a cue is stored", file: file, line: line)
            XCTAssertFalse(value is RenderedClip, "\(step): a clip is stored", file: file, line: line)
            XCTAssertFalse(value is PreparedDJBreak, "\(step): a prepared break is stored", file: file, line: line)
            XCTAssertFalse(value is DJBreakOutcome, "\(step): a full outcome is stored", file: file, line: line)
        }
        let dump = String(reflecting: outcomes)
        XCTAssertFalse(dump.contains(text), "\(step): the personal line is reachable", file: file, line: line)
        for bytes in audio where !bytes.isEmpty {
            XCTAssertFalse(dump.contains(String(decoding: bytes, as: UTF8.self)), "\(step): clip audio is reachable",
                           file: file, line: line)
        }
    }

    /// Hands out a break that speaks about one personal item, runs `purge`, and checks that no
    /// cue text or clip audio is reachable through `breakOutcomes` before or after, and that the
    /// cap report is unchanged.
    private func assertPurgeLeavesNothingPersonal(_ name: String, _ purge: (DJBreakSession, UUID) -> Void,
                                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let itemID = UUID()
        let title = "Fixture dentist reminder 4417"
        let (session, dj, studio) = await session(itemID: itemID, title: title)
        let offer = StationStartBriefing.offer(
            for: .idlePlayStart,
            briefing: session.briefingProvider(studio: studio, now: { Date() }, calendar: calendar))
        await session.queueStarted(djTracks(8), briefing: offer.briefing, sources: offer.sources)
        await session.songStarted(index: 0, remaining: .seconds(180))
        for _ in 0..<500 { if case .ready = dj.studioState { break }; try? await Task.sleep(for: .milliseconds(10)) }
        let handed = await session.naturalBoundary(afterTrack: 0)
        let aired = try XCTUnwrap(handed, "\(name): the personal break is handed out", file: file, line: line)

        let personal = aired.cues.filter { $0.isContent && $0.sourceItemID == itemID }
        XCTAssertFalse(personal.isEmpty, "\(name): fixture break speaks about the item", file: file, line: line)
        let personalText = try XCTUnwrap(personal.first?.text, file: file, line: line)
        let audio = aired.clips.map(\.audio.data)
        XCTAssertFalse(audio.isEmpty, "\(name): fixture break has rendered clips", file: file, line: line)
        XCTAssertNotNil(session.testBreakOutcomes[0], "\(name): the taken break is recorded for the cap report",
                        file: file, line: line)
        XCTAssertFalse(session.testHandedOutPersonalCueIDs.isEmpty, "\(name): fixture ledger holds the personal line",
                       file: file, line: line)
        let reportBefore = session.ordinaryCapReport
        assertNoPersonalContent(session, text: personalText, audio: audio, "\(name): after the take", file: file, line: line)

        purge(session, itemID)
        assertNoPersonalContent(session, text: personalText, audio: audio, "\(name): after the purge", file: file, line: line)
        XCTAssertEqual(session.testHandedOutPersonalCueIDs, [], "\(name): the purged line is not kept for the ledger",
                       file: file, line: line)
        XCTAssertEqual(session.ordinaryCapReport, reportBefore, "\(name): the purge does not change the cap report",
                       file: file, line: line)
    }

    func testPurgeSourceItemIDsLeavesNoCueTextOrAudioInBreakOutcomes() async throws {
        try await assertPurgeLeavesNothingPersonal("purge(sourceItemIDs:)") { session, id in
            session.purge(sourceItemIDs: [id])
        }
    }

    func testPurgeAllPersonalLeavesNoCueTextOrAudioInBreakOutcomes() async throws {
        try await assertPurgeLeavesNothingPersonal("purgeAllPersonal()") { session, id in
            XCTAssertTrue(session.purgeAllPersonal().contains(id), "purgeAllPersonal knew the item")
        }
    }

    /// The slim value carries exactly what the report read from the full outcome.
    func testCapOutcomeKeepsOnlyWhatTheReportReads() {
        let drop = DJTimeCheckDrop(cueID: UUID(), reason: .stale)
        var prepared = PreparedDJBreak(afterTrack: 3, cues: [], clips: [], attributions: [:], trimmedCueIDs: [UUID(), UUID()])
        prepared.droppedTimeCheck = drop
        XCTAssertEqual(DJBreakCapOutcome(.ready(prepared)),
                       DJBreakCapOutcome(droppedTimeCheck: drop, trimmedCount: 2, overBreakBudget: false))
        XCTAssertEqual(DJBreakCapOutcome(.skipped(.overBreakBudget)), DJBreakCapOutcome(overBreakBudget: true))
        XCTAssertEqual(DJBreakCapOutcome(.skipped(.timedOut)), DJBreakCapOutcome())
    }
}

@MainActor
private final class PurgeStudio: LiveQueueStudio {
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

/// Audio bytes are the spoken text, so a leak of either shows up in the stored values.
private struct TextEchoVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}
