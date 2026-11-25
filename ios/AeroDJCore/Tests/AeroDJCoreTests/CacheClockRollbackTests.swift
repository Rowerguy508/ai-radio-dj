import XCTest
@testable import AeroDJCore

/// #82 F2: a clock set back after a clip was stored must not extend its 7-day retention.
/// A future-stamped clip used to be re-stamped to `now`, which restarted its 7 days on every
/// rollback. It is now treated as untrusted and deleted, on the sweep and on every read path
/// (in-memory and on disk). No sleeps: the clocks below are injected. -Atlas
final class CacheClockRollbackTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var now: Date { lock.withLock { value } }
        func set(_ date: Date) { lock.withLock { value = date } }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func personalClip() -> CachedAudio {
        CachedAudio(data: Data([7]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [UUID()])
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// Both shipping caches on one injected clock. The file cache keeps an audio sidecar beside
    /// the metadata, so a deletion has to take both.
    private func caches(_ clock: Clock, dir: URL) -> [(name: String, cache: any AudioCache)] {
        [("FileAudioCache", FileAudioCache(directory: dir, now: { clock.now })),
         ("InMemoryAudioCache", InMemoryAudioCache(now: { clock.now }))]
    }

    // Acceptance 1: clip created at T, clock moved to T-1d, sweep, clock moved to T+8d: gone.
    func testClipStoredAtTSweptAtTMinusOneDayIsGoneAtTPlusEightDays() async throws {
        let clock = Clock(t0)
        let dir = tempDir()
        for (name, cache) in caches(clock, dir: dir) {
            clock.set(t0)
            await cache.store(personalClip(), for: "k")
            clock.set(t0.addingTimeInterval(-day))
            await cache.purgeExpired()
            clock.set(t0.addingTimeInterval(8 * day))
            await cache.purgeExpired()
            let left = await cache.audio(for: "k")
            XCTAssertNil(left, "\(name): gone after 8 days")
        }
        XCTAssertEqual(files(dir), [], "no file left on disk")
    }

    // Acceptance 2: repeated rollback (3 cycles of -1d) never keeps a clip past 7 days of real
    // elapsed age. `real` is the test's own time; the device clock is set back 1 day behind the
    // clip's stamp before each sweep, which used to re-stamp it and restart the 7 days.
    func testRepeatedRollbackNeverKeepsAClipPastSevenDaysOfRealAge() async throws {
        let clock = Clock(t0)
        let dir = tempDir()
        for (name, cache) in caches(clock, dir: dir) {
            clock.set(t0)
            await cache.store(personalClip(), for: "k")
            var real: TimeInterval = 0                         // real seconds since the store
            var stamp = t0                                     // what the device clock last read as "stored"
            for cycle in 1...3 {
                real += 3 * day
                stamp = stamp.addingTimeInterval(-day)         // clock set back to 1 day before the stamp
                clock.set(stamp)
                await cache.purgeExpired()
                let served = await cache.audio(for: "k")
                XCTAssertNil(served, "\(name): cycle \(cycle): a clip stamped in the future is never served")
            }
            XCTAssertGreaterThan(real, AudioCacheRetention.maximum)
            clock.set(t0.addingTimeInterval(real))             // clock corrected to real time
            await cache.purgeExpired()
            let after = await cache.audio(for: "k")
            XCTAssertNil(after, "\(name): \(real / day) real days old and still gone after the clock is corrected")
        }
        XCTAssertEqual(files(dir), [], "no file left on disk")
    }

    // Acceptance 3: an in-memory read of a future-stamped entry does not return audio, with no
    // sweep in between. Same for a disk read (which used to clamp and serve).
    func testReadOfAFutureStampedClipReturnsNoAudioWithoutASweep() async throws {
        let clock = Clock(t0)
        let dir = tempDir()
        for (name, cache) in caches(clock, dir: dir) {
            clock.set(t0)
            await cache.store(personalClip(), for: "k")
            clock.set(t0.addingTimeInterval(-day))
            let read = await cache.audio(for: "k")
            XCTAssertNil(read, "\(name): a clip stamped 1 day in the future is not served")
            clock.set(t0)                                      // clock back where it was
            let again = await cache.audio(for: "k")
            XCTAssertNil(again, "\(name): the read deleted it; it does not come back")
        }
        XCTAssertEqual(files(dir), [], "the disk read removed the clip's files")
    }

    /// The disk cache's memory fallback (disk closed after a failed backup-exclusion mark) holds
    /// clips for the session; it follows the same rule.
    func testFileCacheMemoryFallbackDropsAFutureStampedClipOnRead() async throws {
        let clock = Clock(t0)
        let dir = tempDir()
        let cache = FileAudioCache(directory: dir, now: { clock.now })
        cache.diskGate.close()
        await cache.store(personalClip(), for: "k")
        XCTAssertEqual(files(dir), [], "held in memory, nothing on disk")
        let held = await cache.audio(for: "k")
        XCTAssertNotNil(held, "served from the memory fallback")
        clock.set(t0.addingTimeInterval(-60))
        let read = await cache.audio(for: "k")
        XCTAssertNil(read, "memory fallback: future-stamped clip not served")
    }

    /// A file left by an earlier launch with a stamp ahead of the clock (written while the clock
    /// ran ahead, or the clock set back since): the launch sweep deletes its metadata and audio.
    func testLaunchSweepDeletesAFutureStampedFileAndItsAudio() async throws {
        let clock = Clock(t0.addingTimeInterval(30 * day))    // earlier launch, clock 30 days ahead
        let dir = tempDir()
        let earlier = FileAudioCache(directory: dir, now: { clock.now })
        await earlier.store(personalClip(), for: "k")
        try Data([1]).write(to: dir.appendingPathComponent("k.caf"))
        XCTAssertEqual(files(dir), ["k.caf", "k.json"])

        clock.set(t0)                                          // corrected
        let relaunched = FileAudioCache(directory: dir, now: { clock.now })
        await AudioCacheSweeper(cache: relaunched).prepareForLaunch(purgingPersonalFirst: false)
        XCTAssertEqual(files(dir), [], "metadata and audio both deleted")
    }

    /// Not over-eager: a clock that moves back but stays after the clip's stamp keeps the clip,
    /// and its age is still measured from the original stamp (never re-stamped).
    func testRollbackThatStaysAfterTheStampKeepsTheClipAndItsOriginalAge() async throws {
        let clock = Clock(t0)
        let dir = tempDir()
        for (name, cache) in caches(clock, dir: dir) {
            clock.set(t0)
            await cache.store(personalClip(), for: "k")
            clock.set(t0.addingTimeInterval(3 * day))
            await cache.purgeExpired()
            clock.set(t0.addingTimeInterval(2 * day))          // set back 1 day, still after the stamp
            await cache.purgeExpired()
            let kept = await cache.audio(for: "k")
            XCTAssertEqual(kept?.createdAt, t0, "\(name): kept, stamp unchanged")
            clock.set(t0.addingTimeInterval(AudioCacheRetention.maximum))
            let atLimit = await cache.audio(for: "k")
            XCTAssertNotNil(atLimit, "\(name): kept for exactly 7 days from the original stamp")
            clock.set(t0.addingTimeInterval(AudioCacheRetention.maximum + 1))
            let past = await cache.audio(for: "k")
            XCTAssertNil(past, "\(name): gone one second after 7 days from the original stamp")
        }
        XCTAssertEqual(files(dir), [])
    }

    func testRetentionRuleRejectsFutureAndExpiredStamps() {
        let max = AudioCacheRetention.maximum
        XCTAssertTrue(AudioCacheRetention.isRetained(createdAt: t0, now: t0, maxAge: max))
        XCTAssertTrue(AudioCacheRetention.isRetained(createdAt: t0, now: t0.addingTimeInterval(max), maxAge: max))
        XCTAssertFalse(AudioCacheRetention.isRetained(createdAt: t0, now: t0.addingTimeInterval(max + 1), maxAge: max))
        XCTAssertFalse(AudioCacheRetention.isRetained(createdAt: t0.addingTimeInterval(1), now: t0, maxAge: max))
        XCTAssertFalse(AudioCacheRetention.isRetained(createdAt: .distantFuture, now: t0, maxAge: max))
    }
}
