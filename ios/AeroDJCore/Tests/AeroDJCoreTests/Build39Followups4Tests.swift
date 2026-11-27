import XCTest
@testable import AeroDJCore

/// #424 follow-ups (-Nova).
final class Build39Followups4Tests: XCTestCase {
    private struct MoveFailed: Error {}

    /// n1: if setting the unreadable store aside fails, the previous `.unreadable` copy is kept.
    /// Old copies must only be removed after the new set-aside succeeds.
    func testFailedSetAsideKeepsPreviousUnreadableCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b39f4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        var store = SharedReviewStore(file: file)
        store.setAsideMove = { _, _ in throw MoveFailed() }
        try Data("previous".utf8).write(to: store.unreadableBackupPrefix)
        try Data("{not json".utf8).write(to: file)

        XCTAssertThrowsError(try store.save([UUID(): SharedReviewRecord()]))
        XCTAssertEqual(try String(contentsOf: store.unreadableBackupPrefix, encoding: .utf8), "previous")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{not json", "store not overwritten")
        XCTAssertEqual(store.unreadableCopies().count, 1)
    }
}
