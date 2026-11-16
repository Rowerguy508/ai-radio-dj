import XCTest
@testable import AeroDJCore

// #432 (OnAirly 2.0, -Sentinel): every DJ line may use the cloud voice, but only after the
// listener accepts cloud-voice copy v3. A v1 or v2 grant, no answer, a decline or the toggle off
// sends nothing personal or news-related, and a decline drops prepared cloud breaks and cached
// cloud clips. In-process fakes only: no network, no paid service.

/// Off-device fake that records every text it is asked to voice.
private final class RecordingCloudVoice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

final class CloudVoiceConsentV3Tests: XCTestCase {
    private typealias Store = CloudVoiceConsentStore

    private struct Rig {
        let defaults: UserDefaults
        let suite: String
        let store: Store
        let cloud: RecordingCloudVoice
        let renderer: VoiceRenderer
        let preparer: DJBreakPreparer
    }

    /// The live shape both cloud-voice builds use: a persisted store, a renderer gated by it
    /// (`gated(by:)`) and a preparer with the take-time consent check.
    private func rig(record: String? = nil) async throws -> Rig {
        let suite = "CloudVoiceConsentV3Tests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        if let record { d.set(record, forKey: Store.recordKey) }
        let store = Store(defaults: d)
        let cloud = RecordingCloudVoice()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true),
                                              VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                                     revocations: NarrationRevocations()).gated(by: store)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s",
                                       cloudVoiceConsent: { @Sendable in store.isGranted })
        return Rig(defaults: d, suite: suite, store: store, cloud: cloud, renderer: renderer, preparer: preparer)
    }

    private let calendarText = "From your calendar: dentist at 3."
    private let digestText = "Your shared email digest: the lease is signed."
    private let newsText = "In the news: the bridge reopens Monday."
    private let weatherText = "Seventy-two and sunny here."
    private let libraryText = "That was Private Song by Someone, from your library."
    private let stationText = "You're listening to Kitchen Jams."

    /// One break with a line of every category #432 names. Each call makes fresh cue ids.
    private func everyKindBreak(afterTrack k: Int) -> DJBreak {
        let event = UUID(), digest = UUID()
        func cue(_ order: Int, _ kind: BriefingScriptSegment.Kind, _ text: String, item: UUID? = nil,
                 source: ContextSourceKind? = nil, provenance: String? = nil, expiresAt: Date? = nil) -> NarrationCue {
            NarrationCue(id: UUID(), order: order, group: -1, kind: kind, text: text, estimatedSeconds: 3, maxSeconds: 20,
                         sourceItemID: item, source: source, provenance: provenance, expiresAt: expiresAt)
        }
        let soon = Date().addingTimeInterval(600)
        let cues = [
            cue(0, .upcomingEvent, calendarText, item: event, source: .calendar, provenance: "calendar:1"),
            cue(1, .upcomingEvent, digestText, item: digest, source: .emailShared, provenance: "share:1"),
            cue(2, .transition, newsText, provenance: FactProvenance.make(kind: .localNews, id: UUID(), provider: "gdelt"), expiresAt: soon),
            cue(3, .transition, weatherText, provenance: FactProvenance.make(kind: .weather, id: UUID()), expiresAt: soon),
            cue(4, .transition, libraryText),
            cue(5, .transition, stationText),
        ]
        let attributions: [UUID: SpokenAttribution] = [
            cues[0].id: .personalContext(itemID: event, source: .calendar, provenance: "calendar:1"),
            cues[1].id: .personalContext(itemID: digest, source: .emailShared, provenance: "share:1"),
            cues[2].id: .presenter, cues[3].id: .presenter,
            cues[4].id: .trackMetadata(trackIDs: ["lib1"], origin: .library),
            cues[5].id: .stationName,
        ]
        return DJBreak(afterTrack: k, cues: cues, attributions: attributions)
    }

    private var privateTexts: [String] { [calendarText, digestText, newsText, weatherText, libraryText, stationText] }

    private func outcome(_ preparer: DJBreakPreparer, afterTrack k: Int) async -> DJBreakOutcome {
        while true {
            if let result = await preparer.testResult(afterTrack: k) { return result }
            await Task.yield()
        }
    }

    private func prepare(_ r: Rig, afterTrack k: Int) async -> DJBreakOutcome {
        await r.preparer.prepare(everyKindBreak(afterTrack: k), deadline: .seconds(10), onDeviceOnly: false)
        return await outcome(r.preparer, afterTrack: k)
    }

    // MARK: - Older grants send nothing

    func testAVersionTwoGrantSendsNoPersonalOrNewsLineAndIsAskedAgain() async throws {
        let r = try await rig(record: "2:accepted"); defer { r.defaults.removePersistentDomain(forName: r.suite) }
        XCTAssertEqual(r.store.state, .undecided, "a v2 grant is superseded by v3")
        XCTAssertEqual(r.store.scope, .noLines)
        XCTAssertTrue(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: true, state: r.store.state))
        guard case .ready(let ready) = await prepare(r, afterTrack: 0) else { return XCTFail("on-device break prepares") }
        XCTAssertFalse(ready.clips.isEmpty)
        XCTAssertTrue(ready.clips.allSatisfy { $0.audio.providerID == "device" }, "the old on-device routing stays")
        XCTAssertTrue(r.cloud.received.isEmpty, "a v2 grant sent \(r.cloud.received.count) lines")
    }

    func testAVersionOneGrantUndecidedAndDeclinedSendNothing() async throws {
        for record in ["1:accepted", nil, "\(Store.currentVersion):undecided", "\(Store.currentVersion):declined",
                       "\(Store.currentVersion - 1):declined"] as [String?] {
            let r = try await rig(record: record); defer { r.defaults.removePersistentDomain(forName: r.suite) }
            XCTAssertEqual(r.store.scope, .noLines, "record \(record ?? "nil")")
            guard case .ready(let ready) = await prepare(r, afterTrack: 0) else { return XCTFail("on-device break prepares") }
            XCTAssertTrue(ready.clips.allSatisfy { $0.audio.providerID == "device" }, "record \(record ?? "nil")")
            XCTAssertTrue(r.cloud.received.isEmpty, "record \(record ?? "nil") sent \(r.cloud.received.count) lines")
        }
    }

    // MARK: - The new grant sends every line

    func testAVersionThreeGrantSendsEveryPersonalNewsLibraryAndStationLine() async throws {
        let r = try await rig(); defer { r.defaults.removePersistentDomain(forName: r.suite) }
        r.store.accept()
        XCTAssertEqual(r.defaults.string(forKey: Store.recordKey), "3:accepted")
        XCTAssertEqual(r.store.scope, .allLines)
        guard case .ready(let ready) = await prepare(r, afterTrack: 0) else { return XCTFail("cloud break prepares") }
        XCTAssertTrue(ready.clips.allSatisfy { $0.audio.providerID == "cloud" })
        XCTAssertEqual(Set(r.cloud.received), Set(privateTexts), "every category goes to the cloud voice")
    }

    // MARK: - Decline and withdrawal

    func testADeclineSendsNothingMoreAndDropsThePreparedCloudBreakAndCachedClips() async throws {
        let r = try await rig(); defer { r.defaults.removePersistentDomain(forName: r.suite) }
        r.store.accept()
        guard case .ready = await prepare(r, afterTrack: 0) else { return XCTFail("cloud break prepares") }
        let sentBefore = r.cloud.received.count
        // The app's decline / toggle-off path (`CloudVoiceConsentApp.answer(false)`).
        r.store.decline()
        let dropped = await r.preparer.dropCloudVoiceBreaks()
        await r.renderer.purgeCloudClips()
        XCTAssertEqual(dropped, [0])
        let taken = await r.preparer.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked), "a prepared cloud break never airs after a decline")
        guard case .ready(let next) = await prepare(r, afterTrack: 2) else { return XCTFail("on-device break prepares") }
        XCTAssertTrue(next.clips.allSatisfy { $0.audio.providerID == "device" })
        XCTAssertEqual(r.cloud.received.count, sentBefore, "nothing is sent after a decline")
        // The cached cloud clips are gone: a later v3 grant has to voice the cacheable lines again.
        r.store.accept()
        guard case .ready = await prepare(r, afterTrack: 4) else { return XCTFail("cloud break prepares") }
        for text in [calendarText, digestText, libraryText, stationText] {
            XCTAssertEqual(r.cloud.received.filter { $0 == text }.count, 2, "\(text.prefix(12))… was served from a purged cache")
        }
    }

    /// Withdrawal without a decline: the stored grant is superseded (an app update to new copy) or
    /// reset while a cloud break is prepared. The take re-checks and drops it, and cached cloud
    /// clips are not served.
    func testAWithdrawnGrantDropsThePreparedCloudBreakAtTheTakeAndServesNoCachedCloudClip() async throws {
        let r = try await rig(); defer { r.defaults.removePersistentDomain(forName: r.suite) }
        r.store.accept()
        guard case .ready = await prepare(r, afterTrack: 0) else { return XCTFail("cloud break prepares") }
        let sentBefore = r.cloud.received.count
        r.defaults.set("2:accepted", forKey: Store.recordKey)   // an older grant only
        let taken = await r.preparer.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, .skipped(.paidVoiceRevoked))
        guard case .ready(let next) = await prepare(r, afterTrack: 2) else { return XCTFail("on-device break prepares") }
        XCTAssertTrue(next.clips.allSatisfy { $0.audio.providerID == "device" }, "no cached cloud clip is served")
        XCTAssertEqual(r.cloud.received.count, sentBefore)
    }

    // MARK: - The rule and the copy

    func testOnlyTheAllLinesVersionGrantsAllLines() {
        XCTAssertEqual(Store.allLinesVersion, 3)
        XCTAssertEqual(Store.currentVersion, Store.allLinesVersion)
        for version in [0, 1, 2, 4] {
            XCTAssertFalse(Store.grantsAllLines(state: .accepted, copyVersion: version), "v\(version)")
            XCTAssertEqual(Store.decode("\(version):accepted"), version == Store.currentVersion ? .accepted : .undecided)
        }
        XCTAssertTrue(Store.grantsAllLines(state: .accepted, copyVersion: 3))
        XCTAssertFalse(Store.grantsAllLines(state: .declined, copyVersion: 3))
        XCTAssertFalse(Store.grantsAllLines(state: .undecided, copyVersion: 3))
    }

    func testTheVersionThreeCopySaysEveryLineGoesToElevenLabsAndNeverClaimsZeroRetention() {
        let sheet = [CloudVoiceConsentCopy.intro, CloudVoiceConsentCopy.sent, CloudVoiceConsentCopy.stored].joined(separator: " ")
        XCTAssertTrue(CloudVoiceConsentCopy.intro.contains("every line the DJ says"))
        XCTAssertTrue(CloudVoiceConsentCopy.intro.contains("ElevenLabs"))
        for word in ["calendar", "email digest", "notes", "music library", "station names", "news", "weather"] {
            XCTAssertTrue(CloudVoiceConsentCopy.sent.contains(word), "the sheet must say \(word) lines are sent")
        }
        XCTAssertTrue(CloudVoiceConsentCopy.stored.contains("Model training is turned off for our ElevenLabs account"))
        XCTAssertTrue(CloudVoiceConsentCopy.stored.contains("ElevenLabs may keep the text and audio"))
        XCTAssertTrue(CloudVoiceConsentCopy.footer.contains("ElevenLabs may keep it"))
        for claim in ["zero retention", "not retain", "never stored", "isn't stored", "deleted immediately", "doesn't keep", "won't keep"] {
            XCTAssertFalse((sheet + " " + CloudVoiceConsentCopy.footer).lowercased().contains(claim), "claims \(claim)")
        }
        for word in ["calendar", "email digest", "notes", "library", "station names", "news", "weather"] {
            XCTAssertTrue(CloudVoiceConsentCopy.footer.contains(word), "footer must name \(word)")
        }
    }
}
