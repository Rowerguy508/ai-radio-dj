import XCTest
@testable import AeroDJCore

/// #414 review follow-ups (-Nova).
final class Build39Followups3Tests: XCTestCase {
    private final class Marker: BackupExclusionMarking, @unchecked Sendable {
        let lock = NSLock()
        var marked: [URL] = []
        var throwOnMark = false
        var readBack: Bool? = nil
        var throwOnRead = false
        struct Boom: Error {}
        func markExcluded(_ directory: URL) throws {
            if throwOnMark { throw Boom() }
            lock.withLock { marked.append(directory) }
        }
        func isExcluded(_ directory: URL) throws -> Bool? {
            if throwOnRead { throw Boom() }
            return readBack
        }
    }
    private final class Lines: @unchecked Sendable {
        let lock = NSLock(); var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
    }

    private func tempFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b39f3-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("Review/state.json")
    }

    // MARK: 1. Single-clip boundary break: cue id mismatch fails closed

    func testASingleClipWithItsOwnIDReportsThatID() {
        let id = UUID()
        let r = TalkoverLineReporting(cueIDs: [id], clipCount: 1)
        XCTAssertTrue(r.reportsLines)
        XCTAssertEqual(r.finishedCueID(atClip: 0), id)
    }

    func testASingleClipWithAMismatchedIDListReportsLinesButNoID() {
        for ids in [[], [UUID(), UUID()]] {
            let r = TalkoverLineReporting(cueIDs: ids, clipCount: 1)
            XCTAssertTrue(r.reportsLines, "a mismatch must still report lines, so .finished counts nothing")
            XCTAssertEqual(r.cueIDs, [])
            XCTAssertNil(r.finishedCueID(atClip: 0))
        }
    }

    // MARK: 2. Unreadable copies are capped at one

    func testOlderCopiesIncludingLegacyUUIDNamesAreRemovedWhenANewOneIsSetAside() throws {
        let file = try tempFile()
        let store = SharedReviewStore(file: file, backupExclusion: Marker())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: store.unreadableBackupPrefix)
        for _ in 0..<3 { try Data("legacy".utf8).write(to: file.appendingPathExtension("unreadable-\(UUID().uuidString)")) }
        try Data("unrelated".utf8).write(to: file.deletingLastPathComponent().appendingPathComponent("other.json"))
        try Data("newest".utf8).write(to: file)
        try store.save([:])
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(Set(names), ["state.json", "state.json.unreadable", "other.json"])
        XCTAssertEqual(try String(contentsOf: store.unreadableBackupPrefix, encoding: .utf8), "newest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("other.json").path))
    }

    func testManyCorruptionsLeaveOneCopyAndItIsNeverLoaded() throws {
        let file = try tempFile()
        let store = SharedReviewStore(file: file, backupExclusion: Marker())
        let approved = UUID()
        for _ in 0..<5 {
            try store.save([approved: SharedReviewRecord(decision: .approved)])
            var b = try Data(contentsOf: file); b.removeLast(2); try b.write(to: file)
            XCTAssertTrue(store.load().isEmpty)
            try store.save([:])
            XCTAssertEqual(store.unreadableCopies().count, 1)
            XCTAssertTrue(store.load().isEmpty, "the set-aside approval is never read back")
        }
    }

    func testASaveOfAReadableStoreLeavesAnExistingCopyAlone() throws {
        let file = try tempFile()
        let store = SharedReviewStore(file: file, backupExclusion: Marker())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: store.unreadableBackupPrefix)
        try store.save([UUID(): SharedReviewRecord(decision: .excluded)])
        try store.save([:])
        XCTAssertEqual(try String(contentsOf: store.unreadableBackupPrefix, encoding: .utf8), "kept")
    }

    func testDeleteMyDJDataStillDoesNotClaimReviewDecisionsOrCopies() {
        XCTAssertTrue(PersonalDataReset.message.contains("doesn't delete the shared items themselves, your review choices"))
    }

    // MARK: 3. Review/ is excluded from backup

    func testEverySaveMarksTheReviewFolderExcluded() throws {
        let file = try tempFile()
        let marker = Marker()
        let lines = Lines()
        let store = SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { lines.add($0) })
        try store.save([:])
        try store.save([:])
        XCTAssertEqual(marker.marked.map(\.standardizedFileURL), Array(repeating: file.deletingLastPathComponent().standardizedFileURL, count: 2))
        XCTAssertEqual(lines.all, [])
    }

    /// #426 (-Sentinel): a failed or unset mark blocks the write (fail closed, like #416).
    func testAFailedMarkWritesNothingAndLogsWithoutContent() throws {
        for mode in 0..<3 {
            let file = try tempFile()
            let marker = Marker()
            switch mode { case 0: marker.throwOnMark = true; case 1: marker.throwOnRead = true; default: marker.readBack = false }
            let lines = Lines()
            let store = SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { lines.add($0) })
            let id = UUID()
            XCTAssertThrowsError(try store.save([id: SharedReviewRecord(decision: .approved)])) {
                XCTAssertEqual($0 as? SharedReviewError, .backupExclusionUnverified, "mode \(mode)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "mode \(mode): nothing written")
            XCTAssertTrue(store.load().isEmpty, "mode \(mode)")
            XCTAssertEqual(lines.all, [SharedReviewStore.backupExclusionFailureMessage], "mode \(mode)")
            XCTAssertFalse(lines.all.contains { $0.contains(file.path) || $0.contains(id.uuidString) || $0.contains("Boom") })
        }
    }

    func testAFailedMarkLeavesTheExistingFileAndAnUnreadableFileInPlace() throws {
        let file = try tempFile()
        let marker = Marker()
        let store = SharedReviewStore(file: file, backupExclusion: marker)
        let kept = UUID()
        try store.save([kept: SharedReviewRecord(decision: .excluded)])
        let before = try Data(contentsOf: file)
        marker.readBack = false
        XCTAssertThrowsError(try store.save([UUID(): SharedReviewRecord(decision: .approved)]))
        XCTAssertEqual(try Data(contentsOf: file), before, "the earlier save is untouched")
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try store.save([:]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "corrupt", "not set aside while unverified")
        XCTAssertTrue(store.unreadableCopies().isEmpty)
    }

    private func reviewFixture(items: Int) throws -> (SharedInboxReview, Marker, URL, [UUID]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b39f3-426-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let now = Date()
        var ids: [UUID] = []
        for n in 0..<items {
            let item = try XCTUnwrap(SharedInboxItem(kind: .text, content: "Shared note \(n).", now: now.addingTimeInterval(Double(n))))
            try JSONEncoder().encode(item).write(to: inbox.appendingPathComponent("\(item.id.uuidString).json"))
            ids.append(item.id)
        }
        let marker = Marker(); marker.readBack = true
        let file = root.appendingPathComponent("Review/state.json")
        let review = SharedInboxReview(reader: SharedInboxReader(directory: inbox),
                                       store: SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { _ in }),
                                       now: { now.addingTimeInterval(60) })
        return (review, marker, file, ids)
    }

    func testTheReviewKeepsItsStateWhenTheMarkFailsAndSavesOnceItWorks() async throws {
        let (review, marker, file, ids) = try reviewFixture(items: 1)
        marker.readBack = false
        _ = try await review.refresh()
        do { try await review.setDecision(.approved, for: ids[0]); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? SharedReviewError, .backupExclusionUnverified) }
        let pending = await review.entries.first?.decision
        XCTAssertEqual(pending, .pending, "not applied, so not spoken")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        marker.readBack = true
        try await review.setDecision(.approved, for: ids[0])
        XCTAssertEqual(SharedReviewStore(file: file, backupExclusion: marker).load()[ids[0]]?.decision, .approved)
    }

    /// Echo's #591 blocker: exclude, delete and edit go ahead under a failing mark, say so, and leave
    /// nothing on disk that a relaunch could read back as an approval or a reconfirm.
    func testExposureReducingChangesGoAheadAndResetSavedChoicesWhenTheMarkFails() async throws {
        for change in ["exclude", "delete", "redact"] {
            let (review, marker, file, ids) = try reviewFixture(items: 2)
            _ = try await review.refresh()
            for id in ids { try await review.setDecision(.approved, for: id) }
            try await review.reconfirm(ids[1])
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            marker.readBack = false
            do {
                switch change {
                case "exclude": try await review.setDecision(.excluded, for: ids[0])
                case "delete": try await review.delete(ids[0])
                default: try await review.redact(ids[0], to: "Edited.")
                }
                XCTFail("\(change): must throw")
            } catch {
                XCTAssertEqual(error as? SharedReviewError, .reviewChoicesResetUnverified, change)
            }
            let entries = await review.entries
            XCTAssertEqual(entries.map(\.decision), Array(repeating: .pending, count: entries.count), change)
            XCTAssertTrue(entries.allSatisfy { !$0.isReconfirmed }, change)
            let reconfirmed = await review.reconfirmedItemIDs
            XCTAssertTrue(reconfirmed.isEmpty, change)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(change): saved choices removed, nothing written")
            switch change {
            case "delete":
                XCTAssertFalse(entries.contains { $0.id == ids[0] }, "the delete went ahead")
                do { try await review.delete(ids[0]); XCTFail() } catch SharedReviewError.unknownItem {}
            case "redact":
                XCTAssertEqual(entries.first { $0.id == ids[0] }?.displayText, "Edited.", "the edit went ahead")
            default:
                break
            }
            // A relaunch in that window loads every item as pending, not reconfirmed.
            let relaunched = try await { () async throws -> [SharedReviewEntry] in
                let fresh = SharedInboxReview(reader: SharedInboxReader(directory: file.deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("Inbox")),
                    store: SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { _ in }))
                _ = try await fresh.refresh()
                return await fresh.entries
            }()
            XCTAssertTrue(relaunched.allSatisfy { $0.decision == .pending && !$0.isReconfirmed }, change)
        }
    }

    func testAReadBackOfTrueOrNilCountsAsExcluded() throws {
        for value in [true, nil] as [Bool?] {
            let marker = Marker(); marker.readBack = value
            let store = SharedReviewStore(file: try tempFile(), backupExclusion: marker)
            try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(store.markFolderExcludedFromBackup())
        }
    }
}
