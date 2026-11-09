import XCTest
@testable import AeroDJCore

// Owner, Nov 9 2026: "I want it all elevenlabs." Every attributed DJ line may use the cloud voice,
// but only after the listener accepts cloud-voice copy v2, which says so. An acceptance of v1, an
// undecided answer or the cloud voice turned off sends nothing. In-process fakes only: no network,
// no paid service. -Fry

private final class CloudSpy: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

final class CloudVoiceAllLinesTests: XCTestCase {
    private struct Line { let cue: NarrationCue; let attribution: SpokenAttribution? }

    private func cue(_ kind: BriefingScriptSegment.Kind, _ text: String, item: UUID? = nil,
                     source: ContextSourceKind? = nil, provenance: String? = nil, expiresAt: Date? = nil) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: 0, kind: kind, text: text, estimatedSeconds: 3, maxSeconds: 20,
                     sourceItemID: item, source: source, provenance: provenance, expiresAt: expiresAt)
    }

    /// One line of each kind the owner named, plus a #176-eligible transition and an unattributed cue.
    private func lines() -> (personal: [Line], news: [Line], library: [Line], transition: Line, unattributed: Line) {
        let event = UUID(), digest = UUID()
        let calendar = cue(.upcomingEvent, "From your calendar: dentist at 3.", item: event, source: .calendar, provenance: "calendar:1")
        let email = cue(.upcomingEvent, "Your shared email digest: the lease is signed.", item: digest, source: .emailShared, provenance: "share:1")
        let weather = cue(.transition, "Seventy-two and sunny here.",
                          provenance: FactProvenance.make(kind: .weather, id: UUID()), expiresAt: Date().addingTimeInterval(600))
        let headline = cue(.transition, "In the news: the bridge reopens Monday.",
                           provenance: FactProvenance.make(kind: .localNews, id: UUID(), provider: "gdelt"),
                           expiresAt: Date().addingTimeInterval(600))
        let libraryTrack = cue(.transition, "That was Private Song by Someone, from your library.")
        let stationName = cue(.transition, "You're listening to Kitchen Jams.")
        return (personal: [Line(cue: calendar, attribution: .personalContext(itemID: event, source: .calendar, provenance: "calendar:1")),
                           Line(cue: email, attribution: .personalContext(itemID: digest, source: .emailShared, provenance: "share:1"))],
                news: [Line(cue: weather, attribution: .presenter), Line(cue: headline, attribution: .presenter)],
                library: [Line(cue: libraryTrack, attribution: .trackMetadata(trackIDs: ["lib1"], origin: .library)),
                          Line(cue: stationName, attribution: .stationName)],
                transition: Line(cue: cue(.transition, "Next up, Song 2 by Artist 2."),
                                 attribution: .trackMetadata(trackIDs: ["t2"], origin: .catalog)),
                unattributed: Line(cue: cue(.transition, "Little interruption, back to it."), attribution: nil))
    }

    private func renderer(_ spy: CloudSpy, store: CloudVoiceConsentStore,
                          cache: any AudioCache = InMemoryAudioCache(),
                          revocations: NarrationRevocations = NarrationRevocations()) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: revocations,
                      cloudScope: { store.scope })
    }

    private func providers(_ r: VoiceRenderer, _ lines: [Line]) async -> [String?] {
        var out: [String?] = []
        for line in lines {
            out.append(try? await r.render(line.cue, userID: "u", stationID: "s", attribution: line.attribution).get().audio.providerID)
        }
        return out
    }

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "CloudVoiceAllLinesTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testCopyVersionTwoIsTheAllLinesCopyAndSaysWhatIsSent() {
        XCTAssertEqual(CloudVoiceConsentCopy.version, 2)
        XCTAssertEqual(CloudVoiceConsentStore.currentVersion, CloudVoiceConsentStore.allLinesVersion)
        let sent = CloudVoiceConsentCopy.sent
        for word in ["calendar", "email digest", "notes", "music library", "station names", "news", "weather"] {
            XCTAssertTrue(sent.contains(word), "the sheet must say \(word) lines are sent")
        }
        XCTAssertFalse(CloudVoiceConsentCopy.neverSent.contains("music library"), "v1's library promise is gone")
        XCTAssertTrue(CloudVoiceConsentCopy.footer.contains("calendar") && CloudVoiceConsentCopy.footer.contains("news"))
    }

    func testAnAcceptanceOfVersionOneSendsNothing() async throws {
        let (d, suite) = try defaults(); defer { d.removePersistentDomain(forName: suite) }
        d.set(CloudVoiceConsentState.accepted.rawValue, forKey: CloudVoiceConsentStore.stateKey)
        d.set(1, forKey: CloudVoiceConsentStore.versionKey)
        let store = CloudVoiceConsentStore(defaults: d)
        XCTAssertEqual(store.state, .undecided, "v1 consent is asked again")
        XCTAssertEqual(store.scope, .noLines)
        let spy = CloudSpy(), r = renderer(spy, store: store), l = lines()
        let all = l.personal + l.news + l.library + [l.transition]
        let used = await providers(r, all)
        XCTAssertEqual(used, Array(repeating: "device", count: all.count))
        XCTAssertTrue(spy.received.isEmpty, "a v1 acceptance sent \(spy.received)")
    }

    func testAnAcceptanceOfVersionTwoSendsEveryAttributedLine() async throws {
        let (d, suite) = try defaults(); defer { d.removePersistentDomain(forName: suite) }
        let store = CloudVoiceConsentStore(defaults: d)
        store.accept()
        XCTAssertEqual(store.scope, .allLines)
        let spy = CloudSpy(), r = renderer(spy, store: store), l = lines()
        let all = l.personal + l.news + l.library + [l.transition]
        let used = await providers(r, all)
        XCTAssertEqual(used, Array(repeating: "cloud", count: all.count))
        XCTAssertEqual(spy.received.count, all.count)
        XCTAssertTrue(spy.received.contains { $0.contains("dentist") })
        XCTAssertTrue(spy.received.contains { $0.contains("bridge reopens") })
        // No attribution is still a bug signal: on the device, whatever the consent.
        let unattributed = await providers(r, [l.unattributed])
        XCTAssertEqual(unattributed, ["device"])
        XCTAssertEqual(spy.received.count, all.count)
    }

    func testCloudVoiceOffOrUndecidedSendsNothing() async throws {
        let (d, suite) = try defaults(); defer { d.removePersistentDomain(forName: suite) }
        let store = CloudVoiceConsentStore(defaults: d)
        let spy = CloudSpy(), r = renderer(spy, store: store), l = lines()
        let all = l.personal + l.news + l.library + [l.transition]
        XCTAssertEqual(store.scope, .noLines)
        _ = await providers(r, all)
        store.accept()
        store.decline()  // the Cloud voice toggle turned off
        XCTAssertEqual(store.scope, .noLines)
        let used = await providers(r, all)
        XCTAssertEqual(used, Array(repeating: "device", count: all.count))
        XCTAssertTrue(spy.received.isEmpty, "cloud voice off sent \(spy.received)")
    }

    func testARendererWithNoConsentCheckKeepsTheTransitionsOnlyRule() async {
        let spy = CloudSpy(), l = lines()
        let r = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice, leavesDevice: true),
                                       VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                              budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                              revocations: NarrationRevocations())
        let private_ = await providers(r, l.personal + l.news + l.library)
        XCTAssertEqual(private_, Array(repeating: "device", count: 6))
        let transition = await providers(r, [l.transition])
        XCTAssertEqual(transition, ["cloud"])
        XCTAssertEqual(spy.received, ["Next up, Song 2 by Artist 2."])
    }

    func testLibraryStationBreaksUseTheCloudVoiceOnlyWithVersionTwo() async throws {
        for granted in [true, false] {
            let store = CloudVoiceConsentStore.inMemory(granted ? .accepted : .declined)
            let spy = CloudSpy(), l = lines()
            let preparer = DJBreakPreparer(renderer: renderer(spy, store: store), userID: "u", stationID: "s")
            let line = l.library[0]
            await preparer.prepare(DJBreak(afterTrack: 0, cues: [line.cue], attributions: [line.cue.id: line.attribution!]),
                                   deadline: .seconds(10), onDeviceOnly: true)
            var result: DJBreakOutcome?
            for _ in 0..<100_000 where result == nil {
                result = await preparer.testResult(afterTrack: 0)
                if result == nil { await Task.yield() }
            }
            guard case .ready(let prepared)? = result else { return XCTFail("granted \(granted): \(String(describing: result))") }
            XCTAssertEqual(prepared.clips.map(\.audio.providerID), [granted ? "cloud" : "device"])
            XCTAssertEqual(spy.received.isEmpty, !granted)
        }
    }

    func testDeleteMyDJDataRemovesCachedCloudClipsOfPersonalLines() async throws {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let cache = InMemoryAudioCache(), revocations = NarrationRevocations()
        let spy = CloudSpy(), l = lines()
        let r = renderer(spy, store: store, cache: cache, revocations: revocations)
        _ = await providers(r, l.personal + l.news + l.library + [l.transition])
        // News and weather lines are never cached (#200); the transition clip is not personal.
        let cached = await cache.count
        XCTAssertEqual(cached, l.personal.count + l.library.count + 1)
        let personal = await cache.fileCount().personal
        XCTAssertEqual(personal, l.personal.count + l.library.count, "every widened cloud clip is tagged")
        await PersonalDataReset.run(NarrationPurger(cache: cache, preparer: nil, revocations: revocations,
                                                    feed: NarrationPurgeFeed()))
        let left = await cache.count
        XCTAssertEqual(left, 1, "only the non-personal transition clip may stay")
        // A cached library-line clip is rendered again, and tagged again, after the reset.
        let again = await providers(r, [l.library[0]])
        XCTAssertEqual(again, ["cloud"])
        let tagged = await cache.fileCount().personal
        XCTAssertEqual(tagged, 1)
    }

    func testAPurgeAllInFlightCancelsAWidenedCloudWrite() async throws {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let cache = InMemoryAudioCache(), revocations = NarrationRevocations()
        let l = lines()
        let line = l.library[0]
        // The provider runs the purge-all while it "synthesizes": the write must not land after it.
        struct PurgingVoice: VoiceProvider {
            let revocations: NarrationRevocations
            func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
                revocations.revokeAll(); revocations.purgeAllCompleted()
                return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count, provider: "cloud", cacheKey: nil)
            }
        }
        let r = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: PurgingVoice(revocations: revocations),
                                                  voice: djVoice, leavesDevice: true)],
                              budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: revocations,
                              cloudScope: { store.scope })
        let result = await r.render(line.cue, userID: "u", stationID: "s", attribution: line.attribution)
        guard case .failure = result else { return XCTFail("a purge-all mid-render must cancel the clip") }
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }
}
