import XCTest
@testable import AeroDJCore

/// #592 (-Atlas): review choices may go into backups only with the user's explicit, verified
/// opt-in. Off by default; turning it off re-marks the folder or removes the saved choices; and a
/// #593 revocation still ends only with a save that completes.
final class SharedReviewBackupOptInTests: XCTestCase {
    private final class Marker: BackupExclusionMarking, @unchecked Sendable {
        private let lock = NSLock()
        private var _readBack: Bool? = true
        private var _marks = 0
        var readBack: Bool? {
            get { lock.withLock { _readBack } }
            set { lock.withLock { _readBack = newValue } }
        }
        var marks: Int { lock.withLock { _marks } }
        func markExcluded(_ directory: URL) throws { lock.withLock { _marks += 1 } }
        func isExcluded(_ directory: URL) throws -> Bool? { readBack }
    }
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var _all: [String] = []
        var all: [String] { lock.withLock { _all } }
        func add(_ s: String) { lock.withLock { _all.append(s) } }
    }
    private final class Included: @unchecked Sendable {
        private let lock = NSLock(); private var _dirs: [URL] = []
        var dirs: [URL] { lock.withLock { _dirs } }
        func add(_ u: URL) { lock.withLock { _dirs.append(u) } }
    }
    struct Boom: Error {}

    private func root() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("optin-592-\(UUID().uuidString)")
        addTeardownBlock {
            // A test may leave the folder read-only; make it writable so it can be removed.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.appendingPathComponent("Review").path)
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    /// A store whose folder-include step is recorded instead of touching resource values.
    private func store(_ marker: Marker, lines: Lines = Lines(), included: Included = Included(),
                       at file: URL? = nil) -> SharedReviewStore {
        let file = file ?? root().appendingPathComponent("Review/state.json")
        var store = SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { lines.add($0) })
        store.optInOps.markIncluded = { included.add($0) }
        return store
    }

    private func approvals(_ n: Int) -> [UUID: SharedReviewRecord] {
        Dictionary(uniqueKeysWithValues: (0..<n).map { _ in (UUID(), SharedReviewRecord(decision: .approved, isReconfirmed: true)) })
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A relaunch: the in-process opt-out and revocation sets are gone, only the disk remains.
    private func relaunched(_ s: SharedReviewStore, _ marker: Marker) -> SharedReviewStore {
        SharedReviewBackupOptOuts.shared.clear(s.file)
        SharedReviewRevocations.shared.clear(s.file)
        return SharedReviewStore(file: s.file, backupExclusion: marker, backupExclusionLog: { _ in })
    }

    // MARK: Default

    func testOffByDefaultSoAFailedMarkStillBlocksTheSave() throws {
        let marker = Marker(); marker.readBack = false
        let s = store(marker)
        XCTAssertFalse(s.isBackupOptedIn)
        XCTAssertThrowsError(try s.save(approvals(1))) {
            XCTAssertEqual($0 as? SharedReviewError, .backupExclusionUnverified)
        }
        XCTAssertFalse(exists(s.file), "#426's fail-closed default is unchanged")
        XCTAssertFalse(exists(s.backupOptInFile))
    }

    func testAnOptInFileWithAnythingButOnReadsAsOff() throws {
        let marker = Marker(); marker.readBack = false
        let s = store(marker)
        try FileManager.default.createDirectory(at: s.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for content in ["", "off", "On", "on\n", "yes", "1", "{\"on\":true}"] {
            try Data(content.utf8).write(to: s.backupOptInFile)
            XCTAssertFalse(s.isBackupOptedIn, "\(content.debugDescription) is not an opt-in")
            XCTAssertThrowsError(try s.save(approvals(1)), "\(content.debugDescription): the mark is still required")
        }
        XCTAssertFalse(exists(s.file))
    }

    // MARK: Turning it on

    func testTurningItOnStartsPersistingWithoutTheExclusionAndClearsTheFolderFlag() throws {
        let marker = Marker(), included = Included()
        let s = store(marker, included: included)
        try s.setBackupOptIn(true)
        XCTAssertTrue(s.isBackupOptedIn)
        XCTAssertEqual(try Data(contentsOf: s.backupOptInFile), Data("on".utf8), "holds only the word on")
        XCTAssertEqual(included.dirs.map(\.standardizedFileURL), [s.file.deletingLastPathComponent().standardizedFileURL])

        marker.readBack = false                         // the folder is not (no longer) excluded
        let records = approvals(2)
        try s.save(records)
        XCTAssertEqual(s.load(), records, "saved and loaded with the opt-in on")
        XCTAssertEqual(marker.marks, 0, "the folder is never re-marked excluded while opted in")
        XCTAssertTrue(relaunched(s, marker).isBackupOptedIn, "the opt-in survives a relaunch")
    }

    func testAnOptInThatDoesNotReadBackStaysOffAndLeavesNoFile() throws {
        let marker = Marker(); marker.readBack = false
        let s0 = store(marker)
        for failure in ["write", "read", "content"] {
            var s = s0
            switch failure {
            case "write": s.optInOps.write = { _, _ in throw Boom() }
            case "read": s.optInOps.read = { _ in throw Boom() }
            default: s.optInOps.write = { _, url in try Data("of".utf8).write(to: url) }
            }
            XCTAssertThrowsError(try s.setBackupOptIn(true), failure) {
                XCTAssertEqual($0 as? SharedReviewError, .backupOptInUnverified)
            }
            XCTAssertFalse(s0.isBackupOptedIn, failure)
            XCTAssertFalse(exists(s.backupOptInFile), "\(failure): nothing a later read could take as on")
            XCTAssertThrowsError(try s0.save(approvals(1)), "\(failure): the mark is still required")
        }
        XCTAssertFalse(exists(s0.file))
    }

    func testAFolderFlagThatCanNotBeClearedLogsOneContentFreeLine() throws {
        let marker = Marker(), lines = Lines()
        var s = store(marker, lines: lines)
        s.optInOps.markIncluded = { _ in throw Boom() }
        try s.setBackupOptIn(true)
        XCTAssertTrue(s.isBackupOptedIn, "the choice is kept; the folder just stays excluded (private)")
        XCTAssertEqual(lines.all, [SharedReviewStore.backupInclusionFailureMessage])
        XCTAssertFalse(lines.all.joined().contains(s.file.path))
    }

    // MARK: Turning it off

    func testTurningItOffReMarksTheFolderAndKeepsTheChoices() throws {
        let marker = Marker()
        let s = store(marker)
        try s.setBackupOptIn(true)
        let records = approvals(2)
        try s.save(records)
        try s.setBackupOptIn(false)
        XCTAssertFalse(s.isBackupOptedIn)
        XCTAssertFalse(exists(s.backupOptInFile))
        XCTAssertEqual(marker.marks, 1, "re-marked excluded")
        XCTAssertEqual(s.load(), records, "a verified mark keeps the choices")
        XCTAssertFalse(relaunched(s, marker).isBackupOptedIn)
    }

    func testTurningItOffWithAFailedMarkRemovesTheSavedChoices() throws {
        let marker = Marker()
        let s = store(marker)
        try s.setBackupOptIn(true)
        try s.save(approvals(2))
        marker.readBack = false
        XCTAssertThrowsError(try s.setBackupOptIn(false)) {
            XCTAssertEqual($0 as? SharedReviewError, .reviewChoicesResetUnverified)
        }
        XCTAssertFalse(s.isBackupOptedIn)
        XCTAssertFalse(exists(s.file), "removed, since the folder may still be backed up")
        XCTAssertTrue(s.load().isEmpty)
        XCTAssertTrue(relaunched(s, marker).load().isEmpty, "no approval comes back after a relaunch")
        XCTAssertThrowsError(try s.save(approvals(1)), "off again: the mark is required")
    }

    func testAnOptOutThatCanNotTouchTheFileHoldsForThisProcess() throws {
        let marker = Marker(), lines = Lines()
        var s = store(marker, lines: lines)
        try s.setBackupOptIn(true)
        s.optInOps.remove = { _ in throw Boom() }
        s.optInOps.write = { _, _ in throw Boom() }
        try s.setBackupOptIn(false)
        XCTAssertTrue(exists(s.backupOptInFile), "the disk refused")
        XCTAssertFalse(s.isBackupOptedIn, "but it is off in this process")
        XCTAssertEqual(lines.all, [SharedReviewStore.backupOptOutNotPersistedMessage])
        marker.readBack = false
        XCTAssertThrowsError(try s.save(approvals(1))) {
            XCTAssertEqual($0 as? SharedReviewError, .backupExclusionUnverified)
        }
    }

    func testAnOptOutThatCanNotRemoveTheFileOverwritesItWithOff() throws {
        let marker = Marker()
        var s = store(marker)
        try s.setBackupOptIn(true)
        s.optInOps.remove = { _ in throw Boom() }
        try s.setBackupOptIn(false)
        XCTAssertEqual(try Data(contentsOf: s.backupOptInFile), Data("off".utf8))
        XCTAssertFalse(relaunched(s, marker).isBackupOptedIn, "off after a relaunch too")
    }

    // MARK: #593 revocation: only a save that completes ends it

    /// Saved approvals, then a revoke whose remove and overwrite both fail, so the old file stays
    /// on disk behind the `.revoked` marker.
    private func revokedStore(_ marker: Marker) throws -> SharedReviewStore {
        var s = store(marker)
        try s.save(approvals(2))
        s.fileOps.remove = { _ in throw Boom() }
        s.fileOps.overwriteEmpty = { _ in throw Boom() }
        s.removeSavedChoices()
        XCTAssertTrue(exists(s.revokedMarker))
        XCTAssertTrue(s.load().isEmpty)
        s.fileOps = .live
        return s
    }

    func testAnUnverifiedOptInAfterARevokeStaysRevoked() throws {
        let marker = Marker()
        var s = try revokedStore(marker)
        s.optInOps.read = { _ in throw Boom() }
        XCTAssertThrowsError(try s.setBackupOptIn(true))
        marker.readBack = false
        XCTAssertThrowsError(try s.save(approvals(1))) {
            XCTAssertEqual($0 as? SharedReviewError, .backupExclusionUnverified)
        }
        XCTAssertTrue(exists(s.revokedMarker), "still revoked")
        XCTAssertTrue(s.load().isEmpty)
        XCTAssertTrue(relaunched(s, marker).load().isEmpty, "the old approvals never load")
    }

    func testAVerifiedOptInAloneDoesNotEndARevocation() throws {
        let marker = Marker()
        let s = try revokedStore(marker)
        try s.setBackupOptIn(true)
        XCTAssertTrue(s.isBackupOptedIn)
        XCTAssertTrue(exists(s.revokedMarker))
        XCTAssertTrue(s.load().isEmpty)
        XCTAssertTrue(relaunched(s, marker).load().isEmpty)
    }

    func testAnOptedInSaveThatFailsAfterARevokeStaysRevoked() throws {
        let marker = Marker()
        let s = try revokedStore(marker)
        try s.setBackupOptIn(true)
        let folder = s.file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard (try? Data("probe".utf8).write(to: folder.appendingPathComponent("probe"))) == nil else {
            throw XCTSkip("running with permissions that ignore a read-only folder")
        }
        XCTAssertThrowsError(try s.save(approvals(1)), "the write fails")
        XCTAssertTrue(exists(s.revokedMarker), "still revoked")
        XCTAssertTrue(s.load().isEmpty)
        XCTAssertTrue(relaunched(s, marker).load().isEmpty)
    }

    func testAnOptedInSaveThatCompletesEndsTheRevocationWithOnlyTheNewChoices() throws {
        let marker = Marker()
        let s = try revokedStore(marker)
        try s.setBackupOptIn(true)
        marker.readBack = false
        let fresh = [UUID(): SharedReviewRecord(decision: .excluded)]
        try s.save(fresh)
        XCTAssertFalse(exists(s.revokedMarker))
        XCTAssertEqual(s.load(), fresh, "the old approvals are replaced, never brought back")
        XCTAssertEqual(relaunched(s, marker).load(), fresh)
    }

    // MARK: Review level

    private func review(items: Int, marker: Marker) throws -> (SharedInboxReview, URL, [UUID]) {
        let root = root()
        let inbox = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let now = Date()
        var ids: [UUID] = []
        for n in 0..<items {
            let item = try XCTUnwrap(SharedInboxItem(kind: .text, content: "Shared note \(n).", now: now.addingTimeInterval(Double(n))))
            try JSONEncoder().encode(item).write(to: inbox.appendingPathComponent("\(item.id.uuidString).json"))
            ids.append(item.id)
        }
        let file = root.appendingPathComponent("Review/state.json")
        var s = SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { _ in })
        s.optInOps.markIncluded = { _ in }
        let review = SharedInboxReview(reader: SharedInboxReader(directory: inbox), store: s, now: { now.addingTimeInterval(60) })
        return (review, file, ids)
    }

    func testWithTheOptInOnAnApprovalSavesEvenWhenTheFolderIsNotExcluded() async throws {
        let marker = Marker(); marker.readBack = false
        let (review, file, ids) = try review(items: 1, marker: marker)
        _ = try await review.refresh()
        do { try await review.setDecision(.approved, for: ids[0]); XCTFail("off by default: must throw") }
        catch { XCTAssertEqual(error as? SharedReviewError, .backupExclusionUnverified) }
        try await review.setBackupOptIn(true)
        let on = await review.isBackupOptedIn
        XCTAssertTrue(on)
        try await review.setDecision(.approved, for: ids[0])
        XCTAssertEqual(SharedReviewStore(file: file, backupExclusion: marker).load()[ids[0]]?.decision, .approved)
    }

    func testTurningItOffWithAFailedMarkResetsTheReviewToPending() async throws {
        let marker = Marker()
        let (review, file, ids) = try review(items: 2, marker: marker)
        _ = try await review.refresh()
        try await review.setBackupOptIn(true)
        try await review.setDecision(.approved, for: ids[0])
        try await review.reconfirm(ids[0])
        try await review.setDecision(.approved, for: ids[1])
        marker.readBack = false
        do { try await review.setBackupOptIn(false); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? SharedReviewError, .reviewChoicesResetUnverified) }
        let entries = await review.entries
        XCTAssertEqual(entries.map(\.decision), [.pending, .pending])
        XCTAssertEqual(entries.map(\.isReconfirmed), [false, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let off = await review.isBackupOptedIn
        XCTAssertFalse(off)
    }
}
