import XCTest
@testable import AeroDJCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Temporary inbox directory written exactly like the Share Extension does.
private final class TempInbox {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerodj-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func add(_ content: String, kind: SharedInboxItem.Kind = .text, at date: Date = t0,
             retention: TimeInterval = SharedInboxItem.defaultRetention) throws -> SharedInboxItem {
        let item = try XCTUnwrap(SharedInboxItem(kind: kind, content: content, now: date, retention: retention))
        try write(JSONEncoder().encode(item), name: "\(item.id.uuidString).json")
        return item
    }

    func write(_ data: Data, name: String) throws {
        try data.write(to: url.appendingPathComponent(name))
    }

    /// Encodes `item`, applies `edit` to the JSON object, writes it under the item's name.
    func addTampered(_ item: SharedInboxItem, _ edit: (inout [String: Any]) -> Void) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        edit(&json)
        try write(JSONSerialization.data(withJSONObject: json), name: "\(item.id.uuidString).json")
    }

    var fileNames: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }
}

final class SharedInboxReaderTests: XCTestCase {
    func testMissingDirectoryIsEmpty() throws {
        let reader = SharedInboxReader(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertEqual(try reader.load(now: t0), SharedInboxLoadResult(items: [], purged: [:]))
    }

    func testLoadsValidItemsOldestFirst() throws {
        let inbox = try TempInbox()
        let newer = try inbox.add("Second", at: t0.addingTimeInterval(10))
        let older = try inbox.add("First", at: t0)
        let result = try SharedInboxReader(directory: inbox.url).load(now: t0.addingTimeInterval(20))
        XCTAssertEqual(result.items.map(\.id), [older.id, newer.id])
        XCTAssertTrue(result.purged.isEmpty)
    }

    func testExpiredItemsArePurgedFromDisk() throws {
        let inbox = try TempInbox()
        let gone = try inbox.add("Old", retention: 60)
        let kept = try inbox.add("New")
        let result = try SharedInboxReader(directory: inbox.url).load(now: t0.addingTimeInterval(60))
        XCTAssertEqual(result.items.map(\.id), [kept.id])
        XCTAssertEqual(result.purged, ["\(gone.id.uuidString).json": .expired])
        XCTAssertEqual(inbox.fileNames, ["\(kept.id.uuidString).json"])
    }

    func testMalformedAndUnexpectedFilesArePurged() throws {
        let inbox = try TempInbox()
        let badJSON = "\(UUID().uuidString).json"
        try inbox.write(Data("{not json".utf8), name: badJSON)
        try inbox.write(Data("{}".utf8), name: "notes.txt")
        try inbox.write(Data("tmp".utf8), name: ".tmp-write")
        let result = try SharedInboxReader(directory: inbox.url).load(now: t0)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.purged, [badJSON: .malformed, "notes.txt": .malformed])
        XCTAssertEqual(inbox.fileNames, [".tmp-write"], "dotfiles are left alone")
    }

    func testTamperedEnvelopesAreRejected() throws {
        let inbox = try TempInbox()
        let wrongSource = try XCTUnwrap(SharedInboxItem(kind: .text, content: "a", now: t0))
        try inbox.addTampered(wrongSource) { $0["source"] = "calendar" }
        let oversize = try XCTUnwrap(SharedInboxItem(kind: .text, content: "b", now: t0))
        try inbox.addTampered(oversize) {
            $0["content"] = String(repeating: "x", count: SharedInboxItem.maxContentBytes + 1)
        }
        let longRetention = try XCTUnwrap(SharedInboxItem(kind: .text, content: "c", now: t0))
        try inbox.addTampered(longRetention) {
            $0["expiresAt"] = t0.addingTimeInterval(365 * 86_400).timeIntervalSinceReferenceDate
        }
        let blank = try XCTUnwrap(SharedInboxItem(kind: .text, content: "d", now: t0))
        try inbox.addTampered(blank) { $0["content"] = "   " }
        let mismatched = try XCTUnwrap(SharedInboxItem(kind: .text, content: "e", now: t0))
        try inbox.addTampered(mismatched) { $0["id"] = UUID().uuidString }

        let result = try SharedInboxReader(directory: inbox.url).load(now: t0)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(Set(result.purged.values), [.invalid])
        XCTAssertEqual(result.purged.count, 5)
        XCTAssertTrue(inbox.fileNames.isEmpty)
    }

    func testOversizedFileIsPurgedWithoutDecoding() throws {
        let inbox = try TempInbox()
        let name = "\(UUID().uuidString).json"
        try inbox.write(Data(count: SharedInboxReader.maxFileBytes + 1), name: name)
        let result = try SharedInboxReader(directory: inbox.url).load(now: t0)
        XCTAssertEqual(result.purged, [name: .tooLarge])
    }

    func testDeleteIsIdempotent() throws {
        let inbox = try TempInbox()
        let item = try inbox.add("x")
        let reader = SharedInboxReader(directory: inbox.url)
        try reader.delete(id: item.id)
        try reader.delete(id: item.id)
        XCTAssertTrue(inbox.fileNames.isEmpty)
    }
}

final class SharedInboxReviewTests: XCTestCase {
    private func review(_ inbox: TempInbox, now: Date = t0) -> SharedInboxReview {
        SharedInboxReview(reader: SharedInboxReader(directory: inbox.url), now: { now })
    }

    func testNewSharesArePendingAndNotNarratable() async throws {
        let inbox = try TempInbox()
        let shared = try inbox.add("Dinner with Sam moved to 8pm.")
        let review = review(inbox)
        try await review.refresh()
        let fetched = try await review.fetchItems()
        let item = try XCTUnwrap(fetched.first)
        XCTAssertEqual(item.id, shared.id)
        XCTAssertEqual(item.source, .userShared)
        XCTAssertEqual(item.consent, .notRequested)
        XCTAssertEqual(item.sensitivity, .medium)
        XCTAssertEqual(item.expiresAt, shared.expiresAt)
        XCTAssertEqual(item.provenance, "shared-inbox:\(shared.id.uuidString)")
        XCTAssertFalse(item.isNarratable(at: t0))
    }

    func testApproveExcludeAndLabelControlConsentAndSource() async throws {
        let inbox = try TempInbox()
        let a = try inbox.add("A", at: t0)
        let b = try inbox.add("B", at: t0.addingTimeInterval(1))
        let review = review(inbox, now: t0.addingTimeInterval(2))
        try await review.refresh()
        try await review.setDecision(.approved, for: a.id)
        try await review.setLabel(.email, for: a.id)
        try await review.setDecision(.excluded, for: b.id)
        try await review.setLabel(.message, for: b.id)
        let items = try await review.fetchItems()
        XCTAssertEqual(items.map(\.consent), [.granted, .denied])
        XCTAssertEqual(items.map(\.source), [.emailShared, .messagesShared])
    }

    func testDeleteRemovesFileAndImmediatelyStopsNarration() async throws {
        let inbox = try TempInbox()
        let shared = try inbox.add("Board meeting moved to Tuesday.")
        let review = review(inbox)
        try await review.refresh()
        try await review.setDecision(.approved, for: shared.id)
        let planner = DefaultBriefingPlanner(now: { t0 })
        let before = try await planner.plan(from: review.fetchItems(), targetSpokenSeconds: 150)
        XCTAssertEqual(before.segments.map(\.sourceItemID), [shared.id])

        try await review.delete(shared.id)
        let after = try await planner.plan(from: review.fetchItems(), targetSpokenSeconds: 150)
        XCTAssertTrue(after.segments.isEmpty)
        XCTAssertTrue(inbox.fileNames.isEmpty)
        try await review.refresh()
        let reloaded = try await review.fetchItems()
        XCTAssertTrue(reloaded.isEmpty)
    }

    func testRedactionReplacesNarratedTextAndTitle() async throws {
        let inbox = try TempInbox()
        let shared = try inbox.add("https://bank.example.com/statement?acct=123", kind: .url)
        let review = review(inbox)
        try await review.refresh()
        let fetched = try await review.fetchItems()
        var item = try XCTUnwrap(fetched.first)
        XCTAssertEqual(item.title, "Link from bank.example.com")

        try await review.redact(shared.id, to: "  Statement is ready  ")
        let redacted = try await review.fetchItems()
        item = try XCTUnwrap(redacted.first)
        XCTAssertEqual(item.title, "Statement is ready")
        XCTAssertEqual(item.summary, "Statement is ready")
        XCTAssertFalse(item.summary.contains("acct"))
        do {
            try await review.redact(shared.id, to: " \n ")
            XCTFail("expected emptyRedaction")
        } catch SharedReviewError.emptyRedaction {}
    }

    func testUnknownIDsThrow() async throws {
        let review = review(try TempInbox())
        let id = UUID()
        do { try await review.delete(id); XCTFail() } catch SharedReviewError.unknownItem {}
        do { try await review.setDecision(.approved, for: id); XCTFail() } catch SharedReviewError.unknownItem {}
    }

    func testRefreshKeepsDecisionsAndDropsExternallyRemovedItems() async throws {
        let inbox = try TempInbox()
        let a = try inbox.add("A")
        let b = try inbox.add("B", at: t0.addingTimeInterval(1))
        let review = review(inbox, now: t0.addingTimeInterval(2))
        try await review.refresh()
        try await review.setDecision(.approved, for: a.id)
        try SharedInboxReader(directory: inbox.url).delete(id: b.id)
        try await review.refresh()
        let entries = await review.entries
        XCTAssertEqual(entries.map(\.id), [a.id])
        XCTAssertEqual(entries.first?.decision, .approved)
    }

    func testItemsExpiringAfterRefreshAreNotReturned() async throws {
        let inbox = try TempInbox()
        try inbox.add("Soon gone", retention: 60)
        let clock = Clock(t0)
        let review = SharedInboxReview(reader: SharedInboxReader(directory: inbox.url), now: { clock.now })
        try await review.refresh()
        clock.now = t0.addingTimeInterval(61)
        let items = try await review.fetchItems()
        XCTAssertTrue(items.isEmpty)
    }

    func testLongTextIsBoundedInTitleAndSummary() async throws {
        let inbox = try TempInbox()
        try inbox.add((1...80).map { "w\($0)" }.joined(separator: " "))
        let review = review(inbox)
        try await review.refresh()
        let fetched = try await review.fetchItems()
        let item = try XCTUnwrap(fetched.first)
        XCTAssertEqual(item.title.count, SharedInboxReview.maxTitleCharacters + 1)
        XCTAssertEqual(item.summary.split(separator: " ").count, SharedInboxReview.maxSummaryWords)
        XCTAssertTrue(item.summary.hasSuffix("…"))
    }
}

final class SharedReviewPersistenceTests: XCTestCase {
    private func review(_ inbox: TempInbox, store: URL, now: Date = t0) -> SharedInboxReview {
        SharedInboxReview(reader: SharedInboxReader(directory: inbox.url), store: SharedReviewStore(file: store), now: { now })
    }

    private func stateFile(_ inbox: TempInbox) -> URL {
        inbox.url.deletingLastPathComponent().appendingPathComponent("review-\(UUID().uuidString)/state.json")
    }

    // Regression (integrated review #45): approval was lost on relaunch -> empty briefing.
    func testDecisionsSurviveRelaunch() async throws {
        let inbox = try TempInbox()
        let a = try inbox.add("Dentist moved to Thursday.")
        let b = try inbox.add("Spam", at: t0.addingTimeInterval(1))
        let state = stateFile(inbox)
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let first = review(inbox, store: state, now: t0.addingTimeInterval(2))
        try await first.refresh()
        try await first.setDecision(.approved, for: a.id)
        try await first.setLabel(.message, for: a.id)
        try await first.setDecision(.excluded, for: b.id)

        let relaunched = review(inbox, store: state, now: t0.addingTimeInterval(3))
        try await relaunched.refresh()
        let items = try await relaunched.fetchItems()
        XCTAssertEqual(items.map(\.consent), [.granted, .denied])
        XCTAssertEqual(items.first?.source, .messagesShared)
    }

    func testRedactionRemovesOriginalFromDiskAndPersists() async throws {
        let inbox = try TempInbox()
        let shared = try inbox.add("Call Dr. Smith at 555-0100 about results")
        let state = stateFile(inbox)
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let first = review(inbox, store: state)
        try await first.refresh()
        try await first.redact(shared.id, to: "Call the doctor about results")
        try await first.setDecision(.approved, for: shared.id)
        let raw = try String(contentsOf: inbox.url.appendingPathComponent("\(shared.id.uuidString).json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("555-0100"))
        XCTAssertFalse(raw.contains("Smith"))

        let relaunched = review(inbox, store: state)
        try await relaunched.refresh()
        let entries = await relaunched.entries
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.redactedText, "Call the doctor about results")
        XCTAssertEqual(entry.decision, .approved)
        XCTAssertEqual(entry.item.expiresAt, shared.expiresAt)
    }

    func testDeleteAndExternalRemovalPruneState() async throws {
        let inbox = try TempInbox()
        let a = try inbox.add("A")
        let state = stateFile(inbox)
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        let r = review(inbox, store: state)
        try await r.refresh()
        try await r.setDecision(.approved, for: a.id)
        XCTAssertEqual(SharedReviewStore(file: state).load().count, 1)
        try await r.delete(a.id)
        XCTAssertTrue(SharedReviewStore(file: state).load().isEmpty)
    }

    func testCorruptStateFailsClosedToPending() async throws {
        let inbox = try TempInbox()
        try inbox.add("A")
        let state = stateFile(inbox)
        defer { try? FileManager.default.removeItem(at: state.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: state)
        let r = review(inbox, store: state)
        try await r.refresh()
        let items = try await r.fetchItems()
        XCTAssertEqual(items.map(\.consent), [.notRequested])
    }

    func testForwardDatedEnvelopeIsPurgedAndDirectoriesAreNotDeleted() throws {
        let inbox = try TempInbox()
        try inbox.add("From the future", at: t0.addingTimeInterval(3600))
        try inbox.add("Skewed but ok", at: t0.addingTimeInterval(60))
        let dir = inbox.url.appendingPathComponent("\(UUID().uuidString).json", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = try SharedInboxReader(directory: inbox.url).load(now: t0)
        XCTAssertEqual(result.items.map(\.content), ["Skewed but ok"])
        XCTAssertEqual(Array(result.purged.values), [.forwardDated])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "non-regular entries are skipped, not purged")
    }

    func testURLShareIsNotSpokenAsURL() async throws {
        let inbox = try TempInbox()
        try inbox.add("https://bank.example.com/statement?acct=123", kind: .url)
        let r = SharedInboxReview(reader: SharedInboxReader(directory: inbox.url), now: { t0 })
        try await r.refresh()
        let fetched = try await r.fetchItems()
        let item = try XCTUnwrap(fetched.first)
        XCTAssertEqual(item.summary, "Link from bank.example.com")
        XCTAssertFalse(item.summary.contains("://"))
    }
}

/// Mutable test clock.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
