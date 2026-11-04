import XCTest
@testable import AeroDJCore

// #332 (-Nova): what counts as "aired" for the repeat limit, and the minimum gap.
//
// The P1 left open after #338: `playbackStarted` recorded every personal cue of a break when the
// FIRST clip began, so a call, skip or failure during the intro or lead silenced an update for
// the rest of the day although it was never heard. Now a personal update counts only when its
// own line played to its end (`lineFinished`), or the whole break finished on a player that
// reports no per-line events (the talk-over). Fixture titles only; messages print ids/counts.
@MainActor
final class PersonalUpdateAiredAccountingTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(day: Int = 26, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private struct Rig {
        let session: DJBreakSession
        let dj: DJPresentationStore
        let studio: AccountingStudio
        let clock: Clock
        let ids: [UUID]
        @MainActor var ledger: PersonalUpdateLedger { session.personalUpdates }
    }

    private func rig(items count: Int = 1, hour: Int = 10, store: any PersonalUpdatePlayStore = InMemoryPersonalUpdatePlayStore(),
                     minimumGap: TimeInterval = DJCadence.defaultMinimumGapBetweenPersonalBriefings) async -> Rig {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: AccountingVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let clock = Clock(at(hour))
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 10 },
                                     now: { clock.now },
                                     personalUpdates: PersonalUpdateLedger(store: store, calendar: calendar,
                                                                           minimumGap: minimumGap),
                                     calendar: calendar)
        await session.start()
        let ids = (0..<count).map { _ in UUID() }
        let studio = AccountingStudio(
            items: ids.enumerated().map { i, id in
                ConnectionItem(id: id, integration: .calendar, title: "Fixture review \(i + 1)", state: .approved, sensitivity: .low)
            },
            sensitivity: Dictionary(uniqueKeysWithValues: ids.map { ($0, Sensitivity.low) }))
        return Rig(session: session, dj: dj, studio: studio, clock: clock, ids: ids)
    }

    private func provider(_ r: Rig) -> @MainActor () -> ApprovedShowHandoff {
        r.session.briefingProvider(studio: r.studio, now: { r.clock.now }, calendar: calendar)
    }

    private func tapIDs(_ r: Rig) -> [UUID?] {
        provider(r)().forQueue()?.cues.filter(\.isContent).map(\.sourceItemID) ?? []
    }

    private func startIDs(_ r: Rig, _ kind: StationHandOffKind = .createdStationStart) -> [UUID?] {
        StationStartBriefing.offer(for: kind, briefing: provider(r)).briefing?.cues.filter(\.isContent).map(\.sourceItemID) ?? []
    }

    /// A queue start (station start or song tap), then its first break is handed to the player.
    private func handOut(_ r: Rig, stationStart: Bool = true) async throws -> PreparedDJBreak {
        let briefing: NarrationHandoff?
        let sources: [ConnectionItem]
        if stationStart {
            let offer = StationStartBriefing.offer(for: .idlePlayStart, briefing: provider(r))
            (briefing, sources) = (offer.briefing, offer.sources)
        } else {
            let handoff = provider(r)()
            (briefing, sources) = (handoff.forQueue(), handoff.connectionItems)
        }
        await r.session.queueStarted(djTracks(8), briefing: briefing, sources: sources)
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        for _ in 0..<500 { if case .ready = r.dj.studioState { break }; try? await Task.sleep(for: .milliseconds(10)) }
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        return try XCTUnwrap(handed, "the briefing break is handed out")
    }

    /// The lines in play order (the clips the app passes to the player), split at the update.
    private func lines(_ b: PreparedDJBreak) throws -> (before: [UUID], update: UUID, after: [UUID]) {
        let order = b.clips.map(\.cueID)
        let content = Set(b.cues.filter(\.isContent).map(\.id))
        let i = try XCTUnwrap(order.firstIndex { content.contains($0) }, "one personal line")
        XCTAssertGreaterThan(i, 0, "fixture: a lead plays before the update")
        return (Array(order[..<i]), order[i], Array(order[(i + 1)...]))
    }

    // MARK: P1: interruption before / during the update's own line

    func testAnInterruptionBeforeTheUpdateLineDoesNotCountIt() async throws {
        let r = await rig()
        let b = try await handOut(r)
        let l = try lines(b)
        r.session.playbackStarted(afterTrack: 0)
        XCTAssertFalse(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now), "audio starting counts nothing")
        for id in l.before { r.session.lineFinished(afterTrack: 0, cueID: id) }
        r.session.playbackFailed(afterTrack: 0)   // a call / skip before the update's line
        XCTAssertFalse(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now))
        XCTAssertFalse(r.ledger.isWithinMinimumGap(at: r.clock.now), "nothing aired: no gap either")
        XCTAssertEqual(tapIDs(r), [r.ids[0]], "it keeps its chance later that day")
    }

    func testAnInterruptionDuringTheUpdateLineDoesNotCountIt() async throws {
        for end in ["failed", "revoked"] {
            let r = await rig()
            let b = try await handOut(r)
            let l = try lines(b)
            r.session.playbackStarted(afterTrack: 0)
            for id in l.before { r.session.lineFinished(afterTrack: 0, cueID: id) }
            // The update's line started but never finished.
            if end == "failed" { r.session.playbackFailed(afterTrack: 0) } else { r.session.playbackRevoked(afterTrack: 0) }
            XCTAssertFalse(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now), end)
            XCTAssertEqual(tapIDs(r), [r.ids[0]], end)
        }
    }

    func testTheUpdateCountsOnceItsLineFinishedEvenIfTheBreakIsCutAfter() async throws {
        let r = await rig()
        let b = try await handOut(r)
        let l = try lines(b)
        r.session.playbackStarted(afterTrack: 0)
        for id in l.before + [l.update] { r.session.lineFinished(afterTrack: 0, cueID: id) }
        XCTAssertTrue(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now), "heard in full")
        r.session.playbackFailed(afterTrack: 0)   // the outro / closing was cut
        XCTAssertTrue(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now))
        r.clock.now = at(15)
        XCTAssertEqual(tapIDs(r), [], "not repeated later that day")
    }

    func testABreakThatFinishedOnALineReportingPlayerCountsOnlyReportedLines() async throws {
        let r = await rig()
        let b = try await handOut(r)
        let l = try lines(b)
        r.session.playbackStarted(afterTrack: 0)
        for id in l.before + l.after { r.session.lineFinished(afterTrack: 0, cueID: id) }   // the update line skipped
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertFalse(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now))
    }

    /// The talk-over reports no per-line events: a natural finish means every line was heard.
    func testABreakFinishedWithoutLineReportsCountsItsUpdate() async throws {
        let r = await rig()
        _ = try await handOut(r)
        r.session.playbackStarted(afterTrack: 0)
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertTrue(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now))
    }

    // MARK: B1: a line-reporting break that ends `.finished` before any line finished

    /// Echo's B1: a call lands during line 0, and the resume then ends the break through
    /// `endStaleBreak` (every line left past its window) or `endWithdrawnBreak` (a rating dropped
    /// it). Both report `.finished` with no `lineFinished` before it. The adapter said at `play`
    /// that this break reports lines (`breakReportsLines`), so nothing is counted as aired.
    func testALineReportingBreakEndedStaleOrWithdrawnBeforeAnyLineCountsNothing() async throws {
        for end in ["stale", "withdrawn"] {
            let r = await rig()
            _ = try await handOut(r)
            r.session.breakReportsLines(afterTrack: 0)   // at `play`, before audio
            r.session.playbackStarted(afterTrack: 0)
            // Interrupted during line 0; no line finished. Both resume endings send `.finished`.
            r.session.playbackFinished(afterTrack: 0)
            XCTAssertFalse(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now), end)
            XCTAssertFalse(r.ledger.isWithinMinimumGap(at: r.clock.now), "\(end): nothing aired, no gap")
            XCTAssertEqual(tapIDs(r), [r.ids[0]], "\(end): it keeps its chance later that day")
        }
    }

    func testALineReportingBreakThatPlaysThroughStillCountsItsUpdate() async throws {
        let r = await rig()
        let b = try await handOut(r)
        let l = try lines(b)
        r.session.breakReportsLines(afterTrack: 0)
        r.session.playbackStarted(afterTrack: 0)
        for id in l.before + [l.update] + l.after { r.session.lineFinished(afterTrack: 0, cueID: id) }
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertEqual(r.ledger.limitedItemIDs(at: r.clock.now), [r.ids[0]])
        XCTAssertTrue(r.ledger.isWithinMinimumGap(at: r.clock.now))
    }

    /// The talk-over never sends `breakReportsLines`; a flag for another break changes nothing.
    func testTalkoverCountingIsUnchangedByALineReportForAnotherBreak() async throws {
        let r = await rig()
        _ = try await handOut(r)
        r.session.breakReportsLines(afterTrack: 1)
        r.session.playbackStarted(afterTrack: 0)
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertTrue(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now), "a talk-over finish still counts")
    }

    func testALineEventForAnotherBreakOrAnUnknownCueCountsNothing() async throws {
        let r = await rig()
        let b = try await handOut(r)
        let l = try lines(b)
        r.session.lineFinished(afterTrack: 1, cueID: l.update)
        r.session.lineFinished(afterTrack: 0, cueID: UUID())
        XCTAssertFalse(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now))
        r.session.lineFinished(afterTrack: 0, cueID: l.update)
        r.session.lineFinished(afterTrack: 0, cueID: l.update)   // a duplicate report
        XCTAssertEqual(r.ledger.limitedItemIDs(at: r.clock.now), [r.ids[0]])
    }

    // MARK: All day, station starts, repeat limit, 45 s, consent

    /// Update 1 airs at an 8 AM station start; update 2 airs on a 3 PM song tap; neither repeats
    /// that day (a later tap or station start), and every briefing break stays within 45 s.
    func testUpdatesAirAtAStationStartAndLaterInTheDayWithinTheLimitAndTheCap() async throws {
        let r = await rig(items: 2, hour: 8)
        let first = try await handOut(r, stationStart: true)
        XCTAssertLessThanOrEqual(first.measuredSeconds, 45)
        let l1 = try lines(first)
        for id in l1.before + [l1.update] + l1.after { r.session.lineFinished(afterTrack: 0, cueID: id) }
        r.session.playbackFinished(afterTrack: 0)
        let aired1 = try XCTUnwrap(first.cues.first { $0.id == l1.update }?.sourceItemID)
        XCTAssertTrue(r.ledger.hasReachedLimit(aired1, at: r.clock.now))
        let other = try XCTUnwrap(r.ids.first { $0 != aired1 })

        r.clock.now = at(15)
        XCTAssertEqual(tapIDs(r), [other], "3 PM: only the update not yet aired")
        let later = try await handOut(r, stationStart: false)
        XCTAssertLessThanOrEqual(later.measuredSeconds, 45)
        let l2 = try lines(later)
        XCTAssertEqual(later.cues.first { $0.id == l2.update }?.sourceItemID, other)
        r.session.lineFinished(afterTrack: 0, cueID: l2.update)
        r.session.playbackFinished(afterTrack: 0)

        r.clock.now = at(21)
        XCTAssertEqual(tapIDs(r), [], "9 PM: both at their once-a-day limit")
        XCTAssertEqual(startIDs(r), [])
        r.clock.now = at(day: 27, 9)
        XCTAssertEqual(Set(tapIDs(r).compactMap { $0 }), Set(r.ids), "a new day: both eligible again")
    }

    func testNothingAirsOrCountsAfterConsentWithdrawal() async throws {
        let r = await rig()
        let handoff = provider(r)()
        await r.session.queueStarted(djTracks(8), briefing: handoff.forQueue(), sources: handoff.connectionItems)
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        for _ in 0..<500 { if case .ready = r.dj.studioState { break }; try? await Task.sleep(for: .milliseconds(10)) }
        _ = r.session.purgeAllPersonal()   // the purger's first step on a withdrawal
        r.studio.items = []
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertFalse((handed?.cues ?? []).contains { $0.sourceItemID != nil }, "nothing personal is handed out")
        XCTAssertEqual(tapIDs(r), [], "nor offered to a new queue")
        XCTAssertEqual(startIDs(r), [])
        XCTAssertTrue(r.ledger.limitedItemIDs(at: r.clock.now).isEmpty, "and nothing was counted as aired")
    }

    // MARK: Minimum gap

    func testNoNewQueueCarriesUpdatesWithinTheGapAfterOneAired() async throws {
        XCTAssertEqual(DJCadence.defaultMinimumGapBetweenPersonalBriefings, 30 * 60)
        let r = await rig(items: 2)
        let first = try await handOut(r)
        let l = try lines(first)
        r.session.lineFinished(afterTrack: 0, cueID: l.update)
        let aired = try XCTUnwrap(first.cues.first { $0.id == l.update }?.sourceItemID)
        let other = try XCTUnwrap(r.ids.first { $0 != aired })

        r.clock.now = at(10, 10)
        XCTAssertEqual(tapIDs(r), [], "10 min later: no personal updates in a new queue")
        XCTAssertEqual(startIDs(r), [], "nor at a station start")
        let report = provider(r)().omittedByLimit.entries
        XCTAssertEqual(Set(report.compactMap(\.cue.sourceItemID)), Set(r.ids), "held back and reported")
        // Echo's #403 N1: the aired one is at its daily limit; the other is held by the gap only.
        XCTAssertEqual(report.first { $0.cue.sourceItemID == aired }?.outcome, .dropped(.repeatLimit))
        XCTAssertEqual(report.first { $0.cue.sourceItemID == other }?.outcome, .dropped(.minimumGap))
        r.clock.now = at(10, 29)
        XCTAssertEqual(tapIDs(r), [])
        r.clock.now = at(10, 30)
        XCTAssertEqual(tapIDs(r), [other], "after 30 min: the other update, never the aired one")
    }

    func testTheGapSpansMidnightAndOldStoresDecode() async throws {
        let r = await rig(items: 1, hour: 23)
        r.clock.now = at(23, 50)
        r.ledger.recordAired([NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "", estimatedSeconds: 1,
                                           maxSeconds: 1, sourceItemID: UUID(), source: .obsidian, provenance: "fixture")],
                             at: r.clock.now)
        r.clock.now = at(day: 27, 0, 10)
        XCTAssertTrue(r.ledger.isWithinMinimumGap(at: r.clock.now), "a new day keeps the gap")
        XCTAssertEqual(tapIDs(r), [])
        r.clock.now = at(day: 27, 0, 20)
        XCTAssertEqual(tapIDs(r), [r.ids[0]])

        // A store written before `lastAiredAt` existed decodes with no gap.
        let legacy = Data(#"{"day":"2026-10-26","counts":[]}"#.utf8)
        let plays = try JSONDecoder().decode(PersonalUpdatePlays.self, from: legacy)
        XCTAssertNil(plays.lastAiredAt)
        XCTAssertEqual(plays.day, "2026-10-26")
    }

    func testAZeroGapLedgerHasNoGap() async throws {
        let r = await rig(items: 2, minimumGap: 0)
        let first = try await handOut(r)
        r.session.lineFinished(afterTrack: 0, cueID: try lines(first).update)
        XCTAssertFalse(r.ledger.isWithinMinimumGap(at: r.clock.now))
        XCTAssertEqual(tapIDs(r).count, 1, "the other update is offered at once")
    }
}

@MainActor
private final class AccountingStudio: LiveQueueStudio {
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

private struct AccountingVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

// MARK: Fry's #409 nits 1 and 2 (-Nova): talk-over per-line aired counting

/// The adapter's talk-over (`InterludePlaybackAdapter.playTalkover`, app-only) feeds the session
/// through `TalkoverLineReporting`: `.reportsLines` before audio when it says so, and one
/// `.lineFinished` per clip that played to its end with `finishedCueID(atClip:)`. These drive
/// the session exactly that way, with the cue ids `TalkoverCoordinator` hands over (one per clip).
extension PersonalUpdateAiredAccountingTests {
    private func playTalkover(_ r: Rig, reporting: TalkoverLineReporting, finishedClips: Range<Int>, cut: Bool) {
        if reporting.reportsLines { r.session.breakReportsLines(afterTrack: 0) }
        r.session.playbackStarted(afterTrack: 0)
        for i in finishedClips {
            if let id = reporting.finishedCueID(atClip: i) { r.session.lineFinished(afterTrack: 0, cueID: id) }
        }
        if cut { r.session.playbackFailed(afterTrack: 0) } else { r.session.playbackFinished(afterTrack: 0) }
    }

    func testATalkoverCutBeforeTheUpdateLineCountsNothingThoughItEndsFinished() async throws {
        let r = await rig()
        let b = try await handOut(r)
        let l = try lines(b)
        let reporting = TalkoverLineReporting(cueIDs: b.clips.map(\.cueID), clipCount: b.clips.count)
        XCTAssertEqual(reporting.cueIDs, b.clips.map(\.cueID))
        // A fade or a #388 drop: only the lead lines finished, then the talk-over ends `.finished`.
        playTalkover(r, reporting: reporting, finishedClips: 0..<l.before.count, cut: false)
        XCTAssertFalse(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now), "the update line never aired")
        XCTAssertFalse(r.ledger.isWithinMinimumGap(at: r.clock.now))
        XCTAssertEqual(tapIDs(r), [r.ids[0]])
    }

    func testATalkoverCountsTheUpdateOnceItsOwnLineFinishedEvenIfCutAfter() async throws {
        let r = await rig()
        let b = try await handOut(r)
        let l = try lines(b)
        let reporting = TalkoverLineReporting(cueIDs: b.clips.map(\.cueID), clipCount: b.clips.count)
        playTalkover(r, reporting: reporting, finishedClips: 0..<(l.before.count + 1), cut: true)
        XCTAssertEqual(r.ledger.limitedItemIDs(at: r.clock.now), [r.ids[0]])
    }

    func testATalkoverThatPlaysThroughCountsTheUpdate() async throws {
        let r = await rig()
        let b = try await handOut(r)
        let reporting = TalkoverLineReporting(cueIDs: b.clips.map(\.cueID), clipCount: b.clips.count)
        playTalkover(r, reporting: reporting, finishedClips: 0..<b.clips.count, cut: false)
        XCTAssertEqual(r.ledger.limitedItemIDs(at: r.clock.now), [r.ids[0]])
    }

    /// Nit 2: a cue id / clip count mismatch fails closed. Before, the talk-over sent no
    /// `.reportsLines` and the session's `.finished` fallback counted every line as aired.
    func testATalkoverCueIDMismatchCountsNoLineAsAired() async throws {
        for drop in [1, -1, Int.max] {   // one id short, one extra, none at all
            let r = await rig()
            let b = try await handOut(r)
            var ids = b.clips.map(\.cueID)
            if drop == 1 { ids.removeLast() } else if drop == -1 { ids.append(UUID()) } else { ids = [] }
            let reporting = TalkoverLineReporting(cueIDs: ids, clipCount: b.clips.count)
            XCTAssertTrue(reporting.reportsLines, "\(drop)")
            XCTAssertEqual(reporting.cueIDs, [], "\(drop)")
            playTalkover(r, reporting: reporting, finishedClips: 0..<b.clips.count, cut: false)
            XCTAssertFalse(r.ledger.hasReachedLimit(r.ids[0], at: r.clock.now), "\(drop): nothing counted")
            XCTAssertFalse(r.ledger.isWithinMinimumGap(at: r.clock.now), "\(drop)")
        }
    }

    func testTalkoverLineReportingMapsClipsToCueIDsInOrder() {
        let ids = [UUID(), UUID(), UUID()]
        let reporting = TalkoverLineReporting(cueIDs: ids, clipCount: 3)
        XCTAssertTrue(reporting.reportsLines)
        XCTAssertEqual((0..<3).map { reporting.finishedCueID(atClip: $0) }, ids)
        XCTAssertNil(reporting.finishedCueID(atClip: 3))
        XCTAssertNil(reporting.finishedCueID(atClip: -1))
        XCTAssertEqual(TalkoverLineReporting(cueIDs: [], clipCount: 0).cueIDs, [])
    }
}
