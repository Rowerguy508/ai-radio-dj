import XCTest
@testable import AeroDJCore

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let newYork = calendar("America/New_York")
/// Monday 2026-10-26 07:00 in New York.
private let fixedNow = newYork.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 7))!

private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: 10, day: 26 + dayOffset, hour: hour, minute: minute))!
}

private func item(_ title: String, source: ContextSourceKind = .calendar, summary: String = "",
                  eventAt: Date? = nil, createdAt: Date = fixedNow.addingTimeInterval(-3600),
                  sensitivity: Sensitivity = .low, consent: ConsentState = .granted,
                  expiresAt: Date? = nil, provenance: String? = nil) -> ContextItem {
    ContextItem(source: source, createdAt: createdAt, eventAt: eventAt, title: title, summary: summary,
                sensitivity: sensitivity, consent: consent, expiresAt: expiresAt,
                provenance: provenance ?? "test:\(title)")
}

private func engine(_ config: MorningBriefingConfiguration = .init(), zone: Calendar = newYork) -> MorningBriefingEngine {
    MorningBriefingEngine(configuration: config, calendar: zone, now: { fixedNow })
}

private struct StubSource: ContextSource {
    let source: ContextSourceKind
    let result: Result<[ContextItem], Error>
    func fetchItems() async throws -> [ContextItem] { try result.get() }
}

private struct StubRewriter: BriefingRewriter {
    let transform: @Sendable (BriefingScriptSegment) throws -> String
    func rewrite(_ segment: BriefingScriptSegment, style: BriefingStyle) async throws -> String {
        try transform(segment)
    }
}

final class MorningBriefingEngineTests: XCTestCase {
    func testOrdersEventsThenDueTasksThenFollowUpsThenNotes() {
        let script = engine().script(from: [
            item("Garden ideas", source: .obsidian),
            item("Reply to Sam", source: .emailShared),
            item("Send invoice", source: .obsidian, eventAt: at(17)),
            item("Design review", eventAt: at(9, 30)),
            item("Standup", eventAt: at(8)),
        ])
        XCTAssertEqual(script.segments.map(\.kind),
                       [.opener, .upcomingEvent, .upcomingEvent, .dueTask, .followUp, .note, .closer])
        XCTAssertEqual(script.segments.compactMap(\.title),
                       ["Standup", "Design review", "Send invoice", "Reply to Sam", "Garden ideas"])
        XCTAssertEqual(script.segments[1].text, "Coming up at 8 AM: Standup. From your calendar.")
        XCTAssertEqual(script.segments[2].timePhrase, "at 9:30 AM")
        XCTAssertEqual(script.segments[3].text, "Due today: Send invoice. From your notes.")
        XCTAssertEqual(script.segments[4].text, "To follow up: Reply to Sam. From an email you shared.")
        XCTAssertEqual(script.segments.first?.text, "Good morning. Here's your briefing.")
    }

    func testTextUsesOnlyItemFields() {
        let script = engine().script(from: [
            item("Dentist", summary: "Bring  the\nform", eventAt: at(10, 15)),
            item("Taxes", source: .obsidian, eventAt: at(9, dayOffset: -3)),
        ])
        XCTAssertEqual(script.segments[1].text, "Coming up at 10:15 AM: Dentist. Bring the form. From your calendar.")
        XCTAssertEqual(script.segments[1].detail, "Bring the form")
        XCTAssertEqual(script.segments[2].text, "Overdue: Taxes. From your notes.")
    }

    func testUnapprovedExpiredAndBlockedItemsAreNeverVoiced() {
        let hidden = [
            item("Pending", consent: .notRequested), item("Denied", consent: .denied),
            item("Revoked", consent: .revoked), item("Blocked", sensitivity: .blocked),
            item("Expired", expiresAt: fixedNow),
        ]
        let script = engine().script(from: hidden)
        XCTAssertTrue(script.isEmpty)
        XCTAssertEqual(script.segments.map(\.kind), [.fallback])
        XCTAssertEqual(Set(script.excluded.values), [.notNarratable])
        XCTAssertEqual(script.excluded.count, hidden.count)
        for hiddenItem in hidden {
            XCTAssertFalse(script.segments.contains { $0.text.contains(hiddenItem.title) })
        }
    }

    func testPastFarAndAllDayEvents() {
        let past = item("Earlier", eventAt: at(6)), far = item("Next week", eventAt: at(9, dayOffset: 7))
        let allDay = item("Holiday", eventAt: at(0)), tomorrow = item("Flight", eventAt: at(5, 45, dayOffset: 1))
        let script = engine(.init(eventHorizon: 24 * 3600)).script(from: [past, far, allDay, tomorrow])
        XCTAssertEqual(script.excluded[past.id], .pastEvent)
        XCTAssertEqual(script.excluded[far.id], .outsideHorizon)
        XCTAssertEqual(script.segments.compactMap(\.timePhrase), ["today", "tomorrow at 5:45 AM"])
    }

    func testDuplicateProvenanceAndEmptyContentDropped() {
        let first = item("Standup", eventAt: at(8), provenance: "calendar:1")
        let copy = item("Standup copy", eventAt: at(8), provenance: "calendar:1")
        let blank = item("  ", source: .userShared, summary: "\n")
        let script = engine().script(from: [first, copy, blank])
        XCTAssertEqual(script.excluded, [copy.id: .duplicate, blank.id: .emptyContent])
        XCTAssertEqual(script.segments.compactMap(\.sourceItemID), [first.id])
    }

    func testSpokenBudgetAndSegmentCap() {
        let long = String(repeating: "word ", count: 24)
        let many = (0..<10).map { item("Task \($0)", source: .obsidian, summary: long,
                                       createdAt: fixedNow.addingTimeInterval(Double($0))) }
        let script = engine(.init(maxSpokenSeconds: 40)).script(from: many)
        XCTAssertLessThanOrEqual(script.estimatedSpokenSeconds, 40)
        XCTAssertEqual(script.segments.filter { $0.sourceItemID != nil }.count, 2)
        XCTAssertTrue(script.excluded.values.contains(.overBudget))
        XCTAssertEqual(script.segments.compactMap(\.title).first, "Task 0")

        let short = (0..<8).map { item("Note \($0)", source: .obsidian, createdAt: fixedNow.addingTimeInterval(Double($0))) }
        let capped = engine().script(from: short)
        XCTAssertEqual(capped.segments.filter { $0.sourceItemID != nil }.count, 6)
        XCTAssertEqual(capped.excluded.values.filter { $0 == .segmentCap }.count, 2)
    }

    func testProvenancePreservedPerSegmentAndInPlan() async throws {
        let items = [item("Standup", eventAt: at(8), provenance: "calendar:abc"),
                     item("Link", source: .userShared, provenance: "shared-inbox:xyz")]
        let script = engine().script(from: items)
        let itemSegments = script.segments.filter { $0.sourceItemID != nil }
        XCTAssertEqual(itemSegments.map(\.provenance), ["calendar:abc", "shared-inbox:xyz"])
        XCTAssertEqual(itemSegments.map(\.sourceItemID), items.map(\.id))
        XCTAssertNil(script.segments.first?.provenance)
        let plan = try await engine().plan(from: items, targetSpokenSeconds: 150)
        XCTAssertEqual(plan.segments.compactMap(\.sourceItemID), items.map(\.id))
        XCTAssertEqual(plan.estimatedTotalSpokenSeconds, script.estimatedSpokenSeconds)
    }

    func testDeterministicAndTimeZoneAware() {
        let items = [item("Call", eventAt: at(9, 30)), item("Idea", source: .obsidian)]
        XCTAssertEqual(engine().script(from: items), engine().script(from: items))
        let tokyo = engine(zone: calendar("Asia/Tokyo")).script(from: items)
        // 07:00 New York is 20:00 in Tokyo; 09:30 New York is 22:30 Tokyo.
        XCTAssertEqual(tokyo.segments.first?.text, "Good evening. Here's your briefing.")
        XCTAssertEqual(tokyo.segments[1].timePhrase, "at 10:30 PM")
    }

    func testOfflineSourcesDegradeGracefully() async {
        struct Offline: Error {}
        let sources: [any ContextSource] = [
            StubSource(source: .calendar, result: .failure(Offline())),
            StubSource(source: .obsidian, result: .success([item("Idea", source: .obsidian)])),
        ]
        let collected = await engine().collect(from: sources)
        XCTAssertEqual(collected.unavailable, [.calendar])
        let script = engine().script(from: collected.items, unavailableSources: collected.unavailable)
        XCTAssertTrue(script.segments[0].text.contains("couldn't be reached"))
        XCTAssertEqual(script.segments.compactMap(\.title), ["Idea"])

        let empty = engine().script(from: [], unavailableSources: [.calendar])
        XCTAssertEqual(empty.segments.map(\.text),
                       ["Good morning. Nothing needs your attention right now. Some sources couldn't be reached, so this may be incomplete. Enjoy the music."])
        XCTAssertEqual(empty.rundown.count, 2)
    }

    func testRundownInterleavesMusicAndFillsExperience() {
        let script = engine().script(from: [item("A", eventAt: at(8)), item("B", eventAt: at(9)), item("C", eventAt: at(10))])
        let shape = script.rundown.map { entry -> String in
            if case .music = entry { return "M" } else { return "S" }
        }
        XCTAssertEqual(shape, ["S", "S", "M", "S", "M", "S", "S"])
        let total = script.rundown.reduce(0) { sum, entry in
            switch entry { case .speech(_, let s), .music(_, let s): sum + s }
        }
        XCTAssertEqual(total, 300)
    }
}

final class BriefingRewriteGuardTests: XCTestCase {
    func testAcceptedRewriteKeepsProvenance() async {
        let script = engine().script(from: [item("Standup", eventAt: at(8), provenance: "calendar:1")])
        let rewriter = StubRewriter { "Easy does it. " + $0.text }
        let result = await BriefingRewriteGuard().restyle(script, with: rewriter)
        XCTAssertEqual(result.fallbacks, 0)
        XCTAssertEqual(result.script.segments[1].provenance, "calendar:1")
        XCTAssertTrue(result.script.segments[1].text.hasPrefix("Easy does it."))
    }

    func testRejectsInventedNumbersGrowthErrorsAndEmpty() async {
        let script = engine().script(from: [item("Standup", eventAt: at(8))])
        let cases: [StubRewriter] = [
            StubRewriter { $0.text + " Also lunch at 12." },
            StubRewriter { $0.text + String(repeating: " more", count: 40) },
            StubRewriter { _ in throw URLError(.notConnectedToInternet) },
            StubRewriter { _ in "   " },
        ]
        for rewriter in cases {
            let result = await BriefingRewriteGuard().restyle(script, with: rewriter)
            XCTAssertEqual(result.script, script)
            XCTAssertEqual(result.fallbacks, script.segments.count)
        }
    }
}
