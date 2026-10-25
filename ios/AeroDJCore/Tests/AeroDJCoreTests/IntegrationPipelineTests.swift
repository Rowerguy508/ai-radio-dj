import XCTest
@testable import AeroDJCore

/// End-to-end pipeline tests for #45: context sources → review/consent →
/// briefing engine → broadcast scheduler. Every component is the real
/// implementation; only the file system and clock are fixtures.
final class IntegrationPipelineTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private var morning: Date { utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 7))! }

    private struct NotesFixture: MarkdownDocumentReader {
        let files: [String: String]
        func selectedPaths() async throws -> [String] { Array(files.keys) }
        func read(relativePath: String) async throws -> Data { Data(files[relativePath]!.utf8) }
    }

    /// Writes Share Extension envelopes the way `AeroDJShareViewController` does.
    private func inbox(_ texts: [String], sharedAt: Date) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for text in texts {
            let item = try XCTUnwrap(SharedInboxItem(kind: .text, content: text, now: sharedAt))
            try JSONEncoder().encode(item).write(to: dir.appendingPathComponent("\(item.id.uuidString).json"))
        }
        return dir
    }

    /// The review screen's "include" action for Obsidian items (phase 2 UI).
    private func approved(_ item: ContextItem) -> ContextItem {
        ContextItem(id: item.id, source: item.source, createdAt: item.createdAt, eventAt: item.eventAt,
                    title: item.title, summary: item.summary, sensitivity: item.sensitivity,
                    consent: .granted, expiresAt: item.expiresAt, provenance: item.provenance)
    }

    private func spoken(_ script: BriefingScript) -> String {
        script.segments.map(\.text).joined(separator: " ")
    }

    func testOnlyApprovedContextReachesTheSchedule() async throws {
        let now = morning
        let dir = try inbox(["Dentist moved to Thursday", "Private: do not read this aloud"],
                            sharedAt: now.addingTimeInterval(-3600))
        let review = SharedInboxReview(reader: SharedInboxReader(directory: dir), now: { now })
        try await review.refresh()
        let entries = await review.entries
        let dentist = try XCTUnwrap(entries.first { $0.item.content.hasPrefix("Dentist") })
        try await review.setLabel(.message, for: dentist.id)
        try await review.setDecision(.approved, for: dentist.id)

        let notes = ObsidianContextSource(
            reader: NotesFixture(files: ["inbox.md": "# Renew passport\nForms are in the blue folder."]),
            calendar: utc, now: { now })
        let noteItems = try await notes.importNotes().items
        XCTAssertTrue(noteItems.allSatisfy { $0.consent == .notRequested }, "imports start unapproved")

        let items = try await review.fetchItems() + noteItems.map(approved)
        let engine = MorningBriefingEngine(calendar: utc, now: { now })
        let script = engine.script(from: items)
        let text = spoken(script)
        XCTAssertTrue(text.contains("Dentist moved to Thursday. From a message you shared."))
        XCTAssertTrue(text.contains("Renew passport"))
        XCTAssertFalse(text.contains("do not read this aloud"))

        let slots = try await DefaultBroadcastScheduler().schedule(plan: script.plan, trackCount: 8)
        let scheduledSources = Set(slots.compactMap(\.segment.sourceItemID))
        let approvedIDs = Set(items.filter { $0.consent == .granted }.map(\.id))
        XCTAssertTrue(scheduledSources.isSubset(of: approvedIDs), "only approved items may be scheduled")
        XCTAssertEqual(scheduledSources, approvedIDs, "with enough tracks, every approved item is scheduled")
    }

    func testExpiredShareNeverReachesTheSchedule() async throws {
        let sharedAt = morning.addingTimeInterval(-8 * 24 * 3600) // older than the 7-day retention
        let dir = try inbox(["Stale reminder"], sharedAt: sharedAt)
        let review = SharedInboxReview(reader: SharedInboxReader(directory: dir), now: { [morning] in morning })
        let load = try await review.refresh()
        XCTAssertEqual(Array(load.purged.values), [.expired])
        let script = MorningBriefingEngine(calendar: utc, now: { [morning] in morning })
            .script(from: try await review.fetchItems())
        XCTAssertTrue(script.isEmpty)
        let slots = try await DefaultBroadcastScheduler().schedule(plan: script.plan, trackCount: 4)
        XCTAssertTrue(slots.allSatisfy { $0.segment.sourceItemID == nil }, "only fixed lines, no personal content")
    }

    func testRevokedConsentRemovesItemFromNextBriefing() async throws {
        let now = morning
        let dir = try inbox(["Pick up dry cleaning"], sharedAt: now.addingTimeInterval(-600))
        let review = SharedInboxReview(reader: SharedInboxReader(directory: dir), now: { now })
        try await review.refresh()
        let entries = await review.entries
        let id = try XCTUnwrap(entries.first).id
        try await review.setDecision(.approved, for: id)
        let engine = MorningBriefingEngine(calendar: utc, now: { now })
        let whileApproved = try await review.fetchItems()
        XCTAssertTrue(spoken(engine.script(from: whileApproved)).contains("dry cleaning"))

        try await review.setDecision(.excluded, for: id)
        let afterExclude = try await review.fetchItems()
        XCTAssertFalse(spoken(engine.script(from: afterExclude)).contains("dry cleaning"))
    }

    func testPipelineIsDeterministicAndWithinBudget() async throws {
        let now = morning
        let texts = (0..<12).map { "Shared item \($0) with a reasonably long sentence to read on air" }
        let dir = try inbox(texts, sharedAt: now.addingTimeInterval(-600))
        let review = SharedInboxReview(reader: SharedInboxReader(directory: dir), now: { now })
        try await review.refresh()
        for entry in await review.entries { try await review.setDecision(.approved, for: entry.id) }
        let items = try await review.fetchItems()

        let engine = MorningBriefingEngine(calendar: utc, now: { now })
        let first = engine.script(from: items)
        let second = engine.script(from: items.reversed())
        XCTAssertEqual(first.segments.map(\.text), second.segments.map(\.text), "order-independent output")
        XCTAssertLessThanOrEqual(first.estimatedSpokenSeconds, engine.configuration.maxSpokenSeconds)

        let scheduler = DefaultBroadcastScheduler()
        let slotsA = try await scheduler.schedule(plan: first.plan, trackCount: 10)
        let slotsB = try await scheduler.schedule(plan: second.plan, trackCount: 10)
        XCTAssertEqual(slotsA, slotsB)
        XCTAssertTrue(slotsA.allSatisfy { (0..<10).contains($0.afterTrackIndex) })
    }
}
