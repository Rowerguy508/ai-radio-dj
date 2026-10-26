import XCTest
@testable import AeroDJCore

/// The construction seam `PlayerView` passes to `MusicSearch.live(briefing:)`.
/// `PlayerView` itself is SwiftUI and MusicKit in the app target, which has no
/// unit-test target and is not part of AeroDJCore, so it is not executed here.
/// `PlayerView` calls `LiveQueueBriefing.provider(studio:)`. This test calls that
/// same function. Returning `ApprovedShowHandoff.unapproved` from it fails here.
@MainActor
private final class FixtureStudio: LiveQueueStudio {
    var items: [ConnectionItem]
    var preferences: BriefingPreferences
    /// Source-item sensitivity keyed by row id. Missing ids are blocked.
    var sensitivityByItemID: [UUID: Sensitivity]
    var liveQueueBriefing: LiveQueueBriefingInput {
        LiveQueueBriefingInput(items: items, preferences: preferences, sensitivityByItemID: sensitivityByItemID)
    }
    init(items: [ConnectionItem], preferences: BriefingPreferences,
         sensitivityByItemID: [UUID: Sensitivity] = [:]) {
        self.items = items
        self.preferences = preferences
        self.sensitivityByItemID = sensitivityByItemID
    }
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

    /// The one builder, given the same title the adapter is allowed to pass.
    private func engineContent(id: UUID, title: String, source: ContextSourceKind) -> [NarrationCue] {
        let item = ContextItem(id: id, source: source, createdAt: morning, title: title, summary: "",
                               sensitivity: .low, consent: .granted, provenance: "connection:\(id.uuidString)")
        let now = morning
        let script = MorningBriefingEngine(
            configuration: MorningBriefingConfiguration(experienceSeconds: 300, maxSpokenSeconds: 150),
            calendar: calendar, now: { now }).script(from: [item])
        return script.handoff(maxSpokenSeconds: 150).cues.filter(\.isContent)
    }

    func testPlayerViewProviderPassesOnlyTheApprovedMorningHandoff() async throws {
        let approvedID = UUID()
        let pendingID = UUID()
        let studio = FixtureStudio(items: [
            ConnectionItem(id: pendingID, integration: .calendar, title: "Pending sync", state: .pendingApproval),
        ], preferences: preferences())
        let now = morning
        let provider = LiveQueueBriefing.provider(studio: studio, now: { now }, calendar: calendar)
        XCTAssertNil(provider().forQueue(), "read at play time: nothing approved yet")

        studio.items += [
            ConnectionItem(id: approvedID, integration: .calendar, title: "Design review", state: .approved),
            ConnectionItem(id: UUID(), integration: .obsidian, title: "Flagged memo", state: .flaggedForReview),
            ConnectionItem(id: UUID(), integration: .shareInbox, title: "Expired reminder", state: .expired),
            ConnectionItem(id: UUID(), integration: .obsidian, title: "Revoked note", state: .revoked),
            ConnectionItem(id: UUID(), integration: .calendar, title: "Unavailable calendar",
                           state: .unavailable(.calendarAccess(.denied))),
        ]
        studio.sensitivityByItemID[approvedID] = .low
        let handed = provider()
        XCTAssertNotEqual(handed, .unapproved)
        XCTAssertFalse(handed.revokedOrUnapproved)
        let cues = try XCTUnwrap(handed.forQueue()).cues
        let content = cues.filter(\.isContent)
        let expected = engineContent(id: approvedID, title: "Design review", source: .calendar)
        XCTAssertEqual(content.map(\.sourceItemID), [approvedID])
        XCTAssertEqual(content.map(\.text), expected.map(\.text))
        XCTAssertEqual(content.map(\.source), expected.map(\.source))
        XCTAssertEqual(content.map(\.provenance), expected.map(\.provenance))
        let spoken = cues.map(\.text).joined(separator: " ")
        for hidden in ["Pending sync", "Flagged memo", "Expired reminder", "Revoked note", "Unavailable calendar"] {
            XCTAssertFalse(spoken.contains(hidden), spoken)
        }
    }

    /// An approved Connections row is not enough. The source note's sensitivity still applies.
    func testApprovedBlockedObsidianNoteProducesNoContentCue() async throws {
        let id = UUID()
        let studio = FixtureStudio(
            items: [ConnectionItem(id: id, integration: .obsidian, title: "Private diary", state: .approved)],
            preferences: preferences(),
            sensitivityByItemID: [id: .blocked])
        let now = morning
        let queued = LiveQueueBriefing.provider(studio: studio, now: { now }, calendar: calendar)().forQueue()
        let content = queued?.cues.filter(\.isContent) ?? []
        let spoken = queued?.cues.map(\.text).joined(separator: " ") ?? ""
        XCTAssertTrue(content.isEmpty, spoken)
        XCTAssertFalse(spoken.contains("Private diary"), spoken)
        XCTAssertNil(content.first { $0.sourceItemID == id })
    }

    /// Every `ConnectionItemState` is seeded. Only `.approved` is `.granted`.
    func testOnlyApprovedConnectionStateMapsToGrantedConsent() async throws {
        let states: [ConnectionItemState] = [
            .pendingApproval,
            .flaggedForReview,
            .approved,
            .expired,
            .revoked,
            .unavailable(.calendarAccess(.denied)),
        ]
        XCTAssertEqual(Set(states.map(Self.connectionStateCase)), Set(Self.everyConnectionStateCase))
        let granted = states.filter { LiveQueueBriefing.consent(for: $0) == .granted }
        XCTAssertEqual(granted, [.approved])
        XCTAssertEqual(LiveQueueBriefing.consent(for: .expired), .revoked)
        for state in states where state != .approved {
            XCTAssertNotEqual(LiveQueueBriefing.consent(for: state), .granted, "\(state)")
        }
    }

    /// A new `ConnectionItemState` fails this switch until the seeded list names it.
    private static let everyConnectionStateCase = [
        "pendingApproval", "flaggedForReview", "approved", "expired", "revoked", "unavailable",
    ]

    private static func connectionStateCase(_ state: ConnectionItemState) -> String {
        switch state {
        case .pendingApproval: "pendingApproval"
        case .flaggedForReview: "flaggedForReview"
        case .approved: "approved"
        case .expired: "expired"
        case .revoked: "revoked"
        case .unavailable: "unavailable"
        }
    }

    /// No sensitivity on the input. The adapter must not assume `.low`.
    func testApprovedRowWithUnknownSensitivityProducesNoContentCue() async throws {
        let id = UUID()
        let studio = FixtureStudio(
            items: [ConnectionItem(id: id, integration: .obsidian, title: "Unclassified note", state: .approved)],
            preferences: preferences())
        let now = morning
        let queued = LiveQueueBriefing.provider(studio: studio, now: { now }, calendar: calendar)().forQueue()
        let content = queued?.cues.filter(\.isContent) ?? []
        let spoken = queued?.cues.map(\.text).joined(separator: " ") ?? ""
        XCTAssertTrue(content.isEmpty, spoken)
        XCTAssertFalse(spoken.contains("Unclassified note"), spoken)
    }

    func testLaterShowAndDisabledBriefingStayQuiet() async throws {
        let items = [ConnectionItem(id: UUID(), integration: .calendar, title: "Design review", state: .approved)]
        let on = preferences()
        XCTAssertNil(LiveQueueBriefing.handoff(items: items, preferences: on, now: afternoon, calendar: calendar).forQueue())
        let off = preferences(enabled: false)
        let disabled = LiveQueueBriefing.handoff(items: items, preferences: off, now: morning, calendar: calendar)
        XCTAssertNil(disabled.forQueue())
        XCTAssertTrue(disabled.revokedOrUnapproved)
    }

    func testTurnedOffSectionAndPreparedHandoff() async throws {
        let calendarID = UUID()
        let noteID = UUID()
        let items = [
            ConnectionItem(id: calendarID, integration: .calendar, title: "Design review", state: .approved),
            ConnectionItem(id: noteID, integration: .obsidian, title: "Grocery list", state: .approved),
        ]
        let notesOnly = preferences(sections: [.notes])
        let queued = LiveQueueBriefing.handoff(items: items, preferences: notesOnly, now: morning, calendar: calendar,
                                               sensitivityByItemID: [noteID: .medium, calendarID: .low]).forQueue()
        let content = queued?.cues.filter(\.isContent) ?? []
        let expected = engineContent(id: noteID, title: "Grocery list", source: .obsidian)
        XCTAssertEqual(content.map(\.sourceItemID), [noteID])
        XCTAssertEqual(content.map(\.text), expected.map(\.text))
        XCTAssertEqual(content.map(\.source), [.obsidian])

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
