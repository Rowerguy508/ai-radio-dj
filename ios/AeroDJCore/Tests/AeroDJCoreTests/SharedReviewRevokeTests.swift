import XCTest
@testable import AeroDJCore

/// #593 (-Echo): when `removeSavedChoices()` can't remove `state.json`, the old approvals and
/// reconfirms must never load again, in this process or after a relaunch.
final class SharedReviewRevokeTests: XCTestCase {
    private final class Marker: BackupExclusionMarking, @unchecked Sendable {
        let lock = NSLock()
        private var _readBack: Bool? = true
        var readBack: Bool? {
            get { lock.withLock { _readBack } }
            set { lock.withLock { _readBack = newValue } }
        }
        func markExcluded(_ directory: URL) throws {}
        func isExcluded(_ directory: URL) throws -> Bool? { readBack }
    }
    private final class Lines: @unchecked Sendable {
        let lock = NSLock(); private var _all: [String] = []
        var all: [String] { lock.withLock { _all } }
        func add(_ s: String) { lock.withLock { _all.append(s) } }
    }
    struct Boom: Error {}

    private enum Failing { case remove, overwrite, marker, clearMarker }

    private func ops(failing: Set<Failing>) -> SharedReviewFileOps {
        var ops = SharedReviewFileOps.live
        if failing.contains(.remove) { ops.remove = { _ in throw Boom() } }
        if failing.contains(.overwrite) { ops.overwriteEmpty = { _ in throw Boom() } }
        if failing.contains(.marker) { ops.writeMarker = { _ in throw Boom() } }
        if failing.contains(.clearMarker) { ops.clearMarker = { _ in throw Boom() } }
        return ops
    }

    /// A store with two approved, one reconfirmed, records on disk.
    private func savedStore(failing: Set<Failing>) throws -> (SharedReviewStore, Marker, Lines, [UUID]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("revoke-593-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let marker = Marker(), lines = Lines()
        var store = SharedReviewStore(file: root.appendingPathComponent("Review/state.json"),
                                      backupExclusion: marker, backupExclusionLog: { lines.add($0) })
        let ids = [UUID(), UUID()]
        try store.save([ids[0]: SharedReviewRecord(decision: .approved),
                        ids[1]: SharedReviewRecord(decision: .approved, isReconfirmed: true)])
        XCTAssertEqual(store.load().count, 2)
        store.fileOps = ops(failing: failing)
        return (store, marker, lines, ids)
    }

    /// A relaunch: a new store on the same file with real file operations.
    private func relaunched(_ store: SharedReviewStore, _ marker: Marker) -> SharedReviewStore {
        SharedReviewStore(file: store.file, backupExclusion: marker, backupExclusionLog: { _ in })
    }

    private func assertContentFree(_ lines: Lines, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lines.all, [SharedReviewStore.savedChoicesNotRemovedMessage], file: file, line: line)
    }

    func testARemovedFileLoadsAsPendingAndLogsNothing() throws {
        let (store, marker, lines, _) = try savedStore(failing: [])
        store.removeSavedChoices()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(relaunched(store, marker).load().isEmpty)
        XCTAssertTrue(lines.all.isEmpty)
    }

    func testAFailedRemoveOverwritesTheFileWithNoRecords() throws {
        let (store, marker, lines, _) = try savedStore(failing: [.remove])
        store.removeSavedChoices()
        XCTAssertTrue(store.load().isEmpty, "this process")
        XCTAssertTrue(relaunched(store, marker).load().isEmpty, "a relaunch")
        let data = try Data(contentsOf: store.file)
        XCTAssertEqual(try JSONDecoder().decode([String: SharedReviewRecord].self, from: data), [:], "no records, no content")
        assertContentFree(lines)
    }

    func testAFailedRemoveAndOverwriteLeaveAMarkerSoARelaunchIgnoresTheFile() throws {
        let (store, marker, lines, _) = try savedStore(failing: [.remove, .overwrite])
        store.removeSavedChoices()
        // The old approvals are still in the file, but nothing loads them.
        XCTAssertEqual(try JSONDecoder().decode([String: SharedReviewRecord].self, from: Data(contentsOf: store.file)).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.revokedMarker.path))
        XCTAssertEqual(try Data(contentsOf: store.revokedMarker), Data(), "the marker holds nothing")
        XCTAssertTrue(store.load().isEmpty, "this process")
        XCTAssertTrue(relaunched(store, marker).load().isEmpty, "a relaunch")
        assertContentFree(lines)
    }

    func testWhenEveryStepFailsThisProcessStillIgnoresTheFile() throws {
        let (store, marker, lines, _) = try savedStore(failing: [.remove, .overwrite, .marker])
        store.removeSavedChoices()
        XCTAssertTrue(store.load().isEmpty, "the same store")
        XCTAssertTrue(relaunched(store, marker).load().isEmpty, "a new store in the same process (the sheet builds one per open)")
        assertContentFree(lines)
    }

    func testAVerifiedSaveEndsTheRevocationAndNewChoicesLoadBack() throws {
        let (store, marker, _, ids) = try savedStore(failing: [.remove, .overwrite])
        store.removeSavedChoices()
        try store.save([ids[0]: SharedReviewRecord(decision: .approved)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.revokedMarker.path))
        XCTAssertEqual(store.load(), [ids[0]: SharedReviewRecord(decision: .approved)])
        XCTAssertEqual(relaunched(store, marker).load(), [ids[0]: SharedReviewRecord(decision: .approved)])
    }

    func testAnUnverifiedSaveDoesNotEndTheRevocation() throws {
        let (store, marker, _, ids) = try savedStore(failing: [.remove, .overwrite])
        store.removeSavedChoices()
        marker.readBack = false
        XCTAssertThrowsError(try store.save([ids[0]: SharedReviewRecord(decision: .approved)]))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(relaunched(store, marker).load().isEmpty)
    }

    func testASaveThatCannotClearTheMarkerThrowsAndStillLoadsPending() throws {
        let (store, marker, _, ids) = try savedStore(failing: [.remove, .overwrite, .clearMarker])
        store.removeSavedChoices()
        XCTAssertThrowsError(try store.save([ids[0]: SharedReviewRecord(decision: .approved)]))
        XCTAssertTrue(relaunched(store, marker).load().isEmpty, "fails closed: pending")
    }

    // MARK: Review level

    private func reviewFixture(failing: Set<Failing>) async throws -> (SharedInboxReview, Marker, URL, URL, [UUID]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("revoke-593-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let now = Date()
        var ids: [UUID] = []
        for n in 0..<2 {
            let item = try XCTUnwrap(SharedInboxItem(kind: .text, content: "Shared note \(n).", now: now.addingTimeInterval(Double(n))))
            try JSONEncoder().encode(item).write(to: inbox.appendingPathComponent("\(item.id.uuidString).json"))
            ids.append(item.id)
        }
        let marker = Marker()
        let file = root.appendingPathComponent("Review/state.json")
        var store = SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { _ in })
        store.fileOps = ops(failing: failing)
        let review = SharedInboxReview(reader: SharedInboxReader(directory: inbox), store: store,
                                       now: { now.addingTimeInterval(60) })
        _ = try await review.refresh()
        for id in ids { try await review.setDecision(.approved, for: id) }
        try await review.reconfirm(ids[1])
        return (review, marker, file, inbox, ids)
    }

    func testAnExcludeUnderAFailingMarkAndAFailingRemoveStillRevokesEveryApproval() async throws {
        for failing in [[.remove], [.remove, .overwrite], [.remove, .overwrite, .marker]] as [Set<Failing>] {
            let (review, marker, file, inbox, ids) = try await reviewFixture(failing: failing)
            marker.readBack = false
            do { try await review.setDecision(.excluded, for: ids[0]); XCTFail("must throw") }
            catch { XCTAssertEqual(error as? SharedReviewError, .reviewChoicesResetUnverified, "\(failing)") }
            let entries = await review.entries
            XCTAssertTrue(entries.allSatisfy { $0.decision == .pending && !$0.isReconfirmed }, "\(failing)")
            // Refresh in this process, and a relaunch, both load every item as pending.
            _ = try await review.refresh()
            let refreshed = await review.entries
            XCTAssertTrue(refreshed.allSatisfy { $0.decision == .pending && !$0.isReconfirmed }, "\(failing)")
            let fresh = SharedInboxReview(reader: SharedInboxReader(directory: inbox),
                                          store: SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { _ in }))
            _ = try await fresh.refresh()
            let reloaded = await fresh.entries
            XCTAssertTrue(reloaded.allSatisfy { $0.decision == .pending && !$0.isReconfirmed }, "\(failing)")
            let items = try await fresh.fetchItems()
            XCTAssertFalse(items.contains { $0.consent == .granted }, "\(failing): no consent reaches the briefing")
        }
    }
}
