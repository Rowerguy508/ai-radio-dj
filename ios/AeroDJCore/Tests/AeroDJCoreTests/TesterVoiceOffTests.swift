import XCTest
@testable import AeroDJCore

// Tester build: the cloud voice can be turned off (Sentinel's N1 on #395), and turning it off
// drops breaks already rendered in the cloud voice and the cached cloud clips (Echo's N2).
// All providers are in-process fakes: no network, no paid service. -Nova

/// Off-device fake: renders every text it is handed as "cloud" audio, and counts the calls.
private final class CloudFake: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { count += 1 }
        return VoiceArtifact(data: Data("cloud:\(text)".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

final class TesterVoiceOffTests: XCTestCase {
    // MARK: Fix 1: the toggle is offered in the tester build

    /// Every combination of the two build flags, the owner's paid-provider gate and a selection.
    func testCloudVoiceIsOfferedForEveryFlagCombination() {
        for ownerAB in [false, true] {
            for tester in [false, true] {
                for paid in [false, true] {
                    for selected in [nil, "v"] as [String?] {
                        let offered = CloudVoiceConsentPrompt.isCloudVoiceOffered(
                            ownerABBuild: ownerAB, testerVoiceBuild: tester,
                            paidProvidersEnabled: paid, selectedVoiceID: selected)
                        let expected: Bool
                        if ownerAB {
                            expected = paid && selected != nil   // owner A/B: unchanged, and it wins
                        } else {
                            expected = tester                    // tester: always; neither flag: never
                        }
                        XCTAssertEqual(offered, expected,
                                       "ownerAB=\(ownerAB) tester=\(tester) paid=\(paid) selected=\(selected ?? "nil")")
                    }
                }
            }
        }
    }

    /// The owner A/B rule is the existing two-argument one, unchanged.
    func testOwnerABMatchesTheExistingRule() {
        for paid in [false, true] {
            for selected in [nil, "v"] as [String?] {
                XCTAssertEqual(
                    CloudVoiceConsentPrompt.isCloudVoiceOffered(ownerABBuild: true, testerVoiceBuild: false,
                                                                paidProvidersEnabled: paid, selectedVoiceID: selected),
                    CloudVoiceConsentPrompt.isCloudVoiceOffered(paidProvidersEnabled: paid, selectedVoiceID: selected))
            }
        }
    }

    /// The build this test target was compiled as: plain (Linux CI, Release) is never offered;
    /// `-DAERODJ_TESTER_VOICE` (check-release-disables-paid-voice.sh) is offered with no selection.
    func testThisBuild() {
        #if AERODJ_OWNER_AB
        XCTAssertEqual(CloudVoiceConsentPrompt.isCloudVoiceOfferedInThisBuild(selectedVoiceID: nil), false)
        #elseif AERODJ_TESTER_VOICE
        XCTAssertTrue(CloudVoiceConsentPrompt.isCloudVoiceOfferedInThisBuild(selectedVoiceID: nil))
        #else
        XCTAssertFalse(CloudVoiceConsentPrompt.isCloudVoiceOfferedInThisBuild(selectedVoiceID: nil))
        XCTAssertFalse(CloudVoiceConsentPrompt.isCloudVoiceOfferedInThisBuild(selectedVoiceID: "v"))
        #endif
    }

    // MARK: Fix 2: turning it off drops prepared cloud breaks

    private struct Rig {
        let preparer: DJBreakPreparer
        let consent: CloudVoiceConsentStore
        let cloud: CloudFake
        let events: DJEventLog
    }

    private func rig(consent: CloudVoiceConsentState = .accepted, checksConsent: Bool = true) async -> Rig {
        let cloud = CloudFake()
        let store = CloudVoiceConsentStore.inMemory(consent)
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true),
                                              VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let reader: (@Sendable () -> Bool)? = checksConsent ? { @Sendable in store.isGranted } : nil
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cloudVoiceConsent: reader)
        let events = DJEventLog()
        await preparer.observe { events.add($0) }
        return Rig(preparer: preparer, consent: store, cloud: cloud, events: events)
    }

    private func presenterBreak(afterTrack k: Int) -> DJBreak {
        let cue = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "That was Song \(k) by Artist \(k).",
                               estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        return DJBreak(afterTrack: k, cues: [cue], attributions: [cue.id: .presenter])
    }

    private func outcome(_ preparer: DJBreakPreparer, afterTrack k: Int) async -> DJBreakOutcome {
        while true {
            if let result = await preparer.testResult(afterTrack: k) { return result }
            await Task.yield()
        }
    }

    /// Break 0 is rendered in the cloud voice, break 2 on-device (a library-seeded break). Both
    /// are ready, then consent is turned off.
    private func prepareBoth(_ r: Rig) async {
        await r.preparer.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        await r.preparer.prepare(presenterBreak(afterTrack: 2), deadline: .seconds(10), onDeviceOnly: true)
        guard case .ready(let cloudBreak) = await outcome(r.preparer, afterTrack: 0),
              case .ready(let deviceBreak) = await outcome(r.preparer, afterTrack: 2) else { return XCTFail("both should prepare") }
        XCTAssertEqual(cloudBreak.clips.map(\.audio.providerID), ["cloud"])
        XCTAssertEqual(deviceBreak.clips.map(\.audio.providerID), ["device"])
    }

    func testTurningCloudVoiceOffDropsThePreparedCloudBreakAndKeepsOnDeviceBreaks() async {
        let r = await rig()
        await prepareBoth(r)
        r.consent.decline()   // the toggle turned off
        let dropped = await r.preparer.dropCloudVoiceBreaks()
        XCTAssertEqual(dropped, [0], "only the cloud-rendered break is dropped")
        XCTAssertTrue(r.events.all.contains(.skipped(afterTrack: 0, .paidVoiceRevoked)))
        let taken = await r.preparer.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked), "the cloud break is not played")
        guard case .ready(let kept) = await r.preparer.takeBreak(afterTrack: 2) else { return XCTFail("on-device break kept") }
        XCTAssertEqual(kept.clips.map(\.audio.providerID), ["device"])
    }

    /// The take re-checks consent on its own: a decline the eager drop never saw (it raced the
    /// render, or nothing called it) still keeps the cloud break off air.
    func testTheTakeRechecksConsentWithoutTheEagerDrop() async {
        let r = await rig()
        await prepareBoth(r)
        r.consent.decline()
        let taken = await r.preparer.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked))
        guard case .ready = await r.preparer.takeBreak(afterTrack: 2) else { return XCTFail("on-device break kept") }
    }

    /// A break that finishes after the decline: its next cue goes on-device here (the tester
    /// route refuses without consent; this fake has no such check), but any cloud clip in it,
    /// cached or rendered before the decline, keeps it off air.
    func testABreakRenderedInTheCloudAfterTheDeclineIsDroppedAtTheTake() async {
        let r = await rig()
        r.consent.decline()
        await r.preparer.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        guard case .ready = await outcome(r.preparer, afterTrack: 0) else { return XCTFail("prepared") }
        let taken = await r.preparer.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked))
    }

    func testWhileConsentIsGrantedNothingIsDropped() async {
        let r = await rig()
        await prepareBoth(r)
        let dropped = await r.preparer.dropCloudVoiceBreaks()
        XCTAssertEqual(dropped, [])
        guard case .ready(let played) = await r.preparer.takeBreak(afterTrack: 0) else { return XCTFail("cloud break plays") }
        XCTAssertEqual(played.clips.map(\.audio.providerID), ["cloud"])
    }

    /// Every build without the tester voice passes no consent check: nothing changes there.
    func testWithoutAConsentCheckNothingChanges() async {
        let r = await rig(consent: .declined, checksConsent: false)
        await r.preparer.prepare(presenterBreak(afterTrack: 0), deadline: .seconds(10), onDeviceOnly: false)
        guard case .ready = await outcome(r.preparer, afterTrack: 0) else { return XCTFail("prepared") }
        let dropped = await r.preparer.dropCloudVoiceBreaks()
        XCTAssertEqual(dropped, [])
        guard case .ready = await r.preparer.takeBreak(afterTrack: 0) else { return XCTFail("unchanged") }
    }

    // MARK: Cached cloud clips

    func testPurgeCloudClipsDeletesCloudClipsAndKeepsOnDeviceOnes() async throws {
        let cloud = CloudFake()
        let cache = InMemoryAudioCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true),
                                              VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let cue = presenterBreak(afterTrack: 0).cues[0]
        let local = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "Local line.",
                                 estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        _ = await renderer.render(cue, userID: "u", stationID: "s", attribution: .presenter)
        _ = await renderer.render(local, userID: "u", stationID: "s")   // no attribution: on-device
        var count = await cache.count
        XCTAssertEqual(count, 2)
        await renderer.purgeCloudClips()
        count = await cache.count
        XCTAssertEqual(count, 1, "the cloud clip is deleted, the on-device clip kept")
        // Not served from the cache again: the cloud route is asked afresh.
        _ = await renderer.render(cue, userID: "u", stationID: "s", attribution: .presenter)
        XCTAssertEqual(cloud.calls, 2)
        let device = try await renderer.render(local, userID: "u", stationID: "s").get()
        XCTAssertEqual(device.attempts.last?.result, .cacheHit)
    }

    func testFileCachePurgeCloudClipsKeepsOnlyOnDeviceProviders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tester-voice-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FileAudioCache(directory: dir)
        await cache.store(CachedAudio(data: Data("c".utf8), seconds: 1, providerID: "cloud", voiceID: "host"), for: "cloudKey")
        await cache.store(CachedAudio(data: Data("d".utf8), seconds: 1, providerID: "device", voiceID: "host"), for: "deviceKey")
        try Data("orphan".utf8).write(to: dir.appendingPathComponent("orphan.caf"))
        await cache.purgeClips(keepingProviders: ["device"])
        let cloudClip = await cache.audio(for: "cloudKey")
        let deviceClip = await cache.audio(for: "deviceKey")
        XCTAssertNil(cloudClip)
        XCTAssertNotNil(deviceClip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("orphan.caf").path),
                       "unattributable audio is removed too")
    }
}
