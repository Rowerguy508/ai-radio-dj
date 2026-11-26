import XCTest
@testable import AeroDJCore

/// #671 (-Atlas): an exclude, delete or edit that fails to save for ANY reason must not leave an
/// approval in `state.json` that loads as approved after a relaunch. #426 and #593 covered
/// `backupExclusionUnverified`; these tests cover every other error on the exclude and write path.
final class SharedReviewExcludeFailClosedTests: XCTestCase {
    private struct OddError: Error {}

    private final class Marker: BackupExclusionMarking, @unchecked Sendable {
        let lock = NSLock()
        private var _markThrows: (any Error)?
        private var _readBack: Bool? = true
        var markThrows: (any Error)? {
            get { lock.withLock { _markThrows } }
            set { lock.withLock { _markThrows = newValue } }
        }
        var readBack: Bool? {
            get { lock.withLock { _readBack } }
            set { lock.withLock { _readBack = newValue } }
        }
        func markExcluded(_ directory: URL) throws { if let e = markThrows { throw e } }
        func isExcluded(_ directory: URL) throws -> Bool? { readBack }
    }

    private struct Fixture {
        let review: SharedInboxReview
        let marker: Marker
        let file: URL
        let inbox: URL
        let ids: [UUID]
    }

    /// A review with two approved items, one reconfirmed, saved to disk. `configure` changes the store
    /// AFTER the approvals are saved, so the failure under test hits the exclude.
    private func fixture(optIn: Bool = false, configure: (inout SharedReviewStore, Marker) -> Void) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("excl-671-\(UUID().uuidString)")
        addTeardownBlock {
            _ = chmod(root.appendingPathComponent("Review").path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
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
        let review = SharedInboxReview(reader: SharedInboxReader(directory: inbox), store: store,
                                       now: { now.addingTimeInterval(60) })
        _ = try await review.refresh()
        if optIn { try await review.setBackupOptIn(true) }
        for id in ids { try await review.setDecision(.approved, for: id) }
        try await review.reconfirm(ids[1])
        // The review holds its own copy of the store, so rebuild it with the failing seams.
        configure(&store, marker)
        let failing = SharedInboxReview(reader: SharedInboxReader(directory: inbox), store: store,
                                        now: { now.addingTimeInterval(60) })
        _ = try await failing.refresh()
        XCTAssertEqual(store.load().count, 2, "setup: two approvals are saved")
        return Fixture(review: failing, marker: marker, file: file, inbox: inbox, ids: ids)
    }

    /// The decisive checks: the failed change threw the reset error, nothing is approved in this
    /// process, after `refresh()`, or after a relaunch, no consent reaches the briefing, and an
    /// approval is not left readable on disk (it is gone, emptied, or ignored by the revoked marker).
    @discardableResult
    private func assertFailsClosed(_ f: Fixture, change: (SharedInboxReview) async throws -> Void,
                                   approvalMayRemainOnDisk: Bool = false,
                                   file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
        do { try await change(f.review); XCTFail("must throw", file: file, line: line) }
        catch { XCTAssertEqual(error as? SharedReviewError, .reviewChoicesResetUnverified, file: file, line: line) }
        // On disk, right after the failure (a later save ends the revocation): an approval may only
        // remain in a file that the revoked marker makes unloadable.
        let diskStore = SharedReviewStore(file: f.file, backupExclusion: f.marker, backupExclusionLog: { _ in })
        let markerLeft = FileManager.default.fileExists(atPath: diskStore.revokedMarker.path)
        if let data = try? Data(contentsOf: f.file),
           let records = try? JSONDecoder().decode([String: SharedReviewRecord].self, from: data),
           !approvalMayRemainOnDisk, records.values.contains(where: { $0.decision == .approved }) {
            XCTAssertTrue(markerLeft, "an approval left in state.json must be covered by the revoked marker", file: file, line: line)
        }
        let entries = await f.review.entries
        XCTAssertTrue(entries.allSatisfy { $0.decision != .approved && !$0.isReconfirmed }, "memory", file: file, line: line)
        // A refresh after the reset may itself throw (its prune save hits the same failing seam); the
        // entries it leaves must still be pending. #671 leaves refresh's error handling as it was.
        _ = try? await f.review.refresh()
        let refreshed = await f.review.entries
        XCTAssertTrue(refreshed.allSatisfy { $0.decision != .approved && !$0.isReconfirmed }, "refresh", file: file, line: line)
        let relaunched = SharedInboxReview(reader: SharedInboxReader(directory: f.inbox),
                                           store: SharedReviewStore(file: f.file, backupExclusion: f.marker, backupExclusionLog: { _ in }))
        _ = try? await relaunched.refresh()   // its prune save may fail on the same broken disk
        let reloaded = await relaunched.entries
        XCTAssertTrue(reloaded.allSatisfy { $0.decision != .approved && !$0.isReconfirmed }, "relaunch", file: file, line: line)
        let items = try await relaunched.fetchItems()
        XCTAssertFalse(items.contains { $0.consent == .granted }, "no consent reaches the briefing", file: file, line: line)
        return markerLeft
    }

    private func exclude(_ f: Fixture) -> (SharedInboxReview) async throws -> Void {
        { review in try await review.setDecision(.excluded, for: f.ids[0]) }
    }

    // MARK: each error path

    func testExcludeMarkThrowingAnUnexpectedErrorFailsClosed() async throws {
        let f = try await fixture { _, marker in marker.markThrows = OddError() }
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testExcludeMarkThrowingACocoaErrorFailsClosed() async throws {
        let f = try await fixture { _, marker in marker.markThrows = CocoaError(.fileWriteOutOfSpace) }
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testTheWriteFailingWithNoSpaceLeavesNoApprovalLoadable() async throws {
        let f = try await fixture { store, _ in store.writeState = { _, _ in throw CocoaError(.fileWriteOutOfSpace) } }
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testTheReplaceFailingWithAPosixErrorLeavesNoApprovalLoadable() async throws {
        let f = try await fixture { store, _ in store.writeState = { _, _ in throw POSIXError(.EXDEV) } }
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testAWriteThatFailsAfterTruncatingTheFileLeavesNoApprovalLoadable() async throws {
        let f = try await fixture { store, _ in
            store.writeState = { _, url in
                try Data("{\"half".utf8).write(to: url)   // a torn, unreadable file, then the failure
                throw OddError()
            }
        }
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testAFailedWriteWithTheRemoveAlsoFailingStillRevokesTheOldFile() async throws {
        let f = try await fixture { store, _ in
            store.writeState = { _, _ in throw OddError() }
            store.fileOps.remove = { _ in throw OddError() }
        }
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testAFailedWriteWithRemoveAndOverwriteFailingLeavesTheRevokedMarker() async throws {
        let f = try await fixture { store, _ in
            store.writeState = { _, _ in throw OddError() }
            store.fileOps.remove = { _ in throw OddError() }
            store.fileOps.overwriteEmpty = { _ in throw OddError() }
        }
        let markerLeft = try await assertFailsClosed(f, change: exclude(f))
        XCTAssertTrue(markerLeft, "the old approvals are still in the file, covered by the marker")
    }

    func testWhenEveryRemovalStepFailsThisProcessStillLoadsPending() async throws {
        let f = try await fixture { store, _ in
            store.writeState = { _, _ in throw OddError() }
            store.fileOps.remove = { _ in throw OddError() }
            store.fileOps.overwriteEmpty = { _ in throw OddError() }
            store.fileOps.writeMarker = { _ in throw OddError() }
        }
        // The documented limit (same as #593): with remove, overwrite and marker all failing, the old
        // file stays on disk and only the in-memory revocation holds, for this process and any new
        // store in it. Nothing else can be written in that state.
        let markerLeft = try await assertFailsClosed(f, change: exclude(f), approvalMayRemainOnDisk: true)
        XCTAssertFalse(markerLeft)
    }

    func testARevokedMarkerThatCannotBeClearedFailsClosedOnTheNextExclude() async throws {
        // An earlier revocation left the marker; the next save can't clear it and throws a non-exclusion error.
        let f = try await fixture { store, _ in
            store.fileOps.clearMarker = { _ in throw OddError() }
        }
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testAnUnwritableReviewFolderFailsClosed() async throws {
        try XCTSkipIf(getuid() == 0, "root ignores directory permissions")
        let f = try await fixture { _, _ in }
        XCTAssertEqual(chmod(f.file.deletingLastPathComponent().path, 0o555), 0)
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testAnUnreadableStoreThatCannotBeSetAsideFailsClosed() async throws {
        try XCTSkipIf(getuid() == 0, "root ignores directory permissions")
        let f = try await fixture { _, _ in }
        try Data("{\"half".utf8).write(to: f.file)
        XCTAssertEqual(chmod(f.file.deletingLastPathComponent().path, 0o555), 0)
        try await assertFailsClosed(f, change: exclude(f))
    }

    // MARK: the other reducing changes, and the opt-in path

    func testADeleteWhoseSaveFailsForAnotherReasonFailsClosed() async throws {
        let f = try await fixture { store, _ in store.writeState = { _, _ in throw OddError() } }
        try await assertFailsClosed(f, change: { review in try await review.delete(f.ids[0]) })
    }

    func testAnEditWhoseSaveFailsForAnotherReasonFailsClosed() async throws {
        let f = try await fixture { store, _ in store.writeState = { _, _ in throw OddError() } }
        try await assertFailsClosed(f, change: { review in try await review.redact(f.ids[0], to: "Edited note.") })
    }

    func testMovingAnApprovedItemBackToPendingWhoseSaveFailsFailsClosed() async throws {
        let f = try await fixture { store, _ in store.writeState = { _, _ in throw OddError() } }
        try await assertFailsClosed(f, change: { review in try await review.setDecision(.pending, for: f.ids[0]) })
    }

    func testAWriteFailureWhileOptedInToBackupFailsClosed() async throws {
        let f = try await fixture(optIn: true) { store, _ in store.writeState = { _, _ in throw OddError() } }
        try await assertFailsClosed(f, change: exclude(f))
    }

    // MARK: unchanged behavior

    func testTheExistingBackupExclusionUnverifiedPathStillResets() async throws {
        let f = try await fixture { _, marker in marker.readBack = false }
        try await assertFailsClosed(f, change: exclude(f))
    }

    func testASuccessfulExcludeIsStillAnOrdinaryUnthrownSave() async throws {
        let f = try await fixture { _, _ in }
        try await f.review.setDecision(.excluded, for: f.ids[0])
        let entries = await f.review.entries
        XCTAssertEqual(entries.first { $0.id == f.ids[0] }?.decision, .excluded)
        XCTAssertEqual(entries.first { $0.id == f.ids[1] }?.decision, .approved, "other approvals are kept when the save works")
    }

    func testAFailedApproveStillLeavesTheReviewUnchangedAndDoesNotResetOthers() async throws {
        let f = try await fixture { store, _ in store.writeState = { _, _ in throw OddError() } }
        _ = try await f.review.refresh()
        do { try await f.review.setLabel(.other, for: f.ids[0]); XCTFail("must throw") }
        catch { XCTAssertNil(error as? SharedReviewError, "the raw error is unchanged for non-reducing changes") }
        let entries = await f.review.entries
        XCTAssertTrue(entries.allSatisfy { $0.decision == .approved }, "a failed non-reducing save changes nothing")
    }
}
