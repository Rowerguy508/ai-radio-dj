import Foundation
import XCTest
@testable import AeroDJCore

/// #82 F2 / #649 follow-up (-Atlas): `FileAudioCache.purgeExpired()` itself deletes future-stamped
/// and expired clips, unreadable groups and the in-memory fallback's stale clips. The existing
/// rollback tests always read a clip after the sweep, and a read deletes it too, so a sweep that
/// leaves them behind went unnoticed. These assert on the disk (or the fallback) right after a
/// sweep, with no read in between.
final class FileCacheSweepRollbackTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600
    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        dirs = []
        super.tearDown()
    }

    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-rollback-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    private func clip() -> CachedAudio {
        CachedAudio(data: Data([7]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [UUID()])
    }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// A future-stamped clip is gone from disk after one sweep, with no read.
    func testSweepAloneDeletesFutureStampedFile() async {
        let clock = Clock(t0.addingTimeInterval(30 * day))
        let dir = makeDir()
        let cache = FileAudioCache(directory: dir, now: { clock.now })
        await cache.store(clip(), for: "skewed")
        XCTAssertEqual(names(dir), ["skewed.json"], "precondition: stored on disk")
        clock.set(t0)                                              // clock corrected 30 days back
        await cache.purgeExpired()
        XCTAssertEqual(names(dir), [], "the sweep deletes the future-stamped clip; it must not wait for a read")
    }

    /// Unreadable groups (corrupt metadata, orphaned audio) are removed by the sweep itself.
    func testSweepDeletesUnreadableGroups() async throws {
        let clock = Clock(t0)
        let dir = makeDir()
        let cache = FileAudioCache(directory: dir, now: { clock.now })
        try Data("not json".utf8).write(to: dir.appendingPathComponent("corrupt.json"))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("orphan.caf"))
        await cache.store(clip(), for: "fresh")
        await cache.purgeExpired()
        XCTAssertEqual(names(dir), ["fresh.json"], "only the readable, in-date clip survives the sweep")
    }

    /// Every expired clip goes in one sweep, however the groups are ordered (a kept group must not
    /// stop the sweep). 10 fresh + 10 expired: if a kept group ended the loop, the chance that all
    /// ten expired groups still happened to come first is about 5e-6.
    func testSweepDeletesEveryExpiredClipAmongFreshOnes() async {
        let clock = Clock(t0)
        let dir = makeDir()
        let cache = FileAudioCache(directory: dir, now: { clock.now })
        clock.set(t0)
        for i in 0..<10 { await cache.store(clip(), for: "expired\(i)") }
        clock.set(t0.addingTimeInterval(6 * day))
        for i in 0..<10 { await cache.store(clip(), for: "fresh\(i)") }
        clock.set(t0.addingTimeInterval(8 * day))                  // expired: 8 days old; fresh: 2 days old
        await cache.purgeExpired()
        XCTAssertEqual(names(dir), (0..<10).map { "fresh\($0).json" }.sorted())
    }

    /// The in-memory fallback (used while the disk is unavailable) is swept with the file cache,
    /// future-stamped clips included.
    func testSweepAlsoSweepsTheMemoryFallback() async {
        let clock = Clock(t0.addingTimeInterval(30 * day))
        let cache = FileAudioCache(directory: makeDir(), now: { clock.now })
        await cache.memoryFallback.store(clip(), for: "held")
        var held = await cache.memoryFallback.count
        XCTAssertEqual(held, 1, "precondition")
        clock.set(t0)                                              // clock corrected: the clip is future-stamped
        await cache.purgeExpired()
        held = await cache.memoryFallback.count
        XCTAssertEqual(held, 0)
    }
}
