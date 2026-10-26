import XCTest
@testable import AeroDJCore

/// The construction seam `PlayerView` passes to `MusicSearch.live(briefing:)`.
/// `PlayerView` itself is SwiftUI and MusicKit in the app target, which has no
/// unit-test target and is not part of AeroDJCore, so it is not executed here.
private final class ItemBox: @unchecked Sendable {
    var items: [ConnectionItem]
    init(_ items: [ConnectionItem]) { self.items = items }
}

@MainActor
final class LiveQueueBriefingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 08:00 UTC, inside the default 07:00–09:00 window.
    private var morning: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8))!
    }

    private var afternoon: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15))!
    }

    private func preferences(enabled: Bool = true, sections: Set<BriefingSection> = Set(BriefingSection.allCases)) -> BriefingPreferences {
        BriefingPreferences(enabled: enabled, window: BriefingWindow(startMinute: 7 * 60, durationMinutes: 120), sections: sections)
    }

    func testPlayerViewProviderPassesOnlyTheApprovedMorningHandoff() async throws {
        let approvedID = UUID()
        let pendingID = UUID()
        let box = ItemBox([
            ConnectionItem(id: pendingID, integration: .calendar, title: "Pending sync", state: .pendingApproval),
        ])
        let prefs = preferences()
        let provider = LiveQueueBriefing.provider(
            items: { box.items },
            preferences: { prefs },
            now: { self.morning },
            calendar: calendar)
        XCTAssertNil(provider().forQueue(), "read at play time: nothing approved yet")

        box.items += [
            ConnectionItem(id: approvedID, integration: .calendar, title: "Design review", state: .approved),
            ConnectionItem(id: UUID(), integration: .obsidian, title: "Flagged memo", state: .flaggedForReview),
            ConnectionItem(id: UUID(), integration: .shareInbox, title: "Expired reminder", state: .expired),
            ConnectionItem(id: UUID(), integration: .obsidian, title: "Revoked note", state: .revoked),
            ConnectionItem(id: UUID(), integration: .calendar, title: "Unavailable calendar",
                           state: .unavailable(.calendarAccess(.denied))),
        ]
        let queued = provider().forQueue()
        let cues = queued?.cues ?? []
        XCTAssertEqual(cues.compactMap(\.sourceItemID), [approvedID])
        XCTAssertEqual(cues.map(\.text), ["You've got Design review."])
        XCTAssertEqual(cues.map(\.source), [.calendar])
        XCTAssertEqual(cues.map(\.provenance), ["connection:\(approvedID.uuidString)"])
        let spoken = cues.map(\.text).joined(separator: " ")
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("from your"), spoken)
        for hidden in ["Pending sync", "Flagged memo", "Expired reminder", "Revoked note", "Unavailable calendar"] {
            XCTAssertFalse(spoken.contains(hidden), spoken)
        }
    }

    func testLaterShowAndDisabledBriefingStayQuiet() async throws {
        let items = [ConnectionItem(id: UUID(), integration: .calendar, title: "Design review", state: .approved)]
        let on = preferences()
        XCTAssertNil(LiveQueueBriefing.handoff(items: items, preferences: on, now: afternoon, calendar: calendar).forQueue())
        let off = preferences(enabled: false)
        XCTAssertNil(LiveQueueBriefing.handoff(items: items, preferences: off, now: morning, calendar: calendar).forQueue())
        XCTAssertTrue(LiveQueueBriefing.handoff(items: items, preferences: off, now: morning, calendar: calendar).revokedOrUnapproved)
    }

    func testTurnedOffSectionAndPreparedHandoff() async throws {
        let calendarID = UUID()
        let noteID = UUID()
        let items = [
            ConnectionItem(id: calendarID, integration: .calendar, title: "Design review", state: .approved),
            ConnectionItem(id: noteID, integration: .obsidian, title: "Grocery list", state: .approved),
        ]
        let notesOnly = preferences(sections: [.notes])
        let queued = LiveQueueBriefing.handoff(items: items, preferences: notesOnly, now: morning, calendar: calendar).forQueue()
        XCTAssertEqual(queued?.cues.compactMap(\.sourceItemID), [noteID])
        XCTAssertEqual(queued?.cues.map(\.text), ["You've got Grocery list."])
        XCTAssertEqual(queued?.cues.map(\.source), [.obsidian])

        let preparedCue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note,
                                       text: "Item Pending sync stays in the script.",
                                       estimatedSeconds: 4, maxSeconds: 16, sourceItemID: UUID(),
                                       source: .userShared, provenance: "prepared:pending")
        let approvedCue = NarrationCue(id: UUID(), order: 2, group: 1, kind: .upcomingEvent,
                                       text: "You've got Design review.",
                                       estimatedSeconds: 3, maxSeconds: 16, sourceItemID: calendarID,
                                       source: .calendar, provenance: "prepared:design")
        let prepared = NarrationHandoff(cues: [preparedCue, approvedCue], maxSpokenSeconds: 60, experienceSeconds: 300)
        let passed = LiveQueueBriefing.handoff(items: items, preferences: preferences(), now: morning,
                                               calendar: calendar, prepared: prepared).forQueue()
        XCTAssertEqual(passed?.cues.map(\.id), [approvedCue.id])
    }
}
