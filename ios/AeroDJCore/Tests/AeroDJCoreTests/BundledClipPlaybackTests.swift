import XCTest
@testable import AeroDJCore

// Bundled pre-rendered presenter clips (plan v1). Build 27 ships an empty manifest, so these
// tests pin that an empty manifest changes nothing, and that a filled one plays a clip only for
// a whole `.presenter` line whose normalized-text hash, voice and render settings all match.
// All providers are in-process fakes: no network, no proxy, no paid service, no audio rendered.

/// Stands in for the ElevenLabs proxy: records every text it is sent.
private final class ProxySpy: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("proxy:\(text)".utf8), durationSeconds: 1.5, billableUnits: text.count,
                             provider: "elevenlabs", cacheKey: nil)
    }
}

final class BundledClipPlaybackTests: XCTestCase {
    private let voiceA = "voice-A"
    private let clipBytes = Data("bundled-m4a".utf8)
    private let directory = URL(fileURLWithPath: "/bundle")
    private var presenterLine: String { EditorialTone.warm.continuation[0] }
    private var otherPresenterLine: String { EditorialTone.warm.continuation[1] }

    // MARK: fixtures

    private func proxyRoute(_ spy: ProxySpy, voice: String? = nil) -> VoiceRoute {
        VoiceRoute(providerID: PremiumVoiceRoutes.providerID, provider: spy,
                   voice: VoiceProfile(id: voice ?? voiceA, name: "Paid"), leavesDevice: true)
    }

    private func renderer(_ spy: ProxySpy, voice: String? = nil) -> VoiceRenderer {
        VoiceRenderer(routes: [proxyRoute(spy, voice: voice), VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                      revocations: NarrationRevocations(), cloudConsent: .inMemory(.accepted))
    }

    private func entry(_ text: String, id: String = "warm.continuation.0", hash: String? = nil,
                       file: String? = nil, seconds: Double = 2.5) -> BundledClipManifest.Entry {
        let h = hash ?? BundledClipManifest.textHash(text)
        return .init(id: id, tone: "warm", text: text, textSHA256: h, file: file ?? "\(h).m4a", seconds: seconds)
    }

    private func manifest(_ entries: [BundledClipManifest.Entry], voice: String? = nil,
                          settings: String = BundledClipManifest.currentRenderSettingsVersion) -> BundledClipManifest {
        BundledClipManifest(voiceID: voice ?? voiceA, renderSettingsVersion: settings, entries: entries)
    }

    private func resolver(_ m: BundledClipManifest, allowedTexts: Set<String>? = BundledClipResolver.allowedTexts,
                          readable: Bool = true, access: ProVoiceAccess = .proWithConsentForTests) -> BundledClipResolver {
        let bytes = clipBytes
        return BundledClipResolver(manifest: m, directory: directory, access: access, allowedTexts: allowedTexts,
                                   readData: { _ in readable ? bytes : nil })
    }

    private func cue(_ text: String, maxSeconds: Int = 20) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 3, maxSeconds: maxSeconds, sourceItemID: nil, source: nil, provenance: nil)
    }

    private func oneCueBreak(_ c: NarrationCue, _ attribution: SpokenAttribution? = .presenter) -> DJBreak {
        DJBreak(afterTrack: 0, cues: [c], attributions: attribution.map { [c.id: $0] } ?? [:])
    }

    private func render(_ b: DJBreak, _ r: VoiceRenderer, _ bundled: BundledClipResolver?) async -> DJBreakOutcome {
        await DJBreakPreparer.render(b, renderer: r, userID: "u", stationID: "s",
                                     cap: .init(main: 15, closingCueID: b.talkOverCueID, closing: 4), bundled: bundled)
    }

    private func providers(_ outcome: DJBreakOutcome) -> [String] {
        guard case .ready(let p) = outcome else { return [] }
        return p.clips.map(\.audio.providerID)
    }

    // MARK: empty manifest: zero behavior change

    func testEmptyManifestGivesIdenticalBreaksAndProxyCalls() async {
        var writer = DJScriptWriter(seed: 27)
        let tracks = (1...14).map { DJTrack(id: "t\($0)", title: "Song \($0)", artist: "Artist \($0)", origin: .catalog) }
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 8)
        XCTAssertFalse(plan.breaks.isEmpty)
        let emptyResolvers: [BundledClipResolver] = [
            BundledClipResolver(manifest: .empty, directory: directory, access: .proWithConsentForTests),
            BundledClipResolver(manifest: .decode(Data()), directory: directory, access: .proWithConsentForTests),
            BundledClipResolver(manifest: .load(contentsOf: shippedManifestURL), directory: directory, access: .proWithConsentForTests),
        ]
        for empty in emptyResolvers {
            XCTAssertEqual(empty.usableCount, 0)
            let baseSpy = ProxySpy(), emptySpy = ProxySpy()
            let baseRenderer = renderer(baseSpy), emptyRenderer = renderer(emptySpy)
            for b in plan.breaks {
                let base = await render(b, baseRenderer, nil)
                let withEmpty = await render(b, emptyRenderer, empty)
                XCTAssertEqual(base, withEmpty, "break \(b.afterTrack)")
                guard case .ready(let p) = withEmpty else { return XCTFail("break \(b.afterTrack): \(withEmpty)") }
                XCTAssertFalse(p.clips.contains { $0.audio.providerID == BundledClipResolver.providerID })
            }
            XCTAssertFalse(baseSpy.received.isEmpty)
            XCTAssertEqual(baseSpy.received, emptySpy.received, "same proxy calls, same order")
        }
    }

    func testPreparerWithEmptyManifestMatchesPreparerWithout() async {
        let c = cue(presenterLine)
        var outcomes: [DJBreakOutcome] = []
        var calls: [[String]] = []
        for bundled in [nil, BundledClipResolver(manifest: .empty, directory: directory, access: .proWithConsentForTests)] {
            let spy = ProxySpy()
            let preparer = DJBreakPreparer(renderer: renderer(spy), userID: "u", stationID: "s", bundledClips: bundled)
            await preparer.prepare(oneCueBreak(c), deadline: .seconds(10), onDeviceOnly: false)
            outcomes.append(await outcome(preparer))
            calls.append(spy.received)
        }
        XCTAssertEqual(outcomes[0], outcomes[1])
        XCTAssertEqual(calls[0], [presenterLine])
        XCTAssertEqual(calls[0], calls[1])
    }

    // MARK: a matching entry plays, with no proxy call

    func testMatchingEntryIsUsedAndNoProxyCallIsMade() async {
        let spy = ProxySpy()
        let c = cue(presenterLine)
        let preparer = DJBreakPreparer(renderer: renderer(spy), userID: "u", stationID: "s",
                                       bundledClips: resolver(manifest([entry(presenterLine)])))
        await preparer.prepare(oneCueBreak(c), deadline: .seconds(10), onDeviceOnly: false)
        guard case .ready(let p) = await outcome(preparer) else { return XCTFail("bundled break should be ready") }
        XCTAssertTrue(spy.received.isEmpty, "a bundled hit must not call the proxy")
        XCTAssertEqual(p.clips.map(\.audio.providerID), [BundledClipResolver.providerID])
        XCTAssertEqual(p.clips.first?.audio.data, clipBytes)
        XCTAssertEqual(p.clips.first?.audio.voiceID, voiceA)
        XCTAssertEqual(p.cues.first?.renderedSeconds, 2.5, "the manifest's measured seconds feed the break")
        XCTAssertEqual(p.cues.first?.providerID, BundledClipResolver.providerID)
        XCTAssertEqual(p.clips.first?.audio.sourceItemIDs, [])
    }

    func testBundledSecondsFeedTalkoverAndBreakCaps() async {
        let spy = ProxySpy()
        let color = cue(presenterLine)
        let closing = cue("Next up, Song 2 by Artist 2.", maxSeconds: 4)
        var b = DJBreak(afterTrack: 0, cues: [color, closing],
                        attributions: [color.id: .presenter, closing.id: .trackMetadata(trackIDs: ["t2"], origin: .catalog)])
        b.talkOverCueID = closing.id
        let bundled = resolver(manifest([entry(presenterLine, seconds: 3.25)]))
        guard case .ready(let p) = await render(b, renderer(spy), bundled) else { return XCTFail("mixed break should be ready") }
        XCTAssertEqual(spy.received, [closing.text], "only the live closing line goes to the proxy")
        XCTAssertEqual(p.clips.map(\.audio.providerID), [BundledClipResolver.providerID, PremiumVoiceRoutes.providerID])
        XCTAssertEqual(try XCTUnwrap(p.talkOverStartSeconds), 3.25 + PreparedDJBreak.talkOverGapSeconds, accuracy: 1e-9)

        // A bundled clip longer than the main cap is measured like any clip: the break re-renders
        // once on the on-device route (never the bundle), not a silent overrun.
        let long = resolver(manifest([entry(presenterLine, seconds: 16)]))
        let spy2 = ProxySpy()
        let over = await render(oneCueBreak(cue(presenterLine)), renderer(spy2), long)
        XCTAssertEqual(providers(over), ["device"])
        XCTAssertTrue(spy2.received.isEmpty)
    }

    func testTalkoverVoiceLimitSeesBundledSeconds() {
        // DJTalkover reads clip seconds; a bundled clip is a RenderedClip with its manifest seconds.
        let r = resolver(manifest([entry(presenterLine, seconds: 2.5)]))
        let clip = r.clip(for: cue(presenterLine), attribution: .presenter, renderer: renderer(ProxySpy()))
        XCTAssertEqual(clip?.audio.seconds, 2.5)
    }

    // MARK: every mismatch falls back to today's path

    func testHashMismatchWrongVoiceOrWrongSettingsFallsBack() async {
        let line = presenterLine
        let cases: [(String, BundledClipResolver, String?)] = [
            ("hash mismatch", resolver(manifest([entry(line, hash: BundledClipManifest.textHash(otherPresenterLine))])), nil),
            ("manifest voice differs", resolver(manifest([entry(line)], voice: "voice-B")), nil),
            ("route voice differs", resolver(manifest([entry(line)])), "voice-B"),
            ("old settings version", resolver(manifest([entry(line)], settings: "eleven_flash_v2_5;stability=0.50")), nil),
            ("missing settings version", resolver(BundledClipManifest(voiceID: voiceA, renderSettingsVersion: nil, entries: [entry(line)])), nil),
            ("missing voice", resolver(BundledClipManifest(voiceID: nil, renderSettingsVersion: BundledClipManifest.currentRenderSettingsVersion, entries: [entry(line)])), nil),
            ("unreadable file", resolver(manifest([entry(line)]), readable: false), nil),
            ("over the cue's max seconds", resolver(manifest([entry(line, seconds: 21)])), nil),
        ]
        for (name, bundled, routeVoice) in cases {
            let spy = ProxySpy()
            let outcome = await render(oneCueBreak(cue(line)), renderer(spy, voice: routeVoice), bundled)
            XCTAssertEqual(providers(outcome), [PremiumVoiceRoutes.providerID], name)
            XCTAssertEqual(spy.received, [line], "\(name): the proxy path runs unchanged")
        }
    }

    func testOneCharacterEditMisses() async {
        let spy = ProxySpy()
        let edited = presenterLine + " "
        let outcome = await render(oneCueBreak(cue(edited)), renderer(spy), resolver(manifest([entry(presenterLine)])))
        XCTAssertEqual(providers(outcome), [PremiumVoiceRoutes.providerID])
        XCTAssertEqual(spy.received, [edited])
    }

    func testOnDeviceOnlyAndOnDeviceDefaultNeverUseTheBundle() async throws {
        let bundled = resolver(manifest([entry(presenterLine)]))
        let full = renderer(ProxySpy())
        let local = try XCTUnwrap(full.onDeviceOnly)
        XCTAssertNil(bundled.clip(for: cue(presenterLine), attribution: .presenter, renderer: local))
        XCTAssertNil(bundled.clip(for: cue(presenterLine), attribution: .presenter, renderer: try XCTUnwrap(full.lastRouteOnly)))
        let outcome = await render(oneCueBreak(cue(presenterLine)), local, bundled)
        XCTAssertEqual(providers(outcome), ["device"])

        // A library-seed station through the preparer: on-device, never the bundle.
        let spy = ProxySpy()
        let preparer = DJBreakPreparer(renderer: renderer(spy), userID: "u", stationID: "s", bundledClips: bundled)
        await preparer.prepare(oneCueBreak(cue(presenterLine)), deadline: .seconds(10), onDeviceOnly: true)
        let seeded = await self.outcome(preparer)
        XCTAssertEqual(providers(seeded), ["device"])
        XCTAssertTrue(spy.received.isEmpty)
    }

    // MARK: only presenter lines resolve

    func testStationNameAndSongLinesNeverResolveEvenWhenTheirTextIsInTheManifest() async {
        // Song line: catalog track metadata may leave the device, but is never bundled. Validation
        // is switched off here so only the attribution gate stands in the way.
        let song = "That was Song 1 by Artist 1."
        let songOnly = resolver(manifest([entry(song, id: "song")]), allowedTexts: nil)
        let songCue = cue(song)
        for attribution: SpokenAttribution? in [.trackMetadata(trackIDs: ["t1"], origin: .catalog),
                                                 .trackMetadata(trackIDs: ["t1"], origin: .library),
                                                 .personalContext(itemID: UUID(), source: .calendar, provenance: "p"),
                                                 nil] {
            XCTAssertNil(songOnly.clip(for: songCue, attribution: attribution, renderer: renderer(ProxySpy())), "\(String(describing: attribution))")
        }
        let spy = ProxySpy()
        let songBreak = oneCueBreak(songCue, .trackMetadata(trackIDs: ["t1"], origin: .catalog))
        let songOutcome = await render(songBreak, renderer(spy), songOnly)
        XCTAssertEqual(providers(songOutcome), [PremiumVoiceRoutes.providerID])
        XCTAssertEqual(spy.received, [song])

        // Created-station ID ("Night Bus Electronic" is the canary): its filled text is never a
        // constant line, so it never loads, whatever attribution the cue carries. (#222 attributes
        // it `.stationName`, which the `.presenter`-only gate also refuses.)
        let template = EditorialTone.warm.stationID[0]
        let stationLine = try! XCTUnwrap(TemplatePool.fill(template, ["station": "Night Bus Electronic"]))
        let stationManifest = resolver(manifest([entry(stationLine, id: "warm.stationID.0")]))
        XCTAssertEqual(stationManifest.usableCount, 0)
        XCTAssertNil(stationManifest.clip(for: cue(stationLine), attribution: .presenter, renderer: renderer(ProxySpy())))
        // Same for the built-in name until the OnAirly rename batch adds its own rule.
        let builtIn = try! XCTUnwrap(TemplatePool.fill(template, ["station": "AeroDJ"]))
        XCTAssertEqual(resolver(manifest([entry(builtIn)])).usableCount, 0)
    }

    func testPersonalOrSourcedCueNeverResolvesEvenIfPresenterAttributed() {
        // mayLeaveDevice is false for a sourced cue, so the bundle is not consulted.
        let r = resolver(manifest([entry(presenterLine)]))
        let sourced = NarrationCue(id: UUID(), order: 0, group: 0, kind: .transition, text: presenterLine,
                                   estimatedSeconds: 3, maxSeconds: 20, sourceItemID: UUID(), source: .calendar,
                                   provenance: "test")
        XCTAssertNil(r.clip(for: sourced, attribution: .presenter, renderer: renderer(ProxySpy())))
    }

    // MARK: manifest validation

    func testEntryWithSlotMarkerIsRejected() {
        let slotted = "Coming up, {nextTitle}."
        let e = entry(slotted, id: "warm.closing.0")
        XCTAssertTrue(BundledClipManifest.problems(of: e, allowedTexts: nil).contains(.slotMarker(id: "warm.closing.0")))
        XCTAssertTrue(manifest([e]).problems().contains(.slotMarker(id: "warm.closing.0")))
        XCTAssertTrue(BundledClipManifest.problems(of: entry("Here's {station}."), allowedTexts: nil)
            .contains(.slotMarker(id: "warm.continuation.0")))
        // Rejected at load too: never resolves, even for a cue with that literal text.
        let r = resolver(manifest([e]), allowedTexts: nil)
        XCTAssertEqual(r.usableCount, 0)
        XCTAssertNil(r.clip(for: cue(slotted), attribution: .presenter, renderer: renderer(ProxySpy())))
    }

    func testValidationFlagsBadEntries() {
        let good = entry(presenterLine)
        XCTAssertEqual(manifest([good]).problems(), [])
        XCTAssertEqual(BundledClipManifest.problems(of: entry(presenterLine, hash: String(repeating: "0", count: 64)), allowedTexts: nil),
                       [.hashMismatch(id: good.id)])
        for file in ["", "../x.m4a", "a/b.m4a", ".hidden.m4a"] {
            XCTAssertEqual(BundledClipManifest.problems(of: entry(presenterLine, file: file), allowedTexts: nil), [.badFile(id: good.id)], file)
        }
        for s in [0, -1, Double.nan, .infinity] {
            XCTAssertEqual(BundledClipManifest.problems(of: entry(presenterLine, seconds: s), allowedTexts: nil), [.badSeconds(id: good.id)])
        }
        XCTAssertEqual(BundledClipManifest.problems(of: entry("Not a pool line."), allowedTexts: BundledClipResolver.allowedTexts),
                       [.notAConstantPresenterLine(id: good.id)])
        let dup = manifest([good, entry(presenterLine, id: "copy")])
        XCTAssertEqual(dup.problems(), [.duplicateHash(id: "copy")])
        XCTAssertEqual(resolver(dup).usableCount, 0, "an ambiguous hash never plays")
        XCTAssertEqual(BundledClipManifest(voiceID: nil, renderSettingsVersion: nil, entries: [good]).problems(),
                       [.missingVoiceID, .missingRenderSettingsVersion])
        XCTAssertEqual(BundledClipManifest.empty.problems(), [])
    }

    func testAllowedTextsAreFixedV1PresenterLinesOnly() {
        let allowed = BundledClipResolver.allowedTexts
        let warm = EditorialTone.warm
        XCTAssertFalse(allowed.isEmpty)
        XCTAssertFalse(allowed.contains { $0.contains("{") || $0.contains("}") })
        for line in warm.closing + warm.backAnnounce + warm.artistFocus + warm.stationID + warm.briefingLead + warm.briefingOutro {
            XCTAssertFalse(allowed.contains(line), line)
        }
        XCTAssertTrue(allowed.isSubset(of: Set(warm.continuation + warm.atmosphere.values.flatMap { $0 }
                                                + warm.greetings.values.flatMap { $0 })))
    }

    // MARK: loader

    func testLoaderToleratesEmptyMissingOrMalformedFiles() throws {
        XCTAssertEqual(BundledClipManifest.load(contentsOf: nil), .empty)
        XCTAssertEqual(BundledClipManifest.load(contentsOf: URL(fileURLWithPath: "/nonexistent/BundledClipsManifest.json")), .empty)
        for raw in ["", "  \n", "{}", "not json", "[]", #"{"entries": 3}"#] {
            XCTAssertEqual(BundledClipManifest.decode(Data(raw.utf8)), .empty, raw)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("BundledClipsManifest.json")
        try Data().write(to: url)
        XCTAssertEqual(BundledClipManifest.load(contentsOf: url), .empty)
        let m = manifest([entry(presenterLine)])
        try JSONEncoder().encode(m).write(to: url)
        XCTAssertEqual(BundledClipManifest.load(contentsOf: url), m)
    }

    // MARK: the shipped manifest

    private var shippedManifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AeroDJ/\(BundledClipManifest.resourceName).\(BundledClipManifest.resourceExtension)")
    }

    func testEveryEntryInTheShippedManifestValidates() throws {
        // Strict decode: the tolerant loader must never be what hides a broken shipped file.
        let data = try Data(contentsOf: shippedManifestURL)
        let shipped = try JSONDecoder().decode(BundledClipManifest.self, from: data)
        XCTAssertEqual(shipped.problems(), [])
        for e in shipped.entries {
            XCTAssertEqual(BundledClipManifest.problems(of: e, allowedTexts: BundledClipResolver.allowedTexts), [], e.id)
        }
        if shipped.entries.isEmpty {
            // Build 27: empty, with voice and settings left blank.
            XCTAssertNil(shipped.voiceID)
            XCTAssertNil(shipped.renderSettingsVersion)
        } else {
            XCTAssertEqual(shipped.renderSettingsVersion, BundledClipManifest.currentRenderSettingsVersion)
            XCTAssertNotNil(shipped.voiceID.flatMap(PremiumVoiceCatalog.index(ofVoiceID:)), "a catalog voice")
        }
        XCTAssertEqual(BundledClipResolver(manifest: shipped, directory: directory, access: .proWithConsentForTests).usableCount, shipped.entries.count)
    }

    func testAppWiresTheShippedManifestIntoTheLivePreparer() throws {
        let app = shippedManifestURL.deletingLastPathComponent().appendingPathComponent("AppDependencies.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        XCTAssertTrue(text.contains("forResource: BundledClipManifest.resourceName"))
        XCTAssertTrue(text.contains("bundledClips: bundledClips)"))
    }

    private func outcome(_ preparer: DJBreakPreparer, afterTrack k: Int = 0) async -> DJBreakOutcome {
        while true {
            if let result = await preparer.testResult(afterTrack: k) { return result }
            await Task.yield()
        }
    }
}

// MARK: the Pro + consent gate (fry/storekit-config)

extension BundledClipPlaybackTests {
    /// A manifest that would hit, rendered through the preparer with `access`: the provider IDs
    /// of the clips, and what the proxy was sent.
    private func gatedRun(_ access: ProVoiceAccess) async -> (providers: [String], proxy: [String]) {
        let spy = ProxySpy()
        let bundled = resolver(manifest([entry(presenterLine)]), access: access)
        let outcome = await render(oneCueBreak(cue(presenterLine)), renderer(spy), bundled)
        guard case .ready(let p) = outcome else { XCTFail("break should still be ready on today's path"); return ([], []) }
        return (p.clips.map(\.audio.providerID), spy.received)
    }

    func testProWithConsentIsTheOnlyAccessThatPlaysABundledClip() async {
        let hit = await gatedRun(.proWithConsentForTests)
        XCTAssertEqual(hit.providers, [BundledClipResolver.providerID], "control: this manifest does hit")
        XCTAssertTrue(hit.proxy.isEmpty)
    }

    func testFreeTierGetsZeroBundledClips() async {
        for access in [ProVoiceAccess.none, .testing(.free, consent: true), .testing(.free, consent: false)] {
            let run = await gatedRun(access)
            XCTAssertFalse(run.providers.contains(BundledClipResolver.providerID))
        }
    }

    func testProWithConsentRevokedGetsZeroBundledClips() async {
        let run = await gatedRun(.testing(.pro(productID: ProSubscriptionConfig.yearlyProductID, expiresAt: nil), consent: false))
        XCTAssertFalse(run.providers.contains(BundledClipResolver.providerID))
    }

    func testUnverifiedExpiredOrRevokedGetZeroBundledClips() async {
        let id = ProSubscriptionConfig.monthlyProductID
        let states: [ProEntitlementState] = [.unverified(productID: id),
                                             .expired(productID: id, expiredAt: Date(timeIntervalSince1970: 0)),
                                             .revoked(productID: id, revokedAt: Date(timeIntervalSince1970: 0))]
        for state in states {
            let run = await gatedRun(.testing(state, consent: true))
            XCTAssertFalse(run.providers.contains(BundledClipResolver.providerID), "\(state)")
        }
    }

    func testConsentWithdrawnMidShowStopsTheNextLookup() async {
        let consent = SwitchableConsent(true)
        let bundled = resolver(manifest([entry(presenterLine)]),
                               access: ProVoiceAccess(entitlement: FixedEntitlement(.pro(productID: ProSubscriptionConfig.monthlyProductID, expiresAt: nil)),
                                                      consent: consent))
        let r = renderer(ProxySpy())
        let first = await bundled.gatedClip(for: cue(presenterLine), attribution: .presenter, renderer: r)
        XCTAssertNotNil(first)
        consent.set(false)
        let second = await bundled.gatedClip(for: cue(presenterLine), attribution: .presenter, renderer: r)
        XCTAssertNil(second)
    }
}
