import Foundation
import XCTest
@testable import AeroDJCore

/// #82 F2 (-Fry): a clock rollback never extends narration-cache retention. A clip stamped later
/// than `now` is deleted (read and sweep), never re-stamped, in both caches.
final class CacheClockRollbackTests: XCTestCase {
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

    private func caches(_ clock: Clock) -> [any AudioCache] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-\(UUID().uuidString)")
        dirs.append(dir)
        return [FileAudioCache(directory: dir, now: { clock.now }), InMemoryAudioCache(now: { clock.now })]
    }

    private func clip() -> CachedAudio {
        CachedAudio(data: Data([7]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [UUID()])
    }

    private func files(_ cache: any AudioCache) -> [String] {
        guard let file = cache as? FileAudioCache else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: file.directory.path)) ?? []
    }

    /// Stored at T, clock set to T-1d, sweep, clock to T+8d: gone.
    func testRollbackThenSweepThenForwardLeavesNothing() async {
        let clock = Clock(t0)
        for cache in caches(clock) {
            clock.set(t0)
            await cache.store(clip(), for: "k")
            clock.set(t0.addingTimeInterval(-day))
            await cache.purgeExpired()
            clock.set(t0.addingTimeInterval(8 * day))
            await cache.purgeExpired()
            let left = await cache.audio(for: "k")
            XCTAssertNil(left, "\(type(of: cache))")
            XCTAssertEqual(files(cache), [], "\(type(of: cache)): no file left")
        }
    }

    /// Three -1d rollbacks, with reads and sweeps between, never keep a clip past 7 days of real
    /// elapsed age (the injected clock's forward time since the store).
    func testRepeatedRollbackNeverExtendsRetention() async {
        let clock = Clock(t0)
        for cache in caches(clock) {
            clock.set(t0)
            await cache.store(clip(), for: "k")
            var real = t0
            for _ in 0..<3 {
                real = real.addingTimeInterval(2 * day)                 // real time moves on
                clock.set(real.addingTimeInterval(-day - 2 * day))      // device clock set back
                _ = await cache.audio(for: "k")
                await cache.purgeExpired()
                clock.set(real)                                         // corrected
                _ = await cache.audio(for: "k")
                await cache.purgeExpired()
            }
            clock.set(t0.addingTimeInterval(7 * day + 1))
            await cache.purgeExpired()
            let left = await cache.audio(for: "k")
            XCTAssertNil(left, "\(type(of: cache)): gone by 7 days of real age")
            XCTAssertEqual(files(cache), [], "\(type(of: cache)): no file left")
        }
    }

    /// A read of a future-stamped entry returns no audio and removes it.
    func testReadOfFutureStampedClipReturnsNilAndRemovesIt() async {
        let clock = Clock(t0)
        for cache in caches(clock) {
            clock.set(t0.addingTimeInterval(3 * day))                  // clock ahead at store
            await cache.store(clip(), for: "k")
            clock.set(t0)
            let read = await cache.audio(for: "k")
            XCTAssertNil(read, "\(type(of: cache)): future-stamped audio is not served")
            clock.set(t0.addingTimeInterval(3 * day))                  // back to the store time
            let again = await cache.audio(for: "k")
            XCTAssertNil(again, "\(type(of: cache)): deleted on the read, not hidden")
            XCTAssertEqual(files(cache), [], "\(type(of: cache)): no file left")
        }
    }

    /// Control: an ordinary clip within 7 days is still served at the edge.
    func testClipWithinRetentionIsStillServed() async {
        let clock = Clock(t0)
        for cache in caches(clock) {
            clock.set(t0)
            await cache.store(clip(), for: "k")
            clock.set(t0.addingTimeInterval(7 * day))
            await cache.purgeExpired()
            let read = await cache.audio(for: "k")
            XCTAssertNotNil(read, "\(type(of: cache))")
        }
    }
}
