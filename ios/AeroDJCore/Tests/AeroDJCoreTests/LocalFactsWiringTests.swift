import XCTest
@testable import AeroDJCore

// #401 wiring (-Fry): DJBreakSession's extra-line injection, and `LocalFactsWiring` (the fact gate,
// the purge listener and `FactRefresh.run`). Fixture providers and fake location only: no
// network, no CoreLocation, no WeatherKit, no paid voice. Async tests in a @MainActor class
// (Swift 6.2 Linux test discovery).

private let w0 = Date(timeIntervalSince1970: 1_793_000_000)
private let minneapolis = LocalArea(locality: "Minneapolis", region: "MN", countryCode: "us",
                                    coordinate: CoarseCoordinate(latitude: 44.98, longitude: -93.27), origin: .device)

private final class WiringClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ d: Date) { value = d }
    var now: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

/// Fake device location: counts reads.
private final class FakeDeviceLocation: CoarseLocationSource, @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    let area: LocalArea?
    init(_ area: LocalArea?) { self.area = area }
    var reads: Int { lock.withLock { n } }
    func currentArea() async -> LocalArea? { lock.withLock { n += 1 }; return area }
}

/// Weather fixture that counts calls and can run a hook mid-gather.
private final class CountingWeather: WeatherProvider, @unchecked Sendable {
    let kind = BroadcastFactKind.weather
    private let lock = NSLock(); private var n = 0
    var duringGather: (@Sendable () -> Void)?
    let clock: WiringClock
    init(clock: WiringClock) { self.clock = clock }
    var calls: Int { lock.withLock { n } }
    func facts(for request: FactRequest) async -> FactProviderResult {
        lock.withLock { n += 1 }
        duringGather?()
        guard request.area?.coordinate != nil else { return .omitted(.noLocation) }
        return .facts([BroadcastFact(kind: .weather, payload: .weather(WeatherFact(condition: "partly cloudy", temperature: 54,
                                                                                   unit: request.unit)),
                                     observedAt: request.now, expiresAt: request.now.addingTimeInterval(1800),
                                     attribution: .appleWeather(legalURL: nil))])
    }
}

/// Local-news fixture with an in-memory cache, like GDELT's (N2). Counts calls and purges.
private final class CachingNews: NewsProvider, PurgeableFactProvider, @unchecked Sendable {
    let kind = BroadcastFactKind.localNews
    private let lock = NSLock(); private var cached: [String] = []; private var n = 0; private var purged = 0
    var calls: Int { lock.withLock { n } }
    var purges: Int { lock.withLock { purged } }
    var cacheIsEmpty: Bool { lock.withLock { cached.isEmpty } }
    func purgeCache() async { lock.withLock { cached = []; purged += 1 } }
    func facts(for request: FactRequest) async -> FactProviderResult {
        guard let city = request.area?.locality else { return .omitted(.noLocation) }
        lock.withLock { n += 1; cached.append(city) }
        return .omitted(.unavailable)
    }
}

/// National-news fixture: counts calls and records whether an area reached it.
private final class CountingNationalNews: NewsProvider, @unchecked Sendable {
    let kind = BroadcastFactKind.news
    private let lock = NSLock(); private var n = 0; private var areas = 0
    var calls: Int { lock.withLock { n } }
    var callsWithArea: Int { lock.withLock { areas } }
    func facts(for request: FactRequest) async -> FactProviderResult {
        lock.withLock { n += 1; if request.area != nil { areas += 1 } }
        return .omitted(.unavailable)
    }
}

/// An extra-line source written the legacy way: no provenance (N1).
private struct LegacyExtra: DJBreakExtraLineSource {
    let provenance: String?
    func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine? {
        provenance.map { DJExtraLine(text: "Bit of rain later.", attribution: .presenter, provenance: $0, expiresAt: nil) }
            ?? DJExtraLine(text: "Bit of rain later.", attribution: .presenter)
    }
}

@MainActor
final class LocalFactsWiringTests: XCTestCase {
    private let a = DJTrack(id: "a", title: "A", artist: "X"), b = DJTrack(id: "b", title: "B", artist: "Y")

    private func wiring(consent: LocationConsentState?, clock: WiringClock, device: FakeDeviceLocation,
                        weather: CountingWeather, extra: [any BroadcastFactProvider] = [],
                        toggles: LocalFactsToggles = .inMemory(weather: true, news: true)) -> LocalFactsWiring {
        let store = LocalAreaStore.inMemory()
        switch consent {
        case .approximate?: store.chooseApproximate()
        case .manual?: store.chooseManual("Minneapolis, MN")
        case .declined?: store.decline()
        case .undecided?, nil: break
        }
        return LocalFactsWiring(store: store, toggles: toggles, source: FactExtraLineSource(airLead: 60, now: { clock.now }),
                                providers: [weather] + extra, summarizer: HeadlineSummarizer(paraphraser: NoHeadlineParaphraser()),
                                device: device, manual: nil, now: { clock.now })
    }

    // MARK: DJBreakSession writer injection

    private func session(extra: (any DJBreakExtraLineSource)?, passIt: Bool) async -> DJBreakSession {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let preparer = DJBreakPreparer(renderer: djRenderer(), userID: "u", stationID: "s", cadence: config.cadence())
        if passIt {
            return DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 7, hour: { 14 },
                                  extraLineSource: extra)
        }
        return DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 7, hour: { 14 })
    }

    private func factCues(_ s: DJBreakSession) -> [NarrationCue] {
        s.testPlannedBreaks.values.flatMap(\.cues).filter { FactProvenance.isFact($0.provenance) }
    }

    func testWithoutAnExtraLineSourceTheSessionPlansAsBeforeWithNoFactLines() async {
        for passNil in [false, true] {
            let s = await session(extra: nil, passIt: passNil)
            XCTAssertNil(s.testWriterExtraLineSource, "default: no extra-line source")
            await s.queueStarted(djTracks(40, origin: .catalog))
            XCTAssertFalse(s.testPlannedBreaks.isEmpty, "breaks are planned")
            XCTAssertTrue(factCues(s).isEmpty, "no fact line without a source")
            await s.stop()
        }
    }

    func testTheDefaultPlanIsLineForLineTheSameWhenNilIsPassed() async {
        let implicit = await session(extra: nil, passIt: false), explicit = await session(extra: nil, passIt: true)
        await implicit.queueStarted(djTracks(30, origin: .catalog))
        await explicit.queueStarted(djTracks(30, origin: .catalog))
        func texts(_ s: DJBreakSession) -> [[String]] {
            s.testPlannedBreaks.keys.sorted().map { s.testPlannedBreaks[$0]!.cues.map(\.text) }
        }
        XCTAssertEqual(texts(implicit), texts(explicit))
        await implicit.stop(); await explicit.stop()
    }

    func testAnInjectedFactSourceReachesTheSessionWriterAndPlansOnDeviceFactLines() async {
        let source = FactExtraLineSource(airLead: 60, now: { w0 })
        source.update([BroadcastFact(kind: .weather, payload: .weather(WeatherFact(condition: "partly cloudy", temperature: 54,
                                                                                    unit: .fahrenheit)),
                                     observedAt: w0, expiresAt: w0.addingTimeInterval(900),
                                     attribution: .appleWeather(legalURL: nil))])
        let s = await session(extra: source, passIt: true)
        XCTAssertTrue(s.testWriterExtraLineSource as AnyObject === source, "the writer uses the injected source")
        await s.queueStarted(djTracks(40, origin: .catalog))
        let facts = factCues(s)
        XCTAssertFalse(facts.isEmpty, "the injected source's weather line is planned")
        for cue in facts {
            XCTAssertEqual(FactProvenance.kind(of: cue.provenance), .weather)
            XCTAssertEqual(cue.expiresAt, w0.addingTimeInterval(900))
            XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: .presenter), "on-device only")
        }
        await s.stop()
    }

    // MARK: FactRefresh.run, consent first

    func testWithoutConsentARefreshReadsNoLocationCallsNoProviderAndEmptiesTheSource() async {
        for consent: LocationConsentState in [.undecided, .declined] {
            let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
            let w = wiring(consent: consent, clock: clock, device: device, weather: weather)
            w.source.update([BroadcastFact(kind: .weather, payload: .weather(WeatherFact(condition: "sunny", temperature: 60,
                                                                                          unit: .fahrenheit)),
                                           observedAt: w0, expiresAt: w0.addingTimeInterval(900),
                                           attribution: .appleWeather(legalURL: nil))])
            let outcome = await w.refreshIfDue()
            XCTAssertEqual(outcome, .noConsent, "\(consent)")
            XCTAssertEqual(device.reads, 0, "\(consent): no location read")
            XCTAssertEqual(weather.calls, 0, "\(consent): no provider call")
            XCTAssertNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly), "\(consent): nothing offered")
            XCTAssertEqual(w.status, .off)
        }
    }

    func testWithConsentARefreshRunsIntoTheSourceAtMostOncePerInterval() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather)
        XCTAssertEqual(w.status, .approximate)
        guard case .refreshed(let counts, _) = await w.refreshIfDue() else { return XCTFail("refreshed") }
        XCTAssertEqual(counts.offered, 1)
        XCTAssertEqual(counts.omittedNoLocation + counts.unavailable + counts.expired, 0)
        XCTAssertEqual(weather.calls, 1)
        XCTAssertEqual(device.reads, 1)
        let line = w.source.extraLine(after: a, before: b, shape: .comingUpOnly)
        XCTAssertNotNil(line, "the gathered weather is offered to the writer")
        XCTAssertTrue(line?.text.contains("Apple Weather") == true)
        clock.now = w0.addingTimeInterval(LocalFactsWiring.defaultInterval - 1)
        let early = await w.refreshIfDue()
        XCTAssertEqual(early, .notDue)
        XCTAssertEqual(weather.calls, 1, "not called again inside the interval")
        clock.now = w0.addingTimeInterval(LocalFactsWiring.defaultInterval)
        guard case .refreshed = await w.refreshIfDue() else { return XCTFail("due again") }
        XCTAssertEqual(weather.calls, 2)
    }

    func testAConsentChangeMakesTheNextRefreshDueAtOnce() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather)
        _ = await w.refreshIfDue()
        w.consentChanged()
        XCTAssertNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly), "queued facts forgotten")
        guard case .refreshed = await w.refreshIfDue() else { return XCTFail("runs at once after a change") }
        XCTAssertEqual(weather.calls, 2)
    }

    func testWhenConsentHoldsButNoAreaResolvesNothingIsGathered() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(nil), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather)
        let outcome = await w.refreshIfDue()
        XCTAssertEqual(outcome, .noArea)
        XCTAssertEqual(weather.calls, 0)
    }

    func testTurningOffMidRefreshDiscardsWhatThatRefreshGathered() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather)
        weather.duringGather = { [w] in w.turnOff() }
        let outcome = await w.refreshIfDue()
        XCTAssertEqual(outcome, .superseded)
        XCTAssertNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly), "nothing from before the change is offered")
        XCTAssertEqual(w.store.consent, .declined)
        XCTAssertEqual(w.status, .off)
    }

    // MARK: The purge listener

    func testPurgeAllWithdrawsLocationAndEmptiesTheSource() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .manual, clock: clock, device: device, weather: weather)
        XCTAssertEqual(w.status, .manual("Minneapolis, MN"))
        let feed = NarrationPurgeFeed()
        let tasks = w.listen(to: feed)
        defer { tasks.forEach { $0.cancel() } }
        XCTAssertEqual(tasks.count, 2)
        _ = await w.refreshIfDue()
        feed.publish(.items([UUID()]))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(w.store.consent, .manual, "an item purge is not a location withdrawal")
        feed.publish(.all)
        for _ in 0..<500 where w.store.consent != .declined { await Task.yield() }
        // The clearing listener may run just after the store's.
        var offered = w.source.extraLine(after: a, before: b, shape: .comingUpOnly)
        for _ in 0..<500 where offered != nil {
            await Task.yield()
            offered = w.source.extraLine(after: a, before: b, shape: .comingUpOnly)
        }
        XCTAssertEqual(w.store.consent, .declined)
        XCTAssertNil(w.store.manualPlace)
        XCTAssertNil(offered, "queued weather is gone too")
        let after = await w.refreshIfDue()
        XCTAssertEqual(after, .noConsent)
    }

    // MARK: The take-time fact gate

    private func weatherBreak(afterTrack k: Int, kind: BroadcastFactKind = .weather) -> DJBreak {
        let opener = NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "That was Song \(k).",
                                  estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        var fact = NarrationCue(id: UUID(), order: 1, group: -1, kind: .transition, text: "It's 54 degrees here.",
                                estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil,
                                provenance: FactProvenance.make(kind: kind, id: UUID()))
        fact.expiresAt = w0.addingTimeInterval(900)
        let closing = NarrationCue(id: UUID(), order: 2, group: -1, kind: .transition, text: "Here's Song \(k + 1).",
                                   estimatedSeconds: 2, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        var brk = DJBreak(afterTrack: k, cues: [opener, fact, closing],
                          attributions: [opener.id: .presenter, fact.id: .presenter, closing.id: .presenter])
        brk.optionalCueIDs = [fact.id]
        return brk
    }

    private func ready(_ preparer: DJBreakPreparer, _ k: Int) async -> Bool {
        while true {
            if let r = await preparer.testResult(afterTrack: k) { if case .ready = r { return true }; return false }
            await Task.yield()
        }
    }

    func testTheAttachedGateDropsAWeatherLineAtTheTakeOnceTurnedOff() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather)
        let preparer = DJBreakPreparer(renderer: djRenderer(), userID: "u", stationID: "s", now: { w0 })
        await w.attach(to: preparer)
        for k in [0, 2] {
            await preparer.prepare(weatherBreak(afterTrack: k), deadline: .seconds(10), onDeviceOnly: true)
            let ok = await ready(preparer, k)
            XCTAssertTrue(ok, "prepared \(k)")
        }
        guard case .ready(let kept) = await preparer.takeBreak(afterTrack: 0) else { return XCTFail("airs") }
        XCTAssertEqual(kept.cues.count, 3, "consent holds: the weather line airs")
        XCTAssertEqual(FactAttributionMark.marks(for: kept), [nil, .appleWeather, nil], "the player shows the mark on that line")
        w.turnOff()
        guard case .ready(let dropped) = await preparer.takeBreak(afterTrack: 2) else { return XCTFail("rest airs") }
        XCTAssertEqual(dropped.cues.count, 2, "turned off: the weather line is dropped at the take")
        XCTAssertFalse(dropped.cues.contains { FactProvenance.isFact($0.provenance) })
        XCTAssertEqual(FactAttributionMark.marks(for: dropped), [nil, nil], "and no mark is shown")
    }

    // MARK: Sentinel N1: an extra line without provenance fails closed to on-device voice

    func testALegacyExtraLineWithoutProvenanceIsPlannedOnDeviceOnly() async {
        for provenance in [nil, ""] as [String?] {
            let s = await session(extra: LegacyExtra(provenance: provenance), passIt: true)
            await s.queueStarted(djTracks(40, origin: .catalog))
            let extras = s.testPlannedBreaks.values.flatMap { b in b.cues.filter { $0.text == "Bit of rain later." }.map { (b, $0) } }
            XCTAssertFalse(extras.isEmpty, "the extra line is planned")
            for (b, cue) in extras {
                XCTAssertEqual(cue.provenance, DJExtraLine.unattributedProvenance, "\(String(describing: provenance))")
                XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: b.attributions[cue.id]), "never a cloud or paid voice")
                XCTAssertFalse(FactProvenance.isFact(cue.provenance), "not a provider fact: no fact gate or mark")
            }
            await s.stop()
        }
        XCTAssertEqual(DJExtraLine(text: "x", attribution: .presenter).plannedProvenance, DJExtraLine.unattributedProvenance)
        let fact = FactProvenance.make(kind: .weather, id: UUID())
        XCTAssertEqual(DJExtraLine(text: "x", attribution: .presenter, provenance: fact, expiresAt: nil).plannedProvenance, fact,
                       "a fact line keeps its own provenance")
    }

    // MARK: Sentinel N2: withdrawal and purge-all empty the in-memory facts and caches

    func testTurningOffEmptiesTheSourceAndTheNewsCache() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let news = CachingNews()
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather, extra: [news])
        _ = await w.refreshIfDue()
        XCTAssertEqual(news.calls, 1)
        XCTAssertFalse(news.cacheIsEmpty, "the provider holds the city's headlines")
        await w.turnOff().value
        XCTAssertTrue(news.cacheIsEmpty, "withdrawal empties the news cache")
        XCTAssertNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly), "and the queued facts")
    }

    func testPurgeAllEmptiesTheNewsCacheToo() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let news = CachingNews()
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather, extra: [news])
        let feed = NarrationPurgeFeed()
        let tasks = w.listen(to: feed)
        defer { tasks.forEach { $0.cancel() } }
        _ = await w.refreshIfDue()
        XCTAssertFalse(news.cacheIsEmpty)
        feed.publish(.all)
        for _ in 0..<500 where !news.cacheIsEmpty { await Task.yield() }
        XCTAssertTrue(news.cacheIsEmpty, "purge-all empties the news cache")
    }

    func testARefreshRechecksConsentBeforeHandingFactsToTheSource() async {
        // Withdrawn mid-gather WITHOUT the wiring's own hooks (another screen calls the store):
        // FactRefresh.run's re-check keeps the facts out of the source.
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather)
        weather.duringGather = { [w] in w.store.withdraw() }
        let outcome = await w.refreshIfDue()
        XCTAssertEqual(outcome, .superseded)
        XCTAssertNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly))
        // And FactRefresh.run on its own, with a refusing check: nothing handed over.
        let source = FactExtraLineSource(airLead: 60, now: { w0 })
        let ok = CountingWeather(clock: clock)
        await FactRefresh(gatherer: BroadcastFactGatherer(providers: [ok]), summarizer: HeadlineSummarizer(paraphraser: NoHeadlineParaphraser()))
            .run(FactRequest(now: w0, area: minneapolis), into: source, stillAllowed: { false })
        XCTAssertEqual(ok.calls, 1)
        XCTAssertNil(source.extraLine(after: a, before: b, shape: .comingUpOnly))
    }

    // MARK: Sentinel N3: Weather and News switches, each re-checked at the take

    func testSwitchesDefaultOffPersistAndMapKinds() {
        let suite = "LocalFactsWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let toggles = LocalFactsToggles(defaults: defaults)
        XCTAssertFalse(toggles.weather || toggles.news, "#410: both start off; switching one on is the opt-in")
        let w = LocalFactsWiring(store: .inMemory(), toggles: toggles, providers: [], summarizer: HeadlineSummarizer(paraphraser: NoHeadlineParaphraser()),
                                 device: nil, manual: nil)
        w.setWeather(true)
        XCTAssertTrue(LocalFactsToggles(defaults: defaults).weather, "kept across launches")
        XCTAssertFalse(LocalFactsToggles(defaults: defaults).news)
        XCTAssertTrue(toggles.allows(.weather))
        XCTAssertFalse(toggles.allows(.localNews))
        _ = w.setNews(true)
        XCTAssertTrue(toggles.allows(.localNews))
        XCTAssertTrue(toggles.allows(.news))
        w.setWeather(false)
        XCTAssertFalse(LocalFactsToggles(defaults: defaults).weather, "off is kept too")
        XCTAssertFalse(toggles.allows(.weather))
    }

    // MARK: Sentinel #410: off by default; the prompt only after weather or local news is switched on

    func testFreshAndExistingUsersWithNoStoredValueStartWithBothSwitchesOff() {
        XCTAssertFalse(LocalFactsToggles.inMemory().weather || LocalFactsToggles.inMemory().news, "fresh, in memory")
        let suite = "LocalFactsWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = LocalFactsToggles(defaults: defaults)
        XCTAssertFalse(fresh.weather, "fresh install: weather off")
        XCTAssertFalse(fresh.news, "fresh install: news off")
        // An existing user: location already granted and other settings stored, but no switch value.
        let store = LocalAreaStore(defaults: defaults)
        store.chooseApproximate()
        defaults.set(true, forKey: "AeroDJ.someOtherSetting")
        let existing = LocalFactsToggles(defaults: defaults)
        XCTAssertFalse(existing.weather || existing.news, "no stored value: off, even with location granted")
        XCTAssertNil(defaults.object(forKey: LocalFactsToggles.weatherKey), "reading does not write a value")
        for kind in [BroadcastFactKind.weather, .localNews, .news] {
            XCTAssertFalse(existing.allows(kind), "\(kind)")
        }
    }

    func testWithBothSwitchesOffNothingIsFetchedNoGDELTNoWeatherNoLocation() async {
        for consent: LocationConsentState in [.undecided, .declined, .approximate, .manual] {
            let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
            let local = CachingNews(), national = CountingNationalNews()
            let w = wiring(consent: consent, clock: clock, device: device, weather: weather, extra: [local, national],
                           toggles: .inMemory())
            let outcome = await w.refreshIfDue()
            XCTAssertEqual(outcome, .allOff, "\(consent)")
            XCTAssertEqual(weather.calls, 0, "\(consent): no weather request")
            XCTAssertEqual(local.calls, 0, "\(consent): no local-news (GDELT) request")
            XCTAssertEqual(national.calls, 0, "\(consent): no national-news (GDELT) request either")
            XCTAssertEqual(device.reads, 0, "\(consent): no location read")
            XCTAssertNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly), "\(consent): nothing offered")
            clock.now = w0.addingTimeInterval(LocalFactsWiring.defaultInterval * 3)
            _ = await w.refreshIfDue()
            XCTAssertEqual(weather.calls + local.calls + national.calls + device.reads, 0, "\(consent): still nothing later")
        }
    }

    func testThePromptRule() {
        typealias W = LocalFactsWiring
        for consent: LocationConsentState in [.undecided, .declined] {
            XCTAssertTrue(W.shouldAskForLocation(switchedOn: [.weather], consent: consent), "weather on: ask (\(consent))")
            XCTAssertTrue(W.shouldAskForLocation(switchedOn: [.localNews], consent: consent), "local news on: ask")
            XCTAssertTrue(W.shouldAskForLocation(switchedOn: [.localNews, .news], consent: consent))
            XCTAssertFalse(W.shouldAskForLocation(switchedOn: [.news], consent: consent), "never for national news alone")
            XCTAssertFalse(W.shouldAskForLocation(switchedOn: [], consent: consent), "never before a switch is on")
        }
        for consent: LocationConsentState in [.approximate, .manual] {
            XCTAssertFalse(W.shouldAskForLocation(switchedOn: [.weather, .localNews], consent: consent), "already granted: no prompt")
        }
        // Per switch, with this build's providers.
        let clock = WiringClock(w0)
        let w = wiring(consent: nil, clock: clock, device: FakeDeviceLocation(minneapolis), weather: CountingWeather(clock: clock),
                       extra: [CachingNews()], toggles: .inMemory())
        XCTAssertFalse(w.shouldAskForLocation(afterSwitchingOn: .weather), "still off: no prompt")
        XCTAssertFalse(w.shouldAskForLocation(afterSwitchingOn: .news))
        w.setWeather(true)
        XCTAssertTrue(w.shouldAskForLocation(afterSwitchingOn: .weather), "weather switched on: ask")
        _ = w.setNews(true)
        XCTAssertTrue(w.shouldAskForLocation(afterSwitchingOn: .news), "local news switched on: ask")
        w.store.chooseApproximate()
        XCTAssertFalse(w.shouldAskForLocation(afterSwitchingOn: .weather), "granted: no prompt")
        // A build whose News switch has only national news never asks.
        let nationalOnly = LocalFactsWiring(store: .inMemory(), toggles: .inMemory(news: true), providers: [CountingNationalNews()],
                                            summarizer: HeadlineSummarizer(paraphraser: NoHeadlineParaphraser()), device: nil, manual: nil)
        XCTAssertFalse(nationalOnly.shouldAskForLocation(afterSwitchingOn: .news), "national news alone: no prompt")
    }

    func testNationalNewsAloneNeedsNoLocationAndSendsNoArea() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), national = CountingNationalNews()
        let w = LocalFactsWiring(store: .inMemory(), toggles: .inMemory(news: true), providers: [national],
                                 summarizer: HeadlineSummarizer(paraphraser: NoHeadlineParaphraser()), device: device, manual: nil,
                                 now: { clock.now })
        guard case .refreshed = await w.refreshIfDue() else { return XCTFail("national news runs once switched on") }
        XCTAssertEqual(national.calls, 1)
        XCTAssertEqual(national.callsWithArea, 0, "no area reaches national news")
        XCTAssertEqual(device.reads, 0, "and no location is read for it")
        _ = w.setNews(false)
        clock.now = w0.addingTimeInterval(LocalFactsWiring.defaultInterval)
        let off = await w.refreshIfDue()
        XCTAssertEqual(off, .allOff)
        XCTAssertEqual(national.calls, 1, "switched off: no GDELT request")
        // Even with location granted, national news alone reads no location.
        let granted = LocalAreaStore.inMemory()
        granted.chooseApproximate()
        let device2 = FakeDeviceLocation(minneapolis), national2 = CountingNationalNews()
        let w2 = LocalFactsWiring(store: granted, toggles: .inMemory(news: true), providers: [national2],
                                  summarizer: HeadlineSummarizer(paraphraser: NoHeadlineParaphraser()), device: device2, manual: nil)
        guard case .refreshed = await w2.refreshIfDue() else { return XCTFail("refreshed") }
        XCTAssertEqual(device2.reads, 0, "granted, but no switched-on kind needs it: no location read")
        XCTAssertEqual(national2.callsWithArea, 0)
    }

    func testDecliningThePromptTurnsTheLocationSwitchesBackOff() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let local = CachingNews()
        let w = wiring(consent: nil, clock: clock, device: device, weather: weather, extra: [local], toggles: .inMemory())
        w.setWeather(true)
        _ = w.setNews(true)
        w.store.decline()   // "Not now"
        await w.locationPromptClosed().value
        XCTAssertFalse(w.toggles.weather, "declining keeps weather off")
        XCTAssertFalse(w.toggles.news, "and local news")
        let outcome = await w.refreshIfDue()
        XCTAssertEqual(outcome, .allOff)
        XCTAssertEqual(weather.calls + local.calls + device.reads, 0)
        // Accepting keeps the switch on and refreshes.
        w.setWeather(true)
        w.store.chooseApproximate()
        await w.locationPromptClosed().value
        XCTAssertTrue(w.toggles.weather, "granted: weather stays on")
        guard case .refreshed = await w.refreshIfDue() else { return XCTFail("refreshes once granted") }
        XCTAssertEqual(weather.calls, 1)
        // A News switch with national news stays on when the prompt is declined: it needs no area.
        let national = CountingNationalNews()
        let mixed = LocalFactsWiring(store: .inMemory(), toggles: .inMemory(news: true), providers: [CachingNews(), national],
                                     summarizer: HeadlineSummarizer(paraphraser: NoHeadlineParaphraser()), device: device, manual: nil)
        mixed.store.decline()
        await mixed.locationPromptClosed().value
        XCTAssertTrue(mixed.toggles.news)
    }

    func testEachSwitchDropsItsOwnKindAtTheTakeAfterPlanning() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather)
        let preparer = DJBreakPreparer(renderer: djRenderer(), userID: "u", stationID: "s", now: { w0 })
        await w.attach(to: preparer)
        let plans: [(Int, BroadcastFactKind)] = [(0, .weather), (2, .localNews), (4, .news), (6, .weather), (8, .localNews)]
        for (k, kind) in plans {
            await preparer.prepare(weatherBreak(afterTrack: k, kind: kind), deadline: .seconds(10), onDeviceOnly: true)
            let ok = await ready(preparer, k)
            XCTAssertTrue(ok, "prepared \(k)")
        }
        w.setWeather(false)   // after planning
        guard case .ready(let b0) = await preparer.takeBreak(afterTrack: 0) else { return XCTFail("0 airs") }
        XCTAssertEqual(b0.cues.count, 2, "weather off: the weather line is dropped at the take")
        guard case .ready(let b2) = await preparer.takeBreak(afterTrack: 2) else { return XCTFail("2 airs") }
        XCTAssertEqual(b2.cues.count, 3, "news still on: the local-news line airs")
        _ = w.setNews(false)
        guard case .ready(let b4) = await preparer.takeBreak(afterTrack: 4) else { return XCTFail("4 airs") }
        XCTAssertEqual(b4.cues.count, 2, "news off: national news dropped too")
        guard case .ready(let b8) = await preparer.takeBreak(afterTrack: 8) else { return XCTFail("8 airs") }
        XCTAssertEqual(b8.cues.count, 2, "news off: local news dropped")
        w.setWeather(true)
        guard case .ready(let b6) = await preparer.takeBreak(afterTrack: 6) else { return XCTFail("6 airs") }
        XCTAssertEqual(b6.cues.count, 3, "weather back on before its take: it airs")
    }

    func testASwitchedOffKindIsNeitherGatheredNorOffered() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let news = CachingNews()
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather, extra: [news])
        _ = await w.refreshIfDue()
        XCTAssertNotNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly))
        w.setWeather(false)
        XCTAssertNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly), "queued weather dropped at once")
        guard case .refreshed = await w.refreshIfDue() else { return XCTFail("news still refreshes") }
        XCTAssertEqual(weather.calls, 1, "weather is not asked while off")
        XCTAssertEqual(news.calls, 2)
        await w.setNews(false).value
        XCTAssertTrue(news.cacheIsEmpty, "news off empties the news cache (N2)")
        let off = await w.refreshIfDue()
        XCTAssertEqual(off, .allOff)
        XCTAssertEqual(device.reads, 2, "no location read with both off")
    }

    func testTurningOffAKindMidRefreshDiscardsIt() async {
        let clock = WiringClock(w0), device = FakeDeviceLocation(minneapolis), weather = CountingWeather(clock: clock)
        let w = wiring(consent: .approximate, clock: clock, device: device, weather: weather)
        weather.duringGather = { [w] in w.setWeather(false) }
        let outcome = await w.refreshIfDue()
        XCTAssertEqual(outcome, .superseded)
        XCTAssertNil(w.source.extraLine(after: a, before: b, shape: .comingUpOnly))
    }

    // MARK: Player marks

    func testMarksFollowTheFactKind() {
        func cue(_ kind: BroadcastFactKind?) -> NarrationCue {
            NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: "x", estimatedSeconds: 1, maxSeconds: 20,
                         sourceItemID: nil, source: nil, provenance: kind.map { FactProvenance.make(kind: $0, id: UUID()) })
        }
        XCTAssertEqual(FactAttributionMark.mark(for: cue(.weather)), .appleWeather)
        XCTAssertEqual(FactAttributionMark.mark(for: cue(.localNews)), .gdelt)
        XCTAssertNil(FactAttributionMark.mark(for: cue(.news)), "no live national provider: no mark")
        XCTAssertNil(FactAttributionMark.mark(for: cue(nil)), "presenter lines: none")
    }

    func testStatusAndCopy() {
        XCTAssertEqual(LocalFactsStatus(consent: .undecided, manualPlace: nil), .off)
        XCTAssertEqual(LocalFactsStatus(consent: .declined, manualPlace: "X"), .off)
        XCTAssertEqual(LocalFactsStatus(consent: .manual, manualPlace: nil), .off, "fail closed")
        XCTAssertEqual(LocalFactsStatus(consent: .manual, manualPlace: "Duluth"), .manual("Duluth"))
        XCTAssertEqual(LocalFactsCopy.detail(.manual("Duluth")), "Location: Duluth.", "the location, not the switches")
    }
}
