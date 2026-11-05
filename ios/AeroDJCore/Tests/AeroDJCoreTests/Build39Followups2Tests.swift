import XCTest
@testable import AeroDJCore

// Build 39 follow-ups 2 (-Nova): Sentinel's #409 nit and Fry's #402 nit.
// (Fry's #409 nits 1 and 2 are in PersonalUpdateAiredAccountingTests, next to the session rig.)
final class Build39Followups2Tests: XCTestCase {
    // MARK: Sentinel's #409 nit: CloudVoiceConsentCache reflects nothing

    func testTheConsentCacheMirrorAndDumpShowNoBaseCache() async {
        let base = InMemoryAudioCache()
        await base.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "cloud", voiceID: "secret-voice"), for: "secret-key")
        let wrapped = CloudVoiceConsentCache(base: base, localProviders: ["device"], isGranted: { true })
        let mirror = Mirror(reflecting: wrapped)
        XCTAssertTrue(mirror.children.isEmpty, "no child, so no path to the base cache")
        XCTAssertNil(mirror.descendant("base"))
        XCTAssertNil(mirror.superclassMirror)
        var text = ""
        dump(wrapped, to: &text)
        XCTAssertFalse(text.contains("InMemoryAudioCache"), text)
        XCTAssertFalse(text.contains("base"), text)
        XCTAssertFalse(text.contains("secret"), text)
        XCTAssertFalse(String(reflecting: wrapped).contains("InMemoryAudioCache"))
        // Nested: the inner wrapper is not reachable either.
        let outer = CloudVoiceConsentCache(base: wrapped, localProviders: ["device"], isGranted: { true })
        XCTAssertTrue(Mirror(reflecting: outer).children.isEmpty)
    }

    // MARK: Fry's #402 nit: a save never overwrites an unreadable review store

    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b39f2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("review-state.json")
    }

    func testASaveOverAnUnreadableStoreKeepsTheOldFileAsideAndInventsNoApproval() throws {
        let file = try tempFile()
        let store = SharedReviewStore(file: file)
        let approved = UUID()
        try store.save([approved: SharedReviewRecord(decision: .approved)])
        var bytes = try Data(contentsOf: file)
        bytes.removeLast(3)                                   // truncated: unreadable
        try bytes.write(to: file)
        XCTAssertTrue(store.load().isEmpty, "unreadable still loads as empty (pending)")

        let other = UUID()
        try store.save([other: SharedReviewRecord(decision: .excluded)])
        XCTAssertEqual(try Data(contentsOf: store.unreadableBackupPrefix), bytes, "the unreadable bytes are kept, not overwritten")
        XCTAssertEqual(store.load(), [other: SharedReviewRecord(decision: .excluded)], "no approval read back from the backup")
        XCTAssertNil(store.load()[approved])
    }

    /// #414 n1 (-Nova): copies are capped at one, the newest. (Was: the first copy kept, more added.)
    func testASecondUnreadableStoreReplacesTheFirstBackupSoOnlyOneIsKept() throws {
        let file = try tempFile()
        let store = SharedReviewStore(file: file)
        try Data("first".utf8).write(to: file)
        try store.save([:])
        try Data("second".utf8).write(to: file)
        try store.save([:])
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(Set(names), ["review-state.json", "review-state.json.unreadable"])
        XCTAssertEqual(try String(contentsOf: store.unreadableBackupPrefix, encoding: .utf8), "second")
    }

    func testAReadableOrMissingStoreIsSavedInPlaceWithNoBackup() throws {
        let file = try tempFile()
        let store = SharedReviewStore(file: file)
        try store.save([UUID(): SharedReviewRecord(decision: .approved)])
        try store.save([:])
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["review-state.json"])
    }

    /// A store set aside while it could not be read (say, a read failure that later clears) may
    /// hold valid approvals; they are kept on disk but never loaded back as approvals.
    func testAStoreSetAsideIsNeverLoadedBack() throws {
        let file = try tempFile()
        let store = SharedReviewStore(file: file)
        try store.save([UUID(): SharedReviewRecord(decision: .approved)])
        try FileManager.default.moveItem(at: file, to: store.unreadableBackupPrefix)
        XCTAssertTrue(store.load().isEmpty)
        try store.save([:])
        XCTAssertTrue(store.load().isEmpty)
    }
}
