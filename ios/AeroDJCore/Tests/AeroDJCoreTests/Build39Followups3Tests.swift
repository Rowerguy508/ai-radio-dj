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

    func testAFailedMarkLogsWithoutContentAndKeepsTheDecision() throws {
        for mode in 0..<3 {
            let file = try tempFile()
            let marker = Marker()
            switch mode { case 0: marker.throwOnMark = true; case 1: marker.throwOnRead = true; default: marker.readBack = false }
            let lines = Lines()
            let store = SharedReviewStore(file: file, backupExclusion: marker, backupExclusionLog: { lines.add($0) })
            let id = UUID()
            try store.save([id: SharedReviewRecord(decision: .approved)])
            XCTAssertEqual(store.load()[id]?.decision, .approved, "mode \(mode): decision kept")
            XCTAssertEqual(lines.all, [SharedReviewStore.backupExclusionFailureMessage], "mode \(mode)")
            XCTAssertFalse(lines.all.contains { $0.contains(file.path) })
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
