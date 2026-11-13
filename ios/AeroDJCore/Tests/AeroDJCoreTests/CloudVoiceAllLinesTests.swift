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
    // MARK: Owner's calls on #433 (Nov 9 2026). -Fry

    /// The owner A/B build's route (the owner proxy, leaves the device) behind `gated(by:)`: nothing
    /// for a v1 acceptance, a decline or no answer; every attributed line after v2 is accepted.
    func testOwnerABRendererSendsEveryLineOnlyAfterVersionTwo() async throws {
        let (d, suite) = try defaults(); defer { d.removePersistentDomain(forName: suite) }
        let store = CloudVoiceConsentStore(defaults: d)
        let spy = CloudSpy(), l = lines()
        let owner = VoiceRenderer(routes: [VoiceRoute(providerID: "owner-proxy", provider: spy, voice: djVoice,
                                                      leavesDevice: true),
                                           VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                  budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                                  revocations: NarrationRevocations()).gated(by: store)
        let all = l.personal + l.news + l.library + [l.transition]
        XCTAssertEqual(store.state, .undecided)
        var used = await providers(owner, all)
        XCTAssertEqual(used, Array(repeating: "device", count: all.count), "undecided")
        d.set(CloudVoiceConsentState.accepted.rawValue, forKey: CloudVoiceConsentStore.stateKey)
        d.set(1, forKey: CloudVoiceConsentStore.versionKey)
        XCTAssertEqual(store.state, .undecided, "a v1-only acceptance is asked again")
        XCTAssertTrue(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: true, state: store.state),
                      "the v2 sheet shows on the next launch")
        used = await providers(owner, all)
        XCTAssertEqual(used, Array(repeating: "device", count: all.count), "v1 only")
        store.decline()
        used = await providers(owner, all)
        XCTAssertEqual(used, Array(repeating: "device", count: all.count), "declined / cloud voice off")
        XCTAssertTrue(spy.received.isEmpty, "sent before v2: \(spy.received)")
        store.accept()
        XCTAssertEqual(store.scope, .allLines)
        XCTAssertFalse(CloudVoiceConsentPrompt.shouldPresent(cloudVoiceOffered: true, state: store.state))
        used = await providers(owner, all)
        XCTAssertEqual(used, Array(repeating: "owner-proxy", count: all.count), "v2 accepted")
        XCTAssertEqual(spy.received.count, all.count)
    }

    /// Both cloud-voice builds build their live renderer through the consent store, and the owner
    /// A/B build shows the same v2 sheet and toggle as the tester build.
    func testBothCloudVoiceBuildsGateTheirRendererAndShowTheV2Sheet() throws {
        let trial = try appSource("OwnerVoiceTrial+App.swift")
        let owner = try XCTUnwrap(trial.range(of: "#if AERODJ_OWNER_AB\n        let composition"))
        let tester = try XCTUnwrap(trial.range(of: "#elseif AERODJ_TESTER_VOICE", range: owner.upperBound..<trial.endIndex))
        let end = try XCTUnwrap(trial.range(of: "#else\n        return base", range: tester.upperBound..<trial.endIndex))
        XCTAssertTrue(trial[owner.upperBound..<tester.lowerBound].contains(".gated(by: OwnerCloudVoice.consentStore)"))
        XCTAssertTrue(trial[tester.upperBound..<end.lowerBound].contains(".gated(by: TesterCloudVoice.consentStore)"))
        XCTAssertFalse(trial.contains("cloudScope:"), "no hand-rolled scope in the app")

        let consent = try appSource("TesterVoiceConsent+App.swift")
        XCTAssertTrue(consent.contains("#if AERODJ_OWNER_AB\n        modifier(OwnerCloudVoiceConsentGate())"))
        let gate = try XCTUnwrap(consent.range(of: "private struct OwnerCloudVoiceConsentGate"))
        let gateBody = consent[gate.lowerBound...].prefix(1400)
        XCTAssertTrue(gateBody.contains("state: OwnerCloudVoice.consentStore.state"))
        XCTAssertTrue(gateBody.contains("CloudVoiceConsentSheet { accepted in\n                    OwnerCloudVoice.record(accepted: accepted)"))
        XCTAssertTrue(consent.contains("#if AERODJ_TESTER_VOICE || AERODJ_OWNER_AB\n/// Tune → DJ"), "the toggle is in both builds")
        let tune = try appSource("TuneForm.swift")
        XCTAssertTrue(tune.contains("#if AERODJ_TESTER_VOICE || AERODJ_OWNER_AB"))
    }

    /// Owner's call 6: the launch purge keeps cloud clips of library songs and station names
    /// (tagged only `allLinesClipTag`) and still deletes clips of personal items; "Delete DJ clips,
    /// ratings and location" deletes both.
    func testLaunchPurgeKeepsLibraryAndStationCloudClipsAndDeleteRemovesThem() async throws {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let cache = InMemoryAudioCache(), revocations = NarrationRevocations()
        let spy = CloudSpy(), l = lines()
        let r = renderer(spy, store: store, cache: cache, revocations: revocations)
        _ = await providers(r, l.personal + l.news + l.library + [l.transition])
        let before = await cache.count
        XCTAssertEqual(before, l.personal.count + l.library.count + 1, "news and weather are never cached")
        await AudioCacheSweeper(cache: cache).prepareForLaunch(purgingPersonalFirst: true)
        let afterLaunch = await cache.count
        XCTAssertEqual(afterLaunch, l.library.count + 1, "library and station-name clips are kept between launches")
        let sentBefore = spy.received.count
        let replay = await providers(r, l.library)
        XCTAssertEqual(replay, ["cloud", "cloud"])
        XCTAssertEqual(spy.received.count, sentBefore, "kept clips play from the cache, not sent again")
        await PersonalDataReset.run(NarrationPurger(cache: cache, preparer: nil, revocations: revocations,
                                                    feed: NarrationPurgeFeed()))
        let afterDelete = await cache.count
        XCTAssertEqual(afterDelete, 1, "Delete removes them; only the non-personal transition stays")
    }

    /// The same through the file cache the app uses, and through the consent wrapper.
    func testFileCacheLaunchPurgeKeepsTagOnlyClips() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CloudVoiceAllLines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = FileAudioCache(directory: dir)
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let cache = CloudVoiceConsentCache(base: files, localProviders: ["device"], isGranted: { store.isGranted })
        let spy = CloudSpy(), l = lines(), revocations = NarrationRevocations()
        let r = renderer(spy, store: store, cache: cache, revocations: revocations)
        _ = await providers(r, l.personal + l.library + [l.transition])
        await AudioCacheSweeper(cache: cache).prepareForLaunch(purgingPersonalFirst: true)
        let afterLaunch = await AudioCacheFileLog.fileCount(of: files)
        XCTAssertEqual(afterLaunch, AudioCacheCount(files: l.library.count + 1, personal: l.library.count))
        // A relaunch reads the same directory: the kept clips are still there.
        let reopened = await AudioCacheFileLog.fileCount(of: FileAudioCache(directory: dir))
        XCTAssertEqual(reopened, AudioCacheCount(files: l.library.count + 1, personal: l.library.count))
        await cache.purgeAllPersonal()
        let afterDelete = await AudioCacheFileLog.fileCount(of: files)
        XCTAssertEqual(afterDelete, AudioCacheCount(files: 1, personal: 0))
    }

    /// Owner's call 4: coordinates and the location itself are never sent, but a local news line
    /// can name the listener's city or area. In the sheet, the location prompt and every page.
    func testLocationWordingSaysCoordinatesAreNeverSentButNewsCanNameThePlace() throws {
        let never = CloudVoiceConsentCopy.neverSent
        XCTAssertTrue(never.contains("your coordinates or your location itself"))
        XCTAssertTrue(never.contains("a local news line can name your city or area"))
        XCTAssertFalse(never.contains("your location or coordinates,"))
        XCTAssertTrue(LocalAreaConsentCopy.body.contains("Your coordinates and your location itself are never"))
        XCTAssertTrue(LocalAreaConsentCopy.body.contains("a local headline can name your city or area"))
        XCTAssertFalse(LocalAreaConsentCopy.body.contains("on-device voice only"), "v2 sends news and weather lines")
        XCTAssertTrue(LocalAreaConsentCopy.usageDescription.contains("Your location itself is never sent"))

        let refined = "Your coordinates and your location itself are never sent, but a local news line can name your city or area."
        let privacy = try repoFile("docs/site/privacy.md")
        // The 2.0 page (#509) sends a coarse coordinate to WeatherKit, so it no longer carries the
        // blanket "coordinates ... are never sent" line. Call 4 lives in "What's never sent". -Sentinel
        let neverSentLine = "What's never sent: your Apple ID, your contacts, your coordinates or your location itself, or anything you haven't approved for your briefing. Only the words the DJ speaks are sent, and a local news line can name your city or area."
        let weatherKitLine = "For local weather, a coarse coordinate is sent only to Apple WeatherKit. Apple handles that data under [Apple's Privacy Policy](https://www.apple.com/legal/privacy/)."
        XCTAssertTrue(privacy.contains(neverSentLine))
        XCTAssertTrue(privacy.contains(weatherKitLine))
        XCTAssertFalse(privacy.contains(refined), "privacy.md must not claim coordinates are never sent; WeatherKit gets a coarse one")
        XCTAssertFalse(privacy.contains("Your location is not sent."))
        XCTAssertTrue(privacy.contains("Cloud clips of library songs and station names are kept between launches"))
        let hold = try repoFile("docs/site/HOLD-pro.md")
        XCTAssertTrue(hold.contains(refined))
        XCTAssertFalse(hold.contains("contacts, location, calendar, notes, shared items, library tracks or the station names you type"),
                       "HOLD-pro's \"What we don't send\" contradicted .allLines")
        XCTAssertFalse(hold.contains("Nothing personal. Your calendar"), "the FAQ answer is qualified by the cloud voice")
        let draft = try repoFile("docs/site/DRAFT-privacy-tester-voice.md")
        XCTAssertTrue(draft.contains("a local news line can name your city or area"))
        let matrix = try repoFile("docs/PRIVACY_MATRIX.md")
        XCTAssertTrue(matrix.contains("a local headline can name the listener's city or area"))
        XCTAssertTrue(matrix.contains("`purgePersonalItems`"))
    }

    /// The v2 sheet still names every category it sends, with the refined location claim.
    func testConsentCopyNamesTheCategoriesAndTheLocationClaim() {
        let sheet = [CloudVoiceConsentCopy.intro, CloudVoiceConsentCopy.sent, CloudVoiceConsentCopy.neverSent].joined(separator: " ")
        for word in ["calendar", "email digest", "notes", "music library", "station names", "news", "weather",
                     "coordinates", "city or area"] {
            XCTAssertTrue(sheet.contains(word), "the sheet must mention \(word)")
        }
        XCTAssertTrue(PersonalDataReset.message.contains("cloud-voice clips of your library songs and station names"))
    }

    private func appSource(_ name: String) throws -> String { try repoFile("ios/AeroDJ/\(name)") }

    private func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
