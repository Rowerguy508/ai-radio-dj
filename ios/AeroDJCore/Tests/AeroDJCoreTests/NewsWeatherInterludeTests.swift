import XCTest
@testable import AeroDJCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// #200 news & weather in DJ commentary (-Echo). Fixture providers only: no network, no keys,
// no location service, no paid voice.

/// Counts calls and records the area each call saw.
private final class SpyProvider: WeatherProvider, NewsProvider, @unchecked Sendable {
    let kind: BroadcastFactKind
    private let lock = NSLock()
    private var seen: [LocalArea?] = []
    var calls: [LocalArea?] { lock.withLock { seen } }
    init(kind: BroadcastFactKind) { self.kind = kind }
    func facts(for request: FactRequest) async -> FactProviderResult {
        lock.withLock { seen.append(request.area) }
        return .facts([BroadcastFact(kind: kind, payload: .headline(HeadlineFact(headline: "Bridge reopens", outlet: "WNYC")),
                                     observedAt: request.now, expiresAt: request.now.addingTimeInterval(600),
                                     attribution: FactAttribution(providerID: "spy", spokenName: "WNYC", requiresSpokenCredit: true))])
    }
}

/// Off-device voice that records every text it is handed.
private final class RecordingCloud: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var got: [String] = []
    var texts: [String] { lock.withLock { got } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { got.append(text) }
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: 0, provider: "cloud", cacheKey: nil)
    }
}

private actor RequestLog { var requests: [URLRequest] = []; func add(_ r: URLRequest) { requests.append(r) } }
private struct CapturingTransport: HTTPTransport {
    let log = RequestLog()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await log.add(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "audio/wav", "X-Audio-Duration": "2"])!
        return (Data([1, 2, 3]), response)
    }
}

private final class DropLog: @unchecked Sendable {
    private let lock = NSLock()
    private var got: [(Int, FactCueDropCounts)] = []
    func add(_ k: Int, _ c: FactCueDropCounts) { lock.withLock { got.append((k, c)) } }
    var all: [(Int, FactCueDropCounts)] { lock.withLock { got } }
}

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
private let brooklyn = LocalArea(locality: "Brooklyn", region: "NY", countryCode: "us",
                                 coordinate: CoarseCoordinate(latitude: 40.6782, longitude: -73.9442), origin: .device)

final class NewsWeatherInterludeTests: XCTestCase {
    // MARK: Gathering and the location gate

    func testWithoutAnAreaLocationProvidersAreNeverCalledAndAreReportedOmitted() async {
        let weather = SpyProvider(kind: .weather), local = SpyProvider(kind: .localNews), national = SpyProvider(kind: .news)
        let gatherer = BroadcastFactGatherer(providers: [weather, local, national])
        let (facts, counts) = await gatherer.gather(FactRequest(now: t0, area: nil))
        XCTAssertTrue(weather.calls.isEmpty, "no consent: weather provider not called")
        XCTAssertTrue(local.calls.isEmpty, "no consent: local news provider not called")
        XCTAssertEqual(national.calls.count, 1)
        XCTAssertEqual(counts.omittedNoLocation, 2)
        XCTAssertEqual(facts.map(\.kind), [.news], "nothing invented for the omitted kinds")
    }

    func testNationalNewsNeverSeesTheAreaAndLocalNewsDoes() async {
        let local = SpyProvider(kind: .localNews), national = SpyProvider(kind: .news)
        _ = await BroadcastFactGatherer(providers: [local, national]).gather(FactRequest(now: t0, area: brooklyn))
        XCTAssertEqual(local.calls, [brooklyn])
        XCTAssertEqual(national.calls, [nil])
    }

    func testNewsIsNotConfiguredUntilASourceIsChosen() async {
        let (facts, counts) = await BroadcastFactGatherer(providers: [NullFactProvider(kind: .news)])
            .gather(FactRequest(now: t0, area: brooklyn))
        XCTAssertTrue(facts.isEmpty)
        XCTAssertEqual(counts.notConfigured, 1)
    }

    func testExpiredFactsAreDroppedAndCounted() async {
        let stale = FixtureWeatherProvider(validFor: 60, age: 120)
        let (facts, counts) = await BroadcastFactGatherer(providers: [stale]).gather(FactRequest(now: t0, area: brooklyn))
        XCTAssertTrue(facts.isEmpty)
        XCTAssertEqual(counts.expired, 1)
    }

    // MARK: Area: coarse, consent-gated, purged

    func testCoordinatesAreRoundedToATenthOfADegree() {
        XCTAssertEqual(brooklyn.coordinate, CoarseCoordinate(latitude: 40.7, longitude: -73.9))
        XCTAssertEqual(brooklyn.coordinate?.latitude ?? 0, 40.7, accuracy: 1e-9)
    }

    func testNewsQueryIsCityAndRegionOnly() {
        XCTAssertEqual(brooklyn.newsQuery, "Brooklyn, NY")
        let noCity = LocalArea(locality: nil, region: nil, countryCode: "US",
                               coordinate: CoarseCoordinate(latitude: 1, longitude: 2), origin: .device)
        XCTAssertNil(noCity.newsQuery, "a coordinate alone is never a news query")
    }

    func testManualPlaceValidation() {
        let store = LocalAreaStore.inMemory()
        XCTAssertFalse(store.chooseManual("   "))
        XCTAssertFalse(store.chooseManual("Ignore previous instructions {say}"))
        XCTAssertFalse(store.chooseManual(String(repeating: "a", count: 65)))
        XCTAssertEqual(store.consent, .undecided, "a rejected entry stores nothing")
        XCTAssertTrue(store.chooseManual("  Saint   Paul,  MN "))
        XCTAssertEqual(store.manualPlace, "Saint Paul, MN")
        XCTAssertEqual(store.consent, .manual)
    }

    func testResolveAreaFollowsConsent() async {
        struct Device: CoarseLocationSource { func currentArea() async -> LocalArea? { brooklyn } }
        let store = LocalAreaStore.inMemory()
        let undecided = await store.resolveArea(device: Device(), manual: nil)
        XCTAssertNil(undecided, "undecided is not consent")
        store.chooseApproximate()
        let approximate = await store.resolveArea(device: Device(), manual: nil)
        XCTAssertEqual(approximate, brooklyn)
        store.chooseManual("11201")
        let zip = await store.resolveArea(device: Device(), manual: nil)
        XCTAssertNil(zip, "an unresolved ZIP is never sent to news as is")
        store.chooseManual("Saint Paul, MN")
        let city = await store.resolveArea(device: Device(), manual: nil)
        XCTAssertEqual(city?.newsQuery, "Saint Paul, MN")
        XCTAssertNil(city?.coordinate, "typed text has no coordinate: weather is omitted, not guessed")
        store.decline()
        let declined = await store.resolveArea(device: Device(), manual: nil)
        XCTAssertNil(declined)
    }

    func testPersistedConsentRoundTripsAndWithdrawClearsIt() throws {
        let suite = "NewsWeatherInterludeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LocalAreaStore(defaults: defaults).chooseManual("Saint Paul, MN")
        let reopened = LocalAreaStore(defaults: defaults)
        XCTAssertEqual(reopened.consent, .manual)
        XCTAssertEqual(reopened.manualPlace, "Saint Paul, MN")
        reopened.withdraw()
        XCTAssertEqual(LocalAreaStore(defaults: defaults).consent, .declined)
        XCTAssertNil(LocalAreaStore(defaults: defaults).manualPlace)
        defaults.set("bogus", forKey: LocalAreaStore.consentKey)
        XCTAssertEqual(LocalAreaStore(defaults: defaults).consent, .undecided, "unreadable fails closed")
    }

    func testPurgeAllWithdrawsLocation() async {
        let feed = NarrationPurgeFeed()
        let store = LocalAreaStore.inMemory()
        store.chooseManual("Saint Paul, MN")
        store.remember(brooklyn)
        let task = store.listen(to: feed)
        defer { task.cancel() }
        feed.publish(.items([UUID()]))
        feed.publish(.all)
        for _ in 0..<200 where store.consent != .declined { await Task.yield() }
        XCTAssertEqual(store.consent, .declined)
        XCTAssertNil(store.manualPlace)
        XCTAssertNil(store.area)
    }

    // MARK: Lines: fact fields only, capped, credited

    private func weatherFact(expires: TimeInterval = 900, _ w: WeatherFact = WeatherFact(
        condition: "Partly Cloudy", temperature: 54, unit: .fahrenheit, high: 61, low: 47, precipitationChancePercent: 60)) -> BroadcastFact {
        BroadcastFact(kind: .weather, payload: .weather(w), observedAt: t0, expiresAt: t0.addingTimeInterval(expires),
                      attribution: .appleWeather(legalURL: nil))
    }

    private func headline(_ text: String, _ outlet: String = "NPR", kind: BroadcastFactKind = .news) -> BroadcastFact {
        BroadcastFact(kind: kind, payload: .headline(HeadlineFact(headline: text, outlet: outlet)), observedAt: t0,
                      expiresAt: t0.addingTimeInterval(3600),
                      attribution: FactAttribution(providerID: "fixture", spokenName: outlet, requiresSpokenCredit: true))
    }

    func testOrdinaryWeatherLineSaysOnlyTheFactAndCreditsIt() {
        var counts = FactCueCounts()
        let fact = weatherFact()
        let line = FactInterludeComposer().extraLine(from: [fact], airBy: t0, counts: &counts)
        XCTAssertEqual(line?.text, "It's 54 degrees and partly cloudy here, says Apple Weather.")
        XCTAssertEqual(line?.provenance, fact.provenance)
        XCTAssertEqual(line?.expiresAt, fact.expiresAt)
        XCTAssertLessThanOrEqual(line?.estimatedSeconds ?? 99, 5)
        XCTAssertFalse(line?.text.contains("Brooklyn") ?? true, "never names the place")
        let other = FactInterludeComposer().extraLine(from: [fact], airBy: t0, variant: 2, counts: &counts)
        XCTAssertEqual(other?.text, "Partly cloudy and 54 degrees right now, says Apple Weather.")
    }

    func testAWeatherLineThatWouldAirAfterItsExpiryIsNotOffered() {
        var counts = FactCueCounts()
        XCTAssertNil(FactInterludeComposer().extraLine(from: [weatherFact(expires: 60)], airBy: t0.addingTimeInterval(61),
                                                       counts: &counts))
        XCTAssertEqual(counts.expired, 1)
    }

    func testAnOddConditionIsNotSpoken() {
        var counts = FactCueCounts()
        let odd = weatherFact(WeatherFact(condition: "{inject} now", temperature: 1, unit: .celsius))
        XCTAssertNil(FactInterludeComposer().extraLine(from: [odd], airBy: t0, counts: &counts))
    }

    private func summary(_ text: String, _ outlet: String = "the Star Tribune", kind: BroadcastFactKind = .localNews) -> BroadcastFact {
        BroadcastFact(kind: kind, payload: .headlineSummary(HeadlineSummary(summary: text, outlet: outlet)), observedAt: t0,
                      expiresAt: t0.addingTimeInterval(3600), attribution: .gdelt(outlet: outlet))
    }

    func testBriefingInterludeIsWeatherOnlyThisRoundAndFitsFortyFiveSeconds() {
        var counts = FactCueCounts()
        let facts = [headline("Senate passes budget bill after late vote - NPR"),
                     summary("Minneapolis council backs new bike lanes downtown"),
                     weatherFact()]
        let lines = FactInterludeComposer().briefingLines(from: facts, airBy: t0, counts: &counts)
        XCTAssertEqual(lines.map(\.text),
                       ["From Apple Weather: it's 54 degrees and partly cloudy here, with a high of 61 and a low of 47 today. 60 percent chance of rain."],
                       "news airs in ordinary breaks only this round")
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.estimatedSeconds }, DJCadence().maxBriefingBreakSeconds)
        XCTAssertEqual(counts.kept, 1)
    }

    func testOrdinaryBreakNewsLineIsAParaphraseNamingTheOutletAndNeverTheRawHeadline() {
        var counts = FactCueCounts()
        let raw = headline("Minneapolis council approves new bike lanes on Hennepin Avenue", "the Star Tribune", kind: .localNews)
        XCTAssertNil(FactInterludeComposer().extraLine(from: [raw], airBy: t0, variant: 1, counts: &counts),
                     "a headline with no validated paraphrase is never spoken")
        XCTAssertEqual(counts.notParaphrased, 1)
        let fact = summary("Minneapolis council backs bike lanes for Hennepin Avenue")
        let line = FactInterludeComposer().extraLine(from: [raw, fact, weatherFact()], airBy: t0, variant: 1, counts: &counts)
        XCTAssertEqual(line?.text, "From the Star Tribune: Minneapolis council backs bike lanes for Hennepin Avenue.")
        XCTAssertEqual(line?.fields, [.outlet, .summary])
        XCTAssertEqual(line?.factID, fact.id)
        XCTAssertLessThanOrEqual(line?.estimatedSeconds ?? 99, 7)
        XCTAssertEqual(FactInterludeComposer().extraLine(from: [fact, weatherFact()], airBy: t0, variant: 0, counts: &counts)?.fields.first,
                       .temperature, "even variants lead with weather, odd with news")
        XCTAssertNil(FactInterludeComposer().extraLine(from: [summary("Bridge <b>reopens</b> today in town")], airBy: t0,
                                                       variant: 1, counts: &counts), "markup: dropped, not stripped")
        XCTAssertNil(FactInterludeComposer().extraLine(from: [summary(Array(repeating: "word", count: 30).joined(separator: " "))],
                                                       airBy: t0, variant: 1, counts: &counts), "over the news-line cap")
    }

    // MARK: Through the existing seam: on-device, expiring, dropped at the take

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value: Date
        init(_ d: Date) { value = d }
        var now: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    func testFactExtraLineCarriesProvenanceAndExpiryAndStaysOnTheDevice() {
        let source = FactExtraLineSource(airLead: 60, now: { t0 })
        source.update([weatherFact()])
        var writer = DJScriptWriter(cadence: DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 9, tone: .warm,
                                    shapes: .init(weights: [.comingUpOnly: 1]))
        writer.extraLineSource = source
        let breaks = writer.plan(tracks: djTracks(12, origin: .catalog), briefing: nil, hour: 10).breaks.filter { $0.isPickedShape }
        let factCues = breaks.flatMap(\.cues).filter { FactProvenance.isFact($0.provenance) }
        XCTAssertFalse(factCues.isEmpty, "the weather line is planned")
        for b in breaks {
            for cue in b.cues where FactProvenance.isFact(cue.provenance) {
                XCTAssertEqual(cue.expiresAt, t0.addingTimeInterval(900))
                XCTAssertEqual(FactProvenance.kind(of: cue.provenance), .weather)
                XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: b.attributions[cue.id]),
                               "a fact line never goes to a voice route that leaves the device")
                XCTAssertEqual(b.optionalCueIDs.first, cue.id, "dropped first to fit the 12 s cap")
            }
        }
    }

    /// Sentinel's #401 B1: a news or weather clip carries no source id, so no purge could find it
    /// in the narration cache. It is never written there (nor read), and an ordinary line still is.
    func testAFactLineIsNeverCachedSoPurgesCannotMissIt() async throws {
        let cache = InMemoryAudioCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let line = try XCTUnwrap(FactInterludeComposer().extraLine(
            from: [summary("Brooklyn bridge open again after repairs", "the Brooklyn Paper")], airBy: t0, variant: 1,
            counts: &FactCueCounts.scratch))
        var fact = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: line.text, estimatedSeconds: 3,
                                maxSeconds: 20, sourceItemID: nil, source: nil, provenance: line.provenance)
        fact.expiresAt = line.expiresAt
        XCTAssertFalse(VoiceRenderer.mayUseCache(fact))
        var factNoExpiry = fact; factNoExpiry.expiresAt = nil
        XCTAssertFalse(VoiceRenderer.mayUseCache(factNoExpiry), "fact provenance alone keeps it out of the cache")
        for _ in 0..<2 {
            guard case .success(let clip) = await renderer.render(fact, userID: "u", stationID: "s", attribution: .presenter)
            else { return XCTFail("renders on the device") }
            XCTAssertEqual(clip.attempts.last?.result, .rendered, "rendered fresh, never a cache hit")
        }
        var count = await cache.fileCount()
        XCTAssertEqual(count.files, 0, "nothing from a fact line is on disk for a purge to miss")

        // An expiring line with no source id and no fact provenance is held back the same way.
        var untagged = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "Rain moves in around six.",
                                    estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        untagged.expiresAt = t0.addingTimeInterval(900)
        XCTAssertFalse(VoiceRenderer.mayUseCache(untagged))

        // An ordinary line, and an expiring personal update that a purge can find, still cache.
        let plain = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "Here's the next one.",
                                 estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        var personal = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "Your dentist is at four.",
                                    estimatedSeconds: 2, maxSeconds: 20, sourceItemID: UUID(), source: nil, provenance: nil)
        personal.expiresAt = t0.addingTimeInterval(900)
        XCTAssertTrue(VoiceRenderer.mayUseCache(plain))
        XCTAssertTrue(VoiceRenderer.mayUseCache(personal))
        _ = await renderer.render(plain, userID: "u", stationID: "s", attribution: .presenter)
        count = await cache.fileCount()
        XCTAssertEqual(count.files, 1)
    }

    /// Sentinel's #401 n1 (-Echo): the read path. A clip already cached under the same key (same
    /// text and voice, from an ordinary line) is never handed to a fact line: it is rendered fresh,
    /// so a stale clip a purge might have missed can never air as news or weather.
    func testAFactLineNeverReadsAClipCachedUnderTheSameKey() async throws {
        let cache = InMemoryAudioCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let line = try XCTUnwrap(FactInterludeComposer().extraLine(
            from: [summary("Brooklyn bridge open again after repairs", "the Brooklyn Paper")], airBy: t0, variant: 1,
            counts: &FactCueCounts.scratch))
        let plain = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: line.text, estimatedSeconds: 3,
                                 maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        guard case .success(let seeded) = await renderer.render(plain, userID: "u", stationID: "s", attribution: .presenter)
        else { return XCTFail("the ordinary line renders") }
        XCTAssertEqual(seeded.attempts.last?.result, .rendered)
        guard case .success(let again) = await renderer.render(plain, userID: "u", stationID: "s", attribution: .presenter)
        else { return XCTFail("the ordinary line renders") }
        XCTAssertEqual(again.attempts.last?.result, .cacheHit, "control: the same text is in the cache under that key")

        var fact = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: line.text, estimatedSeconds: 3,
                                maxSeconds: 20, sourceItemID: nil, source: nil, provenance: line.provenance)
        fact.expiresAt = line.expiresAt
        guard case .success(let clip) = await renderer.render(fact, userID: "u", stationID: "s", attribution: .presenter)
        else { return XCTFail("the fact line renders on the device") }
        XCTAssertEqual(clip.attempts.last?.result, .rendered, "a fact line never takes the cached clip")
        XCTAssertFalse(clip.attempts.contains { $0.result == .cacheHit })
        var factNoExpiry = fact; factNoExpiry.expiresAt = nil
        guard case .success(let clip2) = await renderer.render(factNoExpiry, userID: "u", stationID: "s", attribution: .presenter)
        else { return XCTFail("renders") }
        XCTAssertEqual(clip2.attempts.last?.result, .rendered, "fact provenance alone keeps the read out")
    }

    /// Sentinel's #411 n1 (-Echo): the expiring-no-source rule on the read path. An ordinary line
    /// seeds the cache; the same text as an expiring line with no source id (no fact provenance)
    /// must render fresh, never take that clip.
    func testAnExpiringLineWithNoSourceNeverReadsACachedClip() async throws {
        let cache = InMemoryAudioCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let text = "Rain moves in around six."
        let plain = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text, estimatedSeconds: 2,
                                 maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        _ = await renderer.render(plain, userID: "u", stationID: "s", attribution: .presenter)
        guard case .success(let again) = await renderer.render(plain, userID: "u", stationID: "s", attribution: .presenter)
        else { return XCTFail("the ordinary line renders") }
        XCTAssertEqual(again.attempts.last?.result, .cacheHit, "control: the same text is in the cache under that key")

        var untagged = plain; untagged.expiresAt = t0.addingTimeInterval(900)
        guard case .success(let clip) = await renderer.render(untagged, userID: "u", stationID: "s", attribution: .presenter)
        else { return XCTFail("the expiring line renders") }
        XCTAssertEqual(clip.attempts.last?.result, .rendered, "an expiring line with no source never takes the cached clip")
        XCTAssertFalse(clip.attempts.contains { $0.result == .cacheHit })
    }

    /// Sentinel's #411 n1 (-Echo): each rule on the write path, on its own. Rendering the cue must
    /// store nothing, checked on the store itself rather than through a later read.
    func testEachCacheRuleKeepsItsLineOutOfTheStore() async throws {
        let line = try XCTUnwrap(FactInterludeComposer().extraLine(
            from: [summary("Brooklyn bridge open again after repairs", "the Brooklyn Paper")], airBy: t0, variant: 1,
            counts: &FactCueCounts.scratch))
        // The fact rule alone: fact provenance, no expiry.
        let factNoExpiry = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: line.text,
                                        estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil,
                                        provenance: line.provenance)
        // The expiring-no-source rule alone: no provenance, an expiry, no source id.
        var untagged = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "Rain moves in around six.",
                                    estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        untagged.expiresAt = t0.addingTimeInterval(900)
        for (name, cue) in [("fact, no expiry", factNoExpiry), ("expiring, no source", untagged)] {
            let cache = InMemoryAudioCache()
            let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                         budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
            // Fry's #415 nit 2: one case failing to render still checks the other.
            guard case .success = await renderer.render(cue, userID: "u", stationID: "s", attribution: .presenter)
            else { XCTFail("\(name): renders on the device"); continue }
            let count = await cache.fileCount()
            XCTAssertEqual(count.files, 0, "\(name): nothing stored")
        }
    }

    /// Sentinel's #411 n2 (-Echo): the GDELT citation text and link are pinned (GDELT's terms).
    func testTheGDELTCitationNamesTheProjectAndLinksItsSite() {
        // Fry's #415 nit 1: the whole string, so any wording change is a reviewed test change.
        XCTAssertEqual(FactAttribution.gdeltCitation, "News data: The GDELT Project (gdeltproject.org)")
        XCTAssertEqual(FactAttribution.gdeltURL.absoluteString, "https://www.gdeltproject.org/")
    }

    func testAFactLineNeverReachesTheCloudVoiceAndVoiceRequestsHaveNoLocationField() async throws {
        let cloud = RecordingCloud()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: cloud, voice: djVoice, leavesDevice: true),
                                              VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let line = try XCTUnwrap(FactInterludeComposer().extraLine(
            from: [summary("Brooklyn bridge open again after repairs", "the Brooklyn Paper")], airBy: t0, variant: 1,
            counts: &FactCueCounts.scratch))
        var cue = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: line.text, estimatedSeconds: 3,
                               maxSeconds: 20, sourceItemID: nil, source: nil, provenance: line.provenance)
        cue.expiresAt = line.expiresAt
        let result = await renderer.render(cue, userID: "u", stationID: "s", attribution: .presenter)
        guard case .success(let clip) = result else { return XCTFail("renders on the device") }
        XCTAssertEqual(clip.audio.providerID, "device")
        XCTAssertTrue(cloud.texts.isEmpty, "the cloud route never saw the line")

        // The proxy request itself: a fixed set of fields, none of them a location.
        let transport = CapturingTransport()
        let config = try ProxyVoiceProvider.Configuration(endpoint: URL(string: "https://voice.aerodj.example/tts")!,
                                                          allowedHosts: ["voice.aerodj.example"], upstream: .elevenlabs,
                                                          sessionToken: { "t" })
        _ = try await ProxyVoiceProvider(configuration: config, transport: transport)
            .synthesize("Here's the next one.", voice: djVoice, context: RequestContext(stationID: "s", isReusableGeneric: false))
        let sent = await transport.log.requests
        let request = try XCTUnwrap(sent.first)
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(Set(body.keys), ["upstream", "voiceId", "text", "format", "stationId"])
        let banned = ["lat", "lon", "latitude", "longitude", "location", "city", "region", "zip", "postal", "coordinate", "area"]
        for key in body.keys { XCTAssertFalse(banned.contains { key.lowercased().contains($0) }, key) }
        let headers = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        for header in headers { XCTAssertFalse(banned.contains { header.contains($0) }, header) }
        XCTAssertEqual(request.url?.query, nil, "no query string either")
    }

    private func factBreak(afterTrack k: Int, expires: Date, kind: BroadcastFactKind = .weather) -> DJBreak {
        let opener = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "That was Song \(k).",
                                  estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        var fact = NarrationCue(id: UUID(), order: 1, group: -1, kind: .transition, text: "It's 54 degrees and cloudy here.",
                                estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil,
                                provenance: FactProvenance.make(kind: kind, id: UUID()))
        fact.expiresAt = expires
        let closing = NarrationCue(id: UUID(), order: 2, group: -1, kind: .transition, text: "Here's Song \(k + 1).",
                                   estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        var b = DJBreak(afterTrack: k, cues: [opener, fact, closing],
                        attributions: [opener.id: .presenter, fact.id: .presenter, closing.id: .presenter])
        b.optionalCueIDs = [fact.id]
        return b
    }

    private func ready(_ preparer: DJBreakPreparer, _ k: Int) async -> DJBreakOutcome {
        while true {
            if let r = await preparer.testResult(afterTrack: k) { return r }
            await Task.yield()
        }
    }

    func testTheTakeDropsAFactLinePastItsExpiryAndReportsCountsOnly() async {
        let clock = Clock(t0)
        let preparer = DJBreakPreparer(renderer: djRenderer(), userID: "u", stationID: "s", now: { clock.now })
        let drops = DropLog()
        await preparer.observeFactCueDrops { drops.add($0, $1) }
        await preparer.prepare(factBreak(afterTrack: 0, expires: t0.addingTimeInterval(300)), deadline: .seconds(10), onDeviceOnly: true)
        await preparer.prepare(factBreak(afterTrack: 2, expires: t0.addingTimeInterval(900)), deadline: .seconds(10), onDeviceOnly: true)
        guard case .ready = await ready(preparer, 0), case .ready = await ready(preparer, 2) else { return XCTFail("prepared") }
        clock.now = t0.addingTimeInterval(600)   // the first break's weather is now stale
        guard case .ready(let late) = await preparer.takeBreak(afterTrack: 0) else { return XCTFail("rest of break airs") }
        XCTAssertEqual(late.cues.count, 2)
        XCTAssertFalse(late.cues.contains { FactProvenance.isFact($0.provenance) }, "never aired late")
        XCTAssertEqual(late.clips.count, 2)
        guard case .ready(let fresh) = await preparer.takeBreak(afterTrack: 2) else { return XCTFail("fresh break airs") }
        XCTAssertEqual(fresh.cues.count, 3, "a fact still true airs")
        XCTAssertEqual(drops.all.map(\.0), [0])
        XCTAssertEqual(drops.all.first?.1, FactCueDropCounts(expired: 1, notAllowed: 0, kept: 2))
    }

    func testTheTakeDropsALocalFactLineOnceLocationIsWithdrawn() async {
        let store = LocalAreaStore.inMemory()
        store.chooseApproximate()
        let preparer = DJBreakPreparer(renderer: djRenderer(), userID: "u", stationID: "s", now: { t0 })
        await preparer.setFactCueGate { store.allowsFactCue($0) }
        await preparer.prepare(factBreak(afterTrack: 0, expires: t0.addingTimeInterval(900)), deadline: .seconds(10), onDeviceOnly: true)
        await preparer.prepare(factBreak(afterTrack: 2, expires: t0.addingTimeInterval(900), kind: .news), deadline: .seconds(10),
                               onDeviceOnly: true)
        guard case .ready = await ready(preparer, 0), case .ready = await ready(preparer, 2) else { return XCTFail("prepared") }
        store.withdraw()
        guard case .ready(let b0) = await preparer.takeBreak(afterTrack: 0) else { return XCTFail("rest airs") }
        XCTAssertEqual(b0.cues.count, 2, "weather needs location: dropped")
        guard case .ready(let b2) = await preparer.takeBreak(afterTrack: 2) else { return XCTFail("airs") }
        XCTAssertEqual(b2.cues.count, 3, "national news does not need location")
    }

    func testWithdrawnSourceClearsTheExtraLineSource() {
        let source = FactExtraLineSource(now: { t0 })
        source.update([weatherFact()])
        let a = DJTrack(id: "a", title: "A", artist: "X"), b = DJTrack(id: "b", title: "B", artist: "Y")
        XCTAssertNotNil(source.extraLine(after: a, before: b, shape: .comingUpOnly))
        source.clear()
        XCTAssertNil(source.extraLine(after: a, before: b, shape: .comingUpOnly))
    }

    // MARK: #199 alignment: fixed templates, source-tagged fields, drop don't repair

    func testEveryTemplatePlaceholderIsAFactFieldAndAMissingFieldMakesItUnusable() {
        for template in FactLineTemplates.all {
            var rest = Substring(template)
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                let name = String(rest[rest.index(after: open)..<close])
                XCTAssertNotNil(BroadcastFactField(rawValue: name.prefix(1).lowercased() + name.dropFirst()), template)
                rest = rest[rest.index(after: close)...]
            }
        }
        XCTAssertNil(FactLineTemplates.fill(FactLineTemplates.news, [.outlet: "NPR"]), "missing summary: unusable")
        XCTAssertFalse(FactLineTemplates.all.contains { $0.contains("{headline}") }, "no template reads a headline verbatim")
        let w = WeatherFact(condition: "clear", temperature: 54, unit: .fahrenheit, high: 400, low: 47)
        var counts = FactCueCounts()
        let line = FactInterludeComposer().briefingLines(from: [weatherFact(expires: 900, w)], airBy: t0, counts: &counts).first
        XCTAssertEqual(line?.text, "From Apple Weather: it's 54 degrees and clear here.",
                       "an implausible high drops the high-and-low template; the low is not said alone")
        XCTAssertEqual(line?.fields, [.source, .temperature, .condition])
    }

    // MARK: The app asks for approximate, when-in-use location with the shared copy

    func testAppDeclaresWhenInUseReducedAccuracyLocationWithTheSharedCopy() throws {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: ios.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: \(LocalAreaConsentCopy.usageDescription)\n"))
        XCTAssertFalse(project.contains("NSLocationAlwaysAndWhenInUseUsageDescription"), "never Always")
        let data = try Data(contentsOf: ios.appendingPathComponent("AeroDJ/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSLocationDefaultAccuracyReduced"] as? Bool, true)
        XCTAssertNil(plist["NSLocationTemporaryUsageDescriptionDictionary"], "never asks for full accuracy")
    }
}

extension FactCueCounts {
    /// Test scratch counts.
    nonisolated(unsafe) static var scratch = FactCueCounts()
}
