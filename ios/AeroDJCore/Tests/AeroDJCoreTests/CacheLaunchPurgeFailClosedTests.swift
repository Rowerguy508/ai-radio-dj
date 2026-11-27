import XCTest
@testable import AeroDJCore

/// Injected filesystem failures for `FileAudioCache` (#637 P1).
private final class FlakyFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var failRemoving: Set<String> = []
    private var failWrites = false
    private var partialWrites = false

    func failRemoval(of names: Set<String>) { lock.withLock { failRemoving = names } }
    func failWrite(_ on: Bool, leavingPartialFile partial: Bool = false) {
        lock.withLock { failWrites = on; partialWrites = partial }
    }

    var ops: CacheFileOps {
        CacheFileOps(
            write: { data, url in
                let (fail, partial) = self.lock.withLock { (self.failWrites, self.partialWrites) }
                guard fail else { return try ProtectedFile.write(data, to: url) }
                if partial { try Data(data.prefix(3)).write(to: url) }          // torn, non-atomic
                throw CocoaError(.fileWriteOutOfSpace)
            },
            remove: { url in
                if self.lock.withLock({ self.failRemoving.contains(url.lastPathComponent) }) {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            })
    }
}

/// #637 P1 (-Sentinel): the launch gate must fail closed on filesystem errors. A personal clip
/// the launch purge could not delete stays withheld and the gate stays shut until a retry removes
/// it; a clip whose write failed is never marked fresh, so old bytes are not served as this launch's.
final class CacheLaunchPurgeFailClosedTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-failclosed-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func clip(_ byte: UInt8, sources: [UUID]) -> CachedAudio {
        CachedAudio(data: Data([byte]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: sources)
    }

    private func filesOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func seedPreviousLaunch() async {
        let earlier = FileAudioCache(directory: dir)
        await earlier.store(clip(1, sources: [UUID()]), for: "personal")
        await earlier.store(clip(3, sources: []), for: "generic")
    }

    /// The production start path, waiting for the launch sweep (purge, then expiry sweep).
    private func launch(_ cache: FileAudioCache) async {
        let (launched, c) = AsyncStream<String?>.makeStream()
        let task = AudioCacheSweeper(cache: cache).start(every: .seconds(3600), purgingPersonalFirst: true,
                                                         onLaunchSweep: { c.yield($0) })
        var it = launched.makeAsyncIterator()
        _ = await it.next()
        task.cancel(); c.finish()
    }

    func testAFailedRemovalKeepsTheGateShutAndTheClipWithheld() async throws {
        await seedPreviousLaunch()
        let files = FlakyFiles()
        files.failRemoval(of: ["personal.json"])
        let cache = FileAudioCache(directory: dir, fileOps: files.ops)
        await launch(cache)

        XCTAssertTrue(filesOnDisk().contains("personal.json"), "the injected failure really left the clip")
        XCTAssertTrue(cache.launchGate.isPending, "the gate must not open while a removal failed")
        XCTAssertTrue(cache.launchGate.needsRetry)
        let survivor = await cache.audio(for: "personal")
        XCTAssertTrue(survivor == nil, "an earlier launch's personal clip that survived the purge is never served")
        let generic = await cache.audio(for: "generic")
        XCTAssertEqual(generic?.data, Data([3]), "non-personal clips are still served")

        // A clip rendered in this launch is still served while the gate stays shut.
        await cache.store(clip(7, sources: [UUID()]), for: "new")
        let fresh = await cache.audio(for: "new")
        XCTAssertEqual(fresh?.data, Data([7]))
    }

    func testARetryAfterTheRemovalSucceedsFinishesTheGate() async throws {
        await seedPreviousLaunch()
        let files = FlakyFiles()
        files.failRemoval(of: ["personal.json"])
        let cache = FileAudioCache(directory: dir, fileOps: files.ops)
        await launch(cache)
        await cache.purgeExpired()                              // still failing: still shut
        XCTAssertTrue(cache.launchGate.isPending)
        XCTAssertTrue(filesOnDisk().contains("personal.json"))

        files.failRemoval(of: [])
        await cache.purgeExpired()                              // the hourly sweep retries
        XCTAssertFalse(cache.launchGate.isPending, "a retry whose removals all succeed opens the gate")
        XCTAssertFalse(cache.launchGate.needsRetry)
        XCTAssertFalse(filesOnDisk().contains("personal.json"))
        let gone = await cache.audio(for: "personal")
        XCTAssertTrue(gone == nil)
        await cache.store(clip(5, sources: [UUID()]), for: "later")
        let later = await cache.audio(for: "later")
        XCTAssertEqual(later?.data, Data([5]), "after the gate opens, personal clips read back normally")
    }

    /// `prepareForLaunch` called directly (no gate begun): a failed removal starts withholding.
    func testAnUngatedLaunchPurgeThatFailsStartsWithholding() async throws {
        await seedPreviousLaunch()
        let files = FlakyFiles()
        files.failRemoval(of: ["personal.json"])
        let cache = FileAudioCache(directory: dir, fileOps: files.ops)
        await AudioCacheSweeper(cache: cache).prepareForLaunch(purgingPersonalFirst: true)
        XCTAssertTrue(filesOnDisk().contains("personal.json"))
        let survivor = await cache.audio(for: "personal")
        XCTAssertTrue(survivor == nil, "a clip the purge could not delete is withheld")
    }

    func testAFailedWriteIsNeitherMarkedFreshNorServed() async throws {
        await seedPreviousLaunch()
        let files = FlakyFiles()
        let cache = FileAudioCache(directory: dir, fileOps: files.ops)
        cache.beginLaunchPurge()                                // the window, purge not run yet
        files.failWrite(true)
        await cache.store(clip(8, sources: [UUID()]), for: "personal")   // overwrites the earlier key
        XCTAssertFalse(cache.launchGate.storedThisLaunch("personal"), "a failed write is not marked fresh")
        let old = await cache.audio(for: "personal")
        XCTAssertTrue(old == nil, "the earlier launch's bytes are not served as this launch's clip")
        XCTAssertFalse(filesOnDisk().contains("personal.json"), "what was at the key is cleaned up")

        await cache.store(clip(9, sources: [UUID()]), for: "new")
        let missing = await cache.audio(for: "new")
        XCTAssertTrue(missing == nil, "nothing recorded or held in memory for a failed write")
        XCTAssertFalse(cache.launchGate.storedThisLaunch("new"))

        files.failWrite(false)
        await cache.store(clip(6, sources: [UUID()]), for: "new")
        let ok = await cache.audio(for: "new")
        XCTAssertEqual(ok?.data, Data([6]), "a write that succeeds is marked and served")
    }

    /// A key stored earlier in this launch whose next write fails is no longer this launch's clip.
    func testAFailedRewriteOfAFreshKeyUnmarksIt() async throws {
        let files = FlakyFiles()
        let cache = FileAudioCache(directory: dir, fileOps: files.ops)
        cache.beginLaunchPurge()
        await cache.store(clip(1, sources: [UUID()]), for: "k")
        XCTAssertTrue(cache.launchGate.storedThisLaunch("k"))
        files.failWrite(true)
        await cache.store(clip(2, sources: [UUID()]), for: "k")
        XCTAssertFalse(cache.launchGate.storedThisLaunch("k"))
        let read = await cache.audio(for: "k")
        XCTAssertTrue(read == nil)
    }

    func testAFailedWriteLeavesNoPartialFile() async throws {
        let files = FlakyFiles()
        let cache = FileAudioCache(directory: dir, fileOps: files.ops)
        files.failWrite(true, leavingPartialFile: true)
        await cache.store(clip(4, sources: [UUID()]), for: "torn")
        XCTAssertFalse(filesOnDisk().contains("torn.json"), "a torn file is removed")
        let read = await cache.audio(for: "torn")
        XCTAssertTrue(read == nil)
    }

    /// #637 follow-up: production's launch cache is gated. `onDeviceDefault` (app target, not built
    /// on Linux) must hand the sweeper the `FileAudioCache` itself, which is `LaunchPurgeGated`.
    func testOnDeviceDefaultStartsTheLaunchPurgeOnAGatedCache() throws {
        XCTAssertTrue((FileAudioCache(directory: dir) as any AudioCache) is any LaunchPurgeGated)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("ios/AeroDJ/OnDeviceSpeechProvider.swift"),
                                encoding: .utf8)
        guard let start = source.range(of: "static func onDeviceDefault()") else {
            return XCTFail("onDeviceDefault() not found")
        }
        let body = String(source[start.upperBound...].prefix(1200))
        XCTAssertTrue(body.contains("let cache = FileAudioCache(directory:"), "the launch cache is a FileAudioCache")
        XCTAssertTrue(body.contains("AudioCacheSweeper(cache: cache).start(purgingPersonalFirst: true)"),
                      "and the sweeper starts the gated launch purge on that same cache")
        XCTAssertTrue(body.contains("cache: cache)"), "the renderer reads the same gated cache")
    }
}
