import XCTest
@testable import AeroDJCore

// #332 Core side (-Echo): personal updates all day, once per local day per item, at most one
// per break, and an expired time-sensitive update dropped and reported.

@MainActor
private final class AllDayStudio: LiveQueueStudio {
    var items: [ConnectionItem]
    var preferences: BriefingPreferences
    var sensitivity: [UUID: Sensitivity]
    var liveQueueBriefing: LiveQueueBriefingInput {
        LiveQueueBriefingInput(items: items, preferences: preferences, sensitivityByItemID: sensitivity)
    }
    init(items: [ConnectionItem], preferences: BriefingPreferences = .init(enabled: true),
         sensitivity: [UUID: Sensitivity]) {
        self.items = items
        self.preferences = preferences
        self.sensitivity = sensitivity
    }
}

/// Injectable clock the tests move forward.
private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class PersonalUpdatesAllDayTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func at(day: Int = 26, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func row(_ id: UUID, _ integration: StationIntegration = .calendar, _ title: String = "Design review",
                     expiresAt: Date? = nil) -> ConnectionItem {
        ConnectionItem(id: id, integration: integration, title: title, state: .approved, expiresAt: expiresAt)
    }

    private func contentIDs(_ handoff: ApprovedShowHandoff) -> [UUID?] {
        handoff.forQueue()?.cues.filter(\.isContent).map(\.sourceItemID) ?? []
    }

    // MARK: Time of day

    /// The 07:00–09:00 window no longer gates eligibility: 6 AM, 10 AM, 3 PM and 11 PM all air,
    /// with the stored default window (420, 120) left as it was.
    func testUpdatesAreEligibleAt6AM10AM3PMAnd11PM() throws {
        let id = UUID()
        let prefs = BriefingPreferences(enabled: true, window: BriefingWindow(startMinute: 7 * 60, durationMinutes: 120))
        XCTAssertEqual(prefs.window.startMinute, 420)
        XCTAssertEqual(prefs.window.durationMinutes, 120)
        for hour in [6, 10, 15, 23] {
            let now = at(hour)
            XCTAssertFalse(prefs.window.contains(now, calendar: calendar), "\(hour):00 is outside the old window")
            let studio = AllDayStudio(items: [row(id)], preferences: prefs, sensitivity: [id: .low])
            let handed = LiveQueueBriefing.provider(studio: studio, now: { now }, calendar: calendar)()
            XCTAssertTrue(handed.isMorningShow, "\(hour):00")
            XCTAssertFalse(handed.revokedOrUnapproved, "\(hour):00")
            XCTAssertEqual(contentIDs(handed), [id], "\(hour):00 is eligible")
            XCTAssertTrue(handed.omittedByLimit.entries.isEmpty, "\(hour):00")
        }
    }

    /// Consent is unchanged at any hour: only `.approved` rows with a known sensitivity air,
    /// and briefing off is still nil.
    func testConsentStillGatesEveryHour() {
        let approved = UUID(), pending = UUID(), blocked = UUID()
        let items = [row(approved), ConnectionItem(id: pending, integration: .calendar, title: "Pending", state: .pendingApproval),
                     row(blocked, .obsidian, "Private diary")]
        for hour in [6, 10, 15, 23] {
            let handed = LiveQueueBriefing.handoff(items: items, preferences: .init(enabled: true), now: at(hour),
                                                   calendar: calendar,
                                                   sensitivityByItemID: [approved: .low, pending: .low, blocked: .blocked])
            XCTAssertEqual(contentIDs(handed), [approved], "\(hour):00")
            let off = LiveQueueBriefing.handoff(items: items, preferences: .init(enabled: false), now: at(hour),
                                                calendar: calendar, sensitivityByItemID: [approved: .low])
            XCTAssertNil(off.forQueue(), "\(hour):00 briefing off")
            XCTAssertTrue(off.revokedOrUnapproved)
        }
    }

    // MARK: Repeat limit

    func testDefaultsAreOncePerDayAndOnePerBreak() {
        XCTAssertEqual(DJCadence.defaultPersonalUpdatePlaysPerDay, 1)
        XCTAssertEqual(DJCadence.defaultMaxPersonalUpdatesPerBreak, 1)
        XCTAssertEqual(DJCadence().maxPersonalUpdatesPerBreak, 1)
        XCTAssertEqual(PersonalUpdateLedger().playsPerDay, 1)
        XCTAssertEqual(StationConfiguration().cadence().maxPersonalUpdatesPerBreak, 1)
        XCTAssertEqual(StationConfiguration().cadence(base: DJCadence(maxPersonalUpdatesPerBreak: 3)).maxPersonalUpdatesPerBreak, 3)
        XCTAssertEqual(DJCadence(maxPersonalUpdatesPerBreak: 0).maxPersonalUpdatesPerBreak, 1, "never below 1")
    }

    /// Aired at 08:00: blocked at 15:00 and 23:59 the same local day, allowed again at 00:00 next day.
    func testSecondPlaySameDayIsBlockedAndNextDayIsAllowed() throws {
        let id = UUID(), other = UUID()
        let ledger = PersonalUpdateLedger(calendar: calendar)
        let studio = AllDayStudio(items: [row(id), row(other, .obsidian, "Grocery list")],
                                  sensitivity: [id: .low, other: .low])
        let clock = TestClock(at(8))
        let provider = LiveQueueBriefing.provider(studio: studio, now: { clock.now }, calendar: calendar, ledger: ledger)

        let first = provider()
        XCTAssertEqual(Set(contentIDs(first)), [id, other])
        let aired = try XCTUnwrap(first.forQueue()).cues.filter { $0.sourceItemID == id }
        ledger.recordAired(aired, at: clock.now)
        XCTAssertTrue(ledger.hasReachedLimit(id, at: clock.now))
        XCTAssertFalse(ledger.hasReachedLimit(other, at: clock.now), "offered but not aired keeps its chance")

        for (hour, minute) in [(15, 0), (23, 59)] {
            clock.now = at(hour, minute)
            let again = provider()
            XCTAssertEqual(contentIDs(again), [other], "\(hour):\(minute) same day: \(id) blocked")
            XCTAssertEqual(again.omittedByLimit.entries.map(\.cue.sourceItemID), [id])
            XCTAssertEqual(again.omittedByLimit.entries.map(\.outcome), [.dropped(.repeatLimit)])
            XCTAssertEqual(again.omittedByLimit.entries.map(\.cue.text), [""], "report-only, nothing to speak")
        }

        clock.now = at(day: 27, 0, 0)
        XCTAssertFalse(ledger.hasReachedLimit(id, at: clock.now))
        let nextDay = provider()
        XCTAssertEqual(Set(contentIDs(nextDay)), [id, other], "a new local day allows it again")
        XCTAssertTrue(nextDay.omittedByLimit.entries.isEmpty)
    }

    /// The day is the LOCAL calendar day: 23:30 and 00:30 New York are different days even though
    /// they are 1 hour apart (and the same UTC day).
    func testDayBoundaryIsTheLocalCalendarDay() {
        let id = UUID()
        let ledger = PersonalUpdateLedger(calendar: calendar)
        ledger.recordAired([cue(id)], at: at(23, 30))
        XCTAssertEqual(ledger.dayKey(for: at(23, 30)), "2026-10-26")
        XCTAssertEqual(ledger.dayKey(for: at(day: 27, 0, 30)), "2026-10-27")
        XCTAssertTrue(ledger.hasReachedLimit(id, at: at(23, 59)))
        XCTAssertFalse(ledger.hasReachedLimit(id, at: at(day: 27, 0, 30)))
    }

    /// Presenter and track lines never count; one break with the same item twice counts once.
    func testOnlyContentCuesCountAndEachItemOncePerRecord() {
        let id = UUID()
        let ledger = PersonalUpdateLedger(calendar: calendar, playsPerDay: 2)
        let presenter = NarrationCue(id: UUID(), order: 0, group: 0, kind: .transition, text: "Good morning.",
                                     estimatedSeconds: 1, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        ledger.recordAired([presenter], at: at(9))
        XCTAssertTrue(ledger.limitedItemIDs(at: at(9)).isEmpty)
        ledger.recordAired([cue(id), cue(id)], at: at(9))
        XCTAssertFalse(ledger.hasReachedLimit(id, at: at(9)), "1 of 2")
        ledger.recordAired([cue(id)], at: at(10))
        XCTAssertTrue(ledger.hasReachedLimit(id, at: at(10)), "2 of 2")
    }

    /// The UserDefaults store survives a new ledger (an app relaunch) and keeps only one day.
    func testUserDefaultsStoreSurvivesARelaunchAndKeepsOneDay() throws {
        let suite = "personal-updates-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), later = UUID()
        PersonalUpdateLedger(store: UserDefaultsPersonalUpdatePlayStore(defaults: defaults), calendar: calendar)
            .recordAired([cue(id)], at: at(8))
        let relaunched = PersonalUpdateLedger(store: UserDefaultsPersonalUpdatePlayStore(defaults: defaults), calendar: calendar)
        XCTAssertTrue(relaunched.hasReachedLimit(id, at: at(21)))
        relaunched.recordAired([cue(later)], at: at(day: 27, 7))
        let stored = try XCTUnwrap(UserDefaultsPersonalUpdatePlayStore(defaults: defaults).load())
        XCTAssertEqual(stored, PersonalUpdatePlays(day: "2026-10-27", counts: [later: 1]), "yesterday is not kept")
    }

    // MARK: Station start

    /// Fry's station start reads `LiveQueueBriefing.provider` (the song tap's). With the app's one
    /// ledger, an update aired at a station start counts toward the once-a-day limit, so a later
    /// queue (song tap or station start) the same day does not repeat it, and reports it.
    func testAnUpdatePlayedAtAStationStartCountsTowardTheDailyLimit() throws {
        let id = UUID()
        let ledger = PersonalUpdateLedger(calendar: calendar)
        let studio = AllDayStudio(items: [row(id)], sensitivity: [id: .low])
        let clock = TestClock(at(10))
        let stationStart = LiveQueueBriefing.provider(studio: studio, now: { clock.now }, calendar: calendar, ledger: ledger)
        let songTap = LiveQueueBriefing.provider(studio: studio, now: { clock.now }, calendar: calendar, ledger: ledger)

        let started = try XCTUnwrap(stationStart().forQueue())
        XCTAssertEqual(started.cues.filter(\.isContent).map(\.sourceItemID), [id])
        // The station start's first break airs (DJBreakSession hands it to the player).
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 3)
        let plan = writer.plan(tracks: tracks(4), briefing: started, hour: 10)
        let firstBreak = try XCTUnwrap(plan.breaks.first)
        XCTAssertEqual(firstBreak.cues.filter(\.isContent).map(\.sourceItemID), [id])
        ledger.recordAired(firstBreak.cues, at: clock.now)

        clock.now = at(14)
        for later in [songTap(), stationStart()] {
            XCTAssertNil(later.forQueue(), "same day: the station-start update is not repeated")
            XCTAssertEqual(later.omittedByLimit.entries.map(\.outcome), [.dropped(.repeatLimit)])
            XCTAssertEqual(later.omittedByLimit.entries.map(\.cue.sourceItemID), [id])
            let carry = EditorialCarryForward(report: later.omittedByLimit)
            XCTAssertTrue(carry.eligibleNextShow.isEmpty, "not carried into a later show")
        }
        var laterWriter = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 3)
        let laterPlan = laterWriter.plan(tracks: tracks(6), briefing: songTap().forQueue(), hour: 14)
        XCTAssertFalse(laterPlan.breaks.contains { $0.cues.contains { $0.sourceItemID == id } },
                       "no later break that day speaks it")
    }

    // MARK: One per break

    /// Three updates, default cadence: one per break, each exactly once, all within 45 s.
    func testAtMostOnePersonalUpdatePerBreak() {
        let ids = [UUID(), UUID(), UUID()]
        let handoff = NarrationHandoff(cues: ids.enumerated().map { i, id in cue(id, order: i + 1, kind: .note) },
                                       maxSpokenSeconds: 60, experienceSeconds: 600)
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 7)
        XCTAssertEqual(writer.cadence.maxPersonalUpdatesPerBreak, 1)
        let plan = writer.plan(tracks: tracks(10), briefing: handoff, hour: 15)
        let personal = plan.breaks.filter(\.hasBriefing)
        XCTAssertEqual(personal.count, 3)
        XCTAssertEqual(personal.map { $0.cues.filter(\.isContent).count }, [1, 1, 1])
        XCTAssertEqual(personal.map(\.afterTrack), [0, 2, 4], "the next spacing-allowed boundary each time")
        XCTAssertEqual(personal.flatMap { $0.cues.compactMap(\.sourceItemID) }, ids, "each once, in order")
        for b in personal { XCTAssertLessThanOrEqual(b.cues.reduce(0) { $0 + $1.plannedSeconds }, 45) }
        XCTAssertEqual(plan.briefingReport.entries.map(\.outcome),
                       [.scheduled(.afterTrack(0)), .scheduled(.afterTrack(2)), .scheduled(.afterTrack(4))])
    }

    /// Too few boundaries for one per break: the leftover is reported, never silently lost
    /// (a note is deferred; a calendar event is dropped, not carried forward).
    func testLeftoverUpdatesAreReported() {
        let event = UUID(), note = UUID(), extra = UUID()
        let handoff = NarrationHandoff(cues: [cue(event, order: 1, kind: .upcomingEvent), cue(note, order: 2, kind: .note),
                                              cue(extra, order: 3, kind: .upcomingEvent)],
                                       maxSpokenSeconds: 60, experienceSeconds: 600)
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 7)
        let plan = writer.plan(tracks: tracks(3), briefing: handoff, hour: 15)
        XCTAssertEqual(plan.briefingReport.entries.map(\.outcome),
                       [.scheduled(.afterTrack(0)), .deferred(.noTrackBoundary), .dropped(.notCarriedForward)])
        XCTAssertEqual(plan.carryForward.eligibleNextShow.map(\.sourceItemID), [note])
    }

    // MARK: Expired time-sensitive update

    /// A calendar row whose window passed is dropped and reported (`windowPassed`), never spoken
    /// and never carried forward. The still-valid row airs.
    func testExpiredTimeSensitiveUpdateIsDroppedAndReported() throws {
        let past = UUID(), current = UUID()
        let now = at(15)
        let items = [row(past, .calendar, "Standup", expiresAt: at(10)),
                     row(current, .calendar, "Design review", expiresAt: at(16))]
        let handed = LiveQueueBriefing.handoff(items: items, preferences: .init(enabled: true), now: now,
                                               calendar: calendar, sensitivityByItemID: [past: .low, current: .low])
        XCTAssertEqual(contentIDs(handed), [current])
        XCTAssertFalse(handed.forQueue()?.cues.map(\.text).joined().contains("Standup") ?? true)
        let entry = try XCTUnwrap(handed.omittedByLimit.entries.first)
        XCTAssertEqual(handed.omittedByLimit.entries.count, 1)
        XCTAssertEqual(entry.cue.sourceItemID, past)
        XCTAssertEqual(entry.outcome, .dropped(.windowPassed))
        XCTAssertEqual(entry.cue.kind, .upcomingEvent)
        XCTAssertEqual(entry.cue.text, "")
        XCTAssertEqual(entry.cue.provenance, "connection:\(past.uuidString)")
        let carry = EditorialCarryForward(report: handed.omittedByLimit)
        XCTAssertEqual(carry.omittedTimeSensitive.map(\.sourceItemID), [past])
        XCTAssertTrue(carry.eligibleNextShow.isEmpty)
        XCTAssertEqual(handed.omittedByLimit.unscheduledContent.count, 1)
    }

    /// Same for a prepared script: the cue is reported with its own text, not spoken.
    func testExpiredPreparedCueIsDroppedAndReported() throws {
        let past = UUID(), dup = UUID()
        let items = [row(past, .calendar, "Standup", expiresAt: at(10)), row(dup, .obsidian, "Grocery list")]
        let expired = cue(past, order: 1, kind: .upcomingEvent)
        let first = cue(dup, order: 2, kind: .note), second = cue(dup, order: 3, kind: .note)
        let prepared = NarrationHandoff(cues: [expired, first, second], maxSpokenSeconds: 60, experienceSeconds: 300)
        let handed = LiveQueueBriefing.handoff(items: items, preferences: .init(enabled: true), now: at(15),
                                               calendar: calendar, prepared: prepared)
        XCTAssertEqual(handed.forQueue()?.cues.map(\.id), [first.id])
        XCTAssertEqual(handed.omittedByLimit.entries.map(\.cue.id), [expired.id, second.id])
        XCTAssertEqual(handed.omittedByLimit.entries.map(\.outcome), [.dropped(.windowPassed), .dropped(.repeatLimit)])
    }

    // MARK: Helpers

    private func cue(_ id: UUID, order: Int = 1, kind: BriefingScriptSegment.Kind = .upcomingEvent) -> NarrationCue {
        NarrationCue(id: UUID(), order: order, group: order, kind: kind, text: "You've got item \(order). From your calendar.",
                     estimatedSeconds: 3, maxSeconds: 12, sourceItemID: id, source: .calendar,
                     provenance: "fixture:\(id.uuidString)")
    }

    private func tracks(_ n: Int) -> [DJTrack] {
        (0..<n).map { DJTrack(id: "t\($0)", title: "Song \($0)", artist: "Artist \($0)", origin: .catalog) }
    }
}
