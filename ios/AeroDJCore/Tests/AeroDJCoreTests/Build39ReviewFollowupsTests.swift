import XCTest
@testable import AeroDJCore

// Build 39 review follow-ups (-Nova): Echo's #403 N1 (the minimum gap has its own drop reason),
// Fry's #403 nit 1 (the gap comes back after a clock set back), Fry's #404 nit 1 (the consent
// cache forwards the device-run file count) and Sentinel's #404 note (the interruption
// acknowledgement is on-device only). In-process fakes only: no network, no paid service.
// Fixture titles; messages print counts only.

/// Off-device spy: records every text it is handed and renders it, so without the local-only
/// gate a render would succeed on this route and the test would see it.
private final class SpyVoice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    let id: String
    init(_ id: String) { self.id = id }
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("\(id):\(text)".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: id, cacheKey: nil)
    }
}

/// Records every key looked up or written; can be seeded with a clip.
private actor KeyCache: AudioCache {
    let inner = InMemoryAudioCache()
    private(set) var touched: [String] = []
    func audio(for key: String) async -> CachedAudio? { touched.append(key); return await inner.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async { touched.append(key); await inner.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func purgeAllPersonal() async { await inner.purgeAllPersonal() }
    func seed(_ audio: CachedAudio, for key: String) async { await inner.store(audio, for: key) }
}

/// A cache that cannot count its files (no `AudioCacheCounting`).
private struct UncountedCache: AudioCache {
    func audio(for key: String) async -> CachedAudio? { nil }
    func store(_ audio: CachedAudio, for key: String) async {}
    func purge(sourceItemIDs: Set<UUID>) async {}
    func purgeExpired() async {}
    func purgeAllPersonal() async {}
}

private final class Consent: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    var granted: Bool { lock.withLock { value } }
    func set(_ v: Bool) { lock.withLock { value = v } }
}

final class Build39ReviewFollowupsTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: hour, minute: minute))!
    }
    private func row(_ id: UUID, _ title: String) -> ConnectionItem {
        ConnectionItem(id: id, integration: .obsidian, title: title, state: .approved, sensitivity: .low)
    }
    private func personalCue(_ item: UUID, order: Int) -> NarrationCue {
        NarrationCue(id: UUID(), order: order, group: 0, kind: .note, text: "Fixture note \(order).", estimatedSeconds: 2,
                     maxSeconds: 10, sourceItemID: item, source: .obsidian, provenance: "fixture")
    }

    // MARK: Echo's #403 N1: `.minimumGap`

    /// A new queue inside the gap: the update that aired is `.repeatLimit` (daily limit), the
    /// other one `.minimumGap` (held by the gap only). Neither is offered to a later show. After
    /// the gap the other one airs.
    func testANewQueueInsideTheGapReportsTheGapApartFromTheDailyLimit() {
        let aired = UUID(), other = UUID()
        let items = [row(aired, "Fixture A"), row(other, "Fixture B")]
        let low: [UUID: Sensitivity] = [aired: .low, other: .low]
        let ledger = PersonalUpdateLedger(calendar: calendar)
        ledger.recordAired([personalCue(aired, order: 1)], at: at(10))
        // Control: without the ledger both rows would air, so the drops below are the limits'.
        XCTAssertEqual(Set(LiveQueueBriefing.handoff(items: items, preferences: .init(enabled: true), now: at(10, 10),
                                                     calendar: calendar, sensitivityByItemID: low)
                            .forQueue()?.cues.filter(\.isContent).compactMap(\.sourceItemID) ?? []), [aired, other])

        let inGap = LiveQueueBriefing.handoff(items: items, preferences: .init(enabled: true), now: at(10, 10),
                                              calendar: calendar, sensitivityByItemID: low, ledger: ledger)
        XCTAssertNil(inGap.forQueue(), "no personal update inside the gap")
        let outcomes = Dictionary(uniqueKeysWithValues: inGap.omittedByLimit.entries.compactMap { e in
            e.cue.sourceItemID.map { ($0, e.outcome) } })
        XCTAssertEqual(outcomes[aired], .dropped(.repeatLimit))
        XCTAssertEqual(outcomes[other], .dropped(.minimumGap))
        let carry = EditorialCarryForward(report: inGap.omittedByLimit)
        XCTAssertTrue(carry.eligibleNextShow.isEmpty, "a gap drop is never carried into a later show")

        let after = LiveQueueBriefing.handoff(items: items, preferences: .init(enabled: true), now: at(10, 30),
                                              calendar: calendar, sensitivityByItemID: low, ledger: ledger)
        XCTAssertEqual(after.forQueue()?.cues.filter(\.isContent).map(\.sourceItemID), [other])
        XCTAssertEqual(after.omittedByLimit.entries.map(\.outcome), [.dropped(.repeatLimit)])
    }

    /// The prepared-script path (`applyLimits`): inside the gap, a fresh update is `.minimumGap`;
    /// one at its daily limit, and a second cue for the same item, stay `.repeatLimit`.
    func testPreparedCuesInsideTheGapAreMinimumGapUnlessAtTheDailyLimit() {
        let aired = UUID(), fresh = UUID()
        let items = [row(aired, "Fixture A"), row(fresh, "Fixture B")]
        let ledger = PersonalUpdateLedger(calendar: calendar)
        ledger.recordAired([personalCue(aired, order: 1)], at: at(10))
        let cues = [personalCue(aired, order: 1), personalCue(fresh, order: 2), personalCue(fresh, order: 3)]
        let handoff = NarrationHandoff(cues: cues, maxSpokenSeconds: 45, experienceSeconds: 45)

        let limited = LiveQueueBriefing.applyLimits(handoff, items: items, now: at(10, 5), ledger: ledger)
        XCTAssertTrue(limited.handoff.cues.isEmpty)
        XCTAssertEqual(limited.omitted.map(\.outcome),
                       [.dropped(.repeatLimit), .dropped(.minimumGap), .dropped(.repeatLimit)],
                       "daily limit, gap, then a second cue for the same item")

        let outside = LiveQueueBriefing.applyLimits(handoff, items: items, now: at(11), ledger: ledger)
        XCTAssertEqual(outside.handoff.cues.map(\.sourceItemID), [fresh])
        XCTAssertFalse(outside.omitted.contains { $0.outcome == .dropped(.minimumGap) }, "no gap drop after the gap")
    }

    func testTheMinimumGapReasonHasAStableRawValue() {
        XCTAssertEqual(NarrationDropReason.minimumGap.rawValue, "minimumGap")
        XCTAssertNotEqual(NarrationDropReason.minimumGap, .repeatLimit)
    }

    // MARK: Fry's #403 nit 1: the gap after a clock set back

    /// The clock is set back 2 h after an airing, and an update airs again: the gap starts from
    /// that airing. With `max`, the stored time stayed 2 h ahead and the gap was off.
    func testAfterAClockSetBackTheGapStartsFromTheNextAiring() {
        let ledger = PersonalUpdateLedger(calendar: calendar)
        ledger.recordAired([personalCue(UUID(), order: 1)], at: at(10))
        XCTAssertFalse(ledger.isWithinMinimumGap(at: at(8)), "2 h set back: no permanent block")
        ledger.recordAired([personalCue(UUID(), order: 1)], at: at(8))
        XCTAssertTrue(ledger.isWithinMinimumGap(at: at(8, 10)), "the gap is back on from the 8:00 airing")
        XCTAssertFalse(ledger.isWithinMinimumGap(at: at(8, 30)))
    }

    // MARK: Fry's #404 nit 1: AudioCacheCounting through CloudVoiceConsentCache

    func testTheConsentCacheForwardsTheDeviceRunFileCount() async {
        let base = InMemoryAudioCache()
        await base.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v", sourceItemIDs: [UUID()]), for: "k1")
        await base.store(CachedAudio(data: Data([2]), seconds: 1, providerID: "cloud", voiceID: "v"), for: "k2")
        let consent = Consent(true)
        let wrapped = CloudVoiceConsentCache(base: base, localProviders: ["device"], isGranted: { consent.granted })

        let direct = await AudioCacheFileLog.record(base, after: .launch)
        let through = await AudioCacheFileLog.record(wrapped, after: .launch)
        XCTAssertEqual(through, "AeroDJ.cache narration cache count=2 personal=1 after=launch")
        XCTAssertEqual(through, direct)
        consent.set(false)
        let declined = await AudioCacheFileLog.fileCount(of: wrapped)
        XCTAssertEqual(declined, AudioCacheCount(files: 2, personal: 1), "counts what is stored, whatever the consent")
    }

    func testAWrapperOverACacheThatCannotCountReportsNothing() async {
        let wrapped = CloudVoiceConsentCache(base: UncountedCache(), localProviders: ["device"], isGranted: { true })
        let line = await AudioCacheFileLog.record(wrapped, after: .purge)
        XCTAssertNil(line, "no made-up count")
    }

    /// Wrapper in a wrapper: the count still comes through from the innermost cache.
    func testNestedConsentCachesForwardTheCount() async {
        let base = InMemoryAudioCache()
        await base.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "cloud", voiceID: "v"), for: "k1")
        let inner = CloudVoiceConsentCache(base: base, localProviders: ["device"], isGranted: { false })
        let outer = CloudVoiceConsentCache(base: inner, localProviders: ["device"], isGranted: { false })
        let count = await outer.forwardedFileCount()
        XCTAssertEqual(count, AudioCacheCount(files: 1, personal: 0))
    }

    // MARK: Sentinel's #409 N1: the wrapper forwards the count only, never the base cache

    private func coreSource(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AeroDJCore/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Source check: the base cache is a private stored property, and no public or open
    /// declaration in the wrapper or the forwarding protocol hands out an `AudioCache`. The only
    /// public mentions are the type's own conformance and the init that takes the base.
    func testTheConsentCacheExposesNoBaseCache() throws {
        let wrapper = try coreSource("Voice/CloudVoiceConsentCache.swift")
        XCTAssertTrue(wrapper.contains("private let base: any AudioCache"), "base stays private")
        let code = wrapper.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        let exposing = code.filter { line in
            (line.hasPrefix("public") || line.hasPrefix("open") || line.hasPrefix("package") || line.hasPrefix("internal")
             || line.hasPrefix("let ") || line.hasPrefix("var ") || line.hasPrefix("func ") || line.hasPrefix("fileprivate"))
            && line.contains("AudioCache")
            && !line.hasPrefix("public struct CloudVoiceConsentCache: AudioCache")
            && !line.hasPrefix("public init(base: any AudioCache")
            && !line.contains("AudioCacheCount")
        }
        XCTAssertEqual(exposing, [], "no declaration other than the private base mentions the cache type")
        XCTAssertFalse(wrapper.contains("forwardedCache"))

        let log = try coreSource("Voice/AudioCacheFileLog.swift")
        let proto = try XCTUnwrap(log.range(of: "public protocol AudioCacheForwarding"))
        let body = log[proto.upperBound...].prefix { $0 != "}" }
        XCTAssertFalse(body.contains("any AudioCache"), "the forwarding protocol carries a count, not a cache")
        XCTAssertTrue(body.contains("func forwardedFileCount() async -> AudioCacheCount?"))
    }

    // MARK: Sentinel's #404 note: the acknowledgement stays on-device

    /// Cloud and paid routes first, consent or not: the acknowledgement renders on the device
    /// route. The cloud and paid voices never hear it, and a cloud clip already cached under its
    /// text is never read.
    func testTheInterruptionAcknowledgementAlwaysRendersOnDevice() async throws {
        let cloud = SpyVoice("cloud"), paid = SpyVoice("paid")
        let cloudRoute = VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true)
        let paidRoute = VoiceRoute(providerID: "paid", provider: paid, voice: djVoice, microdollarsPerThousandCharacters: 1)
        let cache = KeyCache()
        let cloudKey = VoiceRenderer.cacheKey(text: SpeechDelivery.speakable(BreakInterruptionAcknowledgement.line), route: cloudRoute)
        await cache.seed(CachedAudio(data: Data("cached-cloud".utf8), seconds: 1, providerID: "cloud", voiceID: djVoice.id), for: cloudKey)
        let renderer = VoiceRenderer(routes: [cloudRoute, paidRoute,
                                              VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 1_000_000), cache: cache,
                                     revocations: NarrationRevocations())

        let data = await BreakInterruptionAcknowledgement.renderClip(with: renderer, userID: "u", stationID: "s")
        let text = String(decoding: try XCTUnwrap(data), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("device:"), "rendered by the on-device route")
        XCTAssertTrue(cloud.received.isEmpty, "the cloud voice never hears it")
        XCTAssertTrue(paid.received.isEmpty, "nor a paid voice")
        let touched = await cache.touched
        XCTAssertFalse(touched.contains(cloudKey), "the cached cloud clip is never read")
    }

    /// No on-device route: nothing renders (the break resumes without it); never a cloud clip.
    func testWithOnlyACloudRouteTheAcknowledgementIsNotRendered() async {
        let cloud = SpyVoice("cloud")
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                                     revocations: NarrationRevocations())
        let data = await BreakInterruptionAcknowledgement.renderClip(with: renderer, userID: "u", stationID: "s")
        XCTAssertNil(data)
        XCTAssertTrue(cloud.received.isEmpty)
    }
}
