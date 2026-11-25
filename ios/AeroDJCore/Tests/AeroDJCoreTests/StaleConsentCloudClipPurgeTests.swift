import XCTest
@testable import AeroDJCore

// #397 follow-up (-Sentinel): cloud clips cached under a consent that no longer grants (a
// decline, or an acceptance of a superseded copy version, v2 or earlier while v3 is current)
// are deleted at launch and on the first read that withholds one, not left on disk until a
// decline or the 7-day expiry. On-device clips stay. In-process fakes only: no network.

final class StaleConsentCloudClipPurgeTests: XCTestCase {
    private let cloudClip = CachedAudio(data: Data("c".utf8), seconds: 1, providerID: "cloud", voiceID: "host")
    private let deviceClip = CachedAudio(data: Data("d".utf8), seconds: 1, providerID: "device", voiceID: "host")

    private func defaults() -> UserDefaults {
        let name = "stale-consent-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// A store whose persisted record is `record` (or the legacy two-key acceptance when nil).
    private func store(record: String?) -> CloudVoiceConsentStore {
        let d = defaults()
        if let record {
            d.set(record, forKey: CloudVoiceConsentStore.recordKey)
        } else {
            d.set("accepted", forKey: CloudVoiceConsentStore.stateKey)
            d.set(2, forKey: CloudVoiceConsentStore.versionKey)
        }
        return CloudVoiceConsentStore(defaults: d)
    }

    private func renderer(cache: any AudioCache) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: DJFakeVoice(), voice: djVoice, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
    }

    private func seeded() async -> InMemoryAudioCache {
        let cache = InMemoryAudioCache()
        await cache.store(cloudClip, for: "cloudKey")
        await cache.store(deviceClip, for: "deviceKey")
        return cache
    }

    func testCurrentVersionIsV3() {
        XCTAssertEqual(CloudVoiceConsentStore.currentVersion, 3, "update the stale records below with the copy version")
    }

    // MARK: Launch purge

    /// Every stored answer that does not grant now purges cloud clips at launch.
    func testLaunchPurgesCloudClipsForEveryNonGrantingRecord() async {
        let records: [String?] = ["1:accepted", "2:accepted", "3:declined", "2:declined", "3:undecided", "junk", nil]
        for record in records {
            let s = store(record: record)
            XCTAssertFalse(s.isGranted, "\(record ?? "legacy v2 acceptance") must not grant")
            let cache = await seeded()
            let purged = await renderer(cache: cache).purgeCloudClipsAtLaunch(isGranted: { s.isGranted })
            XCTAssertTrue(purged, record ?? "legacy")
            let cloud = await cache.audio(for: "cloudKey")
            let device = await cache.audio(for: "deviceKey")
            XCTAssertNil(cloud, "superseded cloud clip deleted at launch (\(record ?? "legacy"))")
            XCTAssertEqual(device, deviceClip, "on-device clip kept (\(record ?? "legacy"))")
        }
    }

    /// A current (v3) acceptance keeps its cloud clips: nothing is paid for again.
    func testLaunchKeepsCloudClipsWhileTheCurrentVersionIsAccepted() async {
        let s = store(record: CloudVoiceConsentStore.encode(.accepted))
        XCTAssertTrue(s.isGranted)
        let cache = await seeded()
        let purged = await renderer(cache: cache).purgeCloudClipsAtLaunch(isGranted: { s.isGranted })
        XCTAssertFalse(purged)
        let count = await cache.count
        XCTAssertEqual(count, 2)
    }

    /// Through the file cache the app uses: the v2 clip is gone from disk, the on-device one stays.
    func testLaunchPurgeDeletesTheSupersededClipFromDisk() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stale-consent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = FileAudioCache(directory: dir)
        await files.store(cloudClip, for: "cloudKey")
        await files.store(deviceClip, for: "deviceKey")
        let s = store(record: "2:accepted")
        await renderer(cache: files).purgeCloudClipsAtLaunch(isGranted: { s.isGranted })
        let reopened = FileAudioCache(directory: dir)
        let cloud = await reopened.audio(for: "cloudKey")
        let device = await reopened.audio(for: "deviceKey")
        XCTAssertNil(cloud)
        XCTAssertNotNil(device)
    }

    // MARK: Read-time purge

    /// The consent cache withholds a cloud clip under a stale acceptance, and deletes it (and every
    /// other cloud clip) from the base cache at that read. On-device clips are untouched.
    func testAReadUnderAStaleAcceptanceDeletesCloudClips() async {
        let base = await seeded()
        await base.store(cloudClip, for: "otherCloudKey")
        let s = store(record: "2:accepted")
        let cache = CloudVoiceConsentCache(base: base, localProviders: ["device"], isGranted: { s.isGranted })
        let read = await cache.audio(for: "cloudKey")
        XCTAssertNil(read, "a superseded cloud clip is never served")
        let left = await base.count
        XCTAssertEqual(left, 1, "every cloud clip is deleted at the withheld read")
        let device = await cache.audio(for: "deviceKey")
        XCTAssertEqual(device, deviceClip)
    }

    /// A read of an on-device clip, or any read while granted, never purges.
    func testReadsThatAreNotWithheldPurgeNothing() async {
        let base = await seeded()
        let declined = CloudVoiceConsentCache(base: base, localProviders: ["device"], isGranted: { false })
        _ = await declined.audio(for: "deviceKey")
        var count = await base.count
        XCTAssertEqual(count, 2, "an on-device read does not purge")
        let s = store(record: CloudVoiceConsentStore.encode(.accepted))
        let granted = CloudVoiceConsentCache(base: base, localProviders: ["device"], isGranted: { s.isGranted })
        let read = await granted.audio(for: "cloudKey")
        XCTAssertEqual(read, cloudClip)
        count = await base.count
        XCTAssertEqual(count, 2)
    }

    /// Source check: the app starts the launch purge with the tester / owner A/B consent reader.
    func testTheAppStartsTheLaunchPurge() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/AppDependencies.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("if let consent = TesterCloudVoiceConsentHooks.preparerConsent {"))
        XCTAssertTrue(source.contains("await voice.purgeCloudClipsAtLaunch(isGranted: consent)"))
    }
}
