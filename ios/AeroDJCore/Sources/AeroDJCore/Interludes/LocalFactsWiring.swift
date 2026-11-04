import Foundation

// #401 wiring (-Fry): the one hookup of Echo's news and weather plumbing (#200) to the live DJ.
// `AppDependencies.live` builds ONE of these; nothing here talks to CoreLocation, WeatherKit or
// a network directly (the providers and the location sources are injected), so it is all
// testable on Linux.
//
// What it wires, per #401's handoff 3:
// - the writer's extra-line source (`source`, handed to `DJBreakSession(extraLineSource:)`);
// - the take-time fact gate (`attach(to:)` -> `DJBreakPreparer.setFactCueGate`);
// - the purge listener (`listen(to:)`: `LocalAreaStore.listen(to:)`, plus clearing `source`);
// - the refresh (`refreshIfDue()` -> `FactRefresh.run`), at most once per `interval`.
// Sentinel's notes on #401: N1 is the writer's fail-closed `DJExtraLine.plannedProvenance`; N2,
// withdrawal and purge-all also empty the source and provider caches, and a refresh re-checks
// before handing facts over; N3, separate Weather and News switches, re-read at every take.
//
// Off by default, fail closed (Sentinel, #410): the Weather and News switches start off and
// turning one on is the opt-in. With both off nothing is fetched and no location is read. The
// location prompt comes only after weather or local news is switched on
// (`shouldAskForLocation`). Without `.approximate` or `.manual` consent no area is resolved and no
// weather or local-news provider is called. A consent or switch change while a refresh is in
// flight discards that refresh's facts.

/// Where the location prompt lives and what the Tune card shows (`LocalFactsCopy`).
public enum LocalFactsStatus: Equatable, Sendable {
    case off
    case approximate
    case manual(String)

    public init(consent: LocationConsentState, manualPlace: String?) {
        switch consent {
        case .approximate: self = .approximate
        case .manual: self = manualPlace.map(Self.manual) ?? .off
        case .undecided, .declined: self = .off
        }
    }
}

/// #401 N2: a provider holding fetched facts in memory (GDELT's city-keyed headline cache).
/// Emptied on location or news withdrawal and on purge-all.
public protocol PurgeableFactProvider: BroadcastFactProvider {
    func purgeCache() async
}

/// The listener's two switches in Tune (#401 N3).
public enum LocalFactsSwitch: String, CaseIterable, Sendable {
    case weather
    case news

    /// "Weather" covers `.weather`; "News" covers `.localNews` and `.news`.
    public func covers(_ kind: BroadcastFactKind) -> Bool {
        switch self {
        case .weather: kind == .weather
        case .news: kind == .localNews || kind == .news
        }
    }
}

/// #401 N3 (Sentinel; -Fry): the listener's per-kind switches. Re-read at every take (the
/// fact-cue gate) and before every refresh.
///
/// Sentinel's privacy call on #410: BOTH default OFF, and turning one on is the opt-in. A fresh
/// install and an existing user with no stored value are both off. With both off nothing is
/// fetched: no weather, no news (not even national news, which still sends the IP address and
/// user agent to GDELT), and no location is read.
public final class LocalFactsToggles: @unchecked Sendable {
    public static let weatherKey = "AeroDJ.localFacts.weather"
    public static let newsKey = "AeroDJ.localFacts.news"
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var weatherOn: Bool
    private var newsOn: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        weatherOn = defaults.object(forKey: Self.weatherKey) as? Bool ?? false
        newsOn = defaults.object(forKey: Self.newsKey) as? Bool ?? false
    }

    private init(weather: Bool, news: Bool) { defaults = nil; weatherOn = weather; newsOn = news }
    /// Not persisted. Off unless told otherwise, like a fresh install.
    public static func inMemory(weather: Bool = false, news: Bool = false) -> LocalFactsToggles {
        LocalFactsToggles(weather: weather, news: news)
    }

    public var weather: Bool { lock.withLock { weatherOn } }
    public var news: Bool { lock.withLock { newsOn } }

    func set(weather: Bool) { lock.withLock { weatherOn = weather; defaults?.set(weather, forKey: Self.weatherKey) } }
    func set(news: Bool) { lock.withLock { newsOn = news; defaults?.set(news, forKey: Self.newsKey) } }

    public func isOn(_ which: LocalFactsSwitch) -> Bool {
        switch which {
        case .weather: weather
        case .news: news
        }
    }

    func set(_ which: LocalFactsSwitch, on: Bool) {
        switch which {
        case .weather: set(weather: on)
        case .news: set(news: on)
        }
    }

    public func allows(_ kind: BroadcastFactKind) -> Bool {
        switch kind {
        case .weather: weather
        case .localNews, .news: news
        default: true
        }
    }

    /// The take-time half of N3: a weather or news line airs only while its switch is on.
    public func allowsFactCue(_ cue: NarrationCue) -> Bool {
        guard let kind = FactProvenance.kind(of: cue.provenance) else { return true }
        return allows(kind)
    }
}

public final class LocalFactsWiring: @unchecked Sendable {
    /// One refresh per this many seconds at most (#401: "e.g. every 15 min while playing").
    public static let defaultInterval: TimeInterval = 15 * 60

    public let store: LocalAreaStore
    public let toggles: LocalFactsToggles
    /// The writer's extra-line source. Pass it to `DJBreakSession(extraLineSource:)`.
    public let source: FactExtraLineSource
    public let interval: TimeInterval
    private let providers: [any BroadcastFactProvider]
    private let summarizer: HeadlineSummarizer
    private let device: (any CoarseLocationSource)?
    private let manual: (any ManualPlaceResolver)?
    private let unit: @Sendable () -> TemperatureUnit
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastRefresh: Date?
    /// Bumped by every consent or toggle change and purge: an in-flight refresh from before is discarded.
    private var generation = 0

    public init(store: LocalAreaStore, toggles: LocalFactsToggles = LocalFactsToggles(),
                source: FactExtraLineSource = FactExtraLineSource(),
                providers: [any BroadcastFactProvider], summarizer: HeadlineSummarizer,
                device: (any CoarseLocationSource)?, manual: (any ManualPlaceResolver)?,
                unit: @escaping @Sendable () -> TemperatureUnit = { .fahrenheit },
                now: @escaping @Sendable () -> Date = DJBreakPreparer.systemNow,
                interval: TimeInterval = LocalFactsWiring.defaultInterval) {
        self.store = store
        self.toggles = toggles
        self.source = source
        self.providers = providers
        self.summarizer = summarizer
        self.device = device
        self.manual = manual
        self.unit = unit
        self.now = now
        self.interval = interval
    }

    public var status: LocalFactsStatus { LocalFactsStatus(consent: store.consent, manualPlace: store.manualPlace) }

    /// The take-time gate (`DJBreakPreparer.setFactCueGate`, re-read at every take like the
    /// cloud-voice consent): a fact line airs only while location consent holds for its kind
    /// (`LocalAreaStore.allowsFactCue`) AND its own switch is on (N3).
    public func attach(to preparer: DJBreakPreparer) async {
        let store = store, toggles = toggles
        await preparer.setFactCueGate { store.allowsFactCue($0) && toggles.allowsFactCue($0) }
    }

    /// Purge-all (`.all`: consent withdrawal, "delete my narration data"): `LocalAreaStore`'s own
    /// listener withdraws location, and this one empties the extra-line source and the providers'
    /// caches (N2). Keep both tasks for the app's lifetime.
    @discardableResult
    public func listen(to feed: NarrationPurgeFeed) -> [Task<Void, Never>] {
        let updates = feed.updates()
        let clearing = Task { [weak self] in
            for await purge in updates where purge == .all { await self?.consentChanged().value }
        }
        return [store.listen(to: feed), clearing]
    }

    /// The listener answered or changed the prompt (or turned it off), or purge-all: forget
    /// queued facts at once, let the next `refreshIfDue` run with the new answer, and empty every
    /// provider cache (the returned task; N2).
    @discardableResult
    public func consentChanged() -> Task<Void, Never> {
        invalidate()
        let purgeable = providers.compactMap { $0 as? any PurgeableFactProvider }
        return Task { for provider in purgeable { await provider.purgeCache() } }
    }

    /// "Turn off" in Tune: withdraw (declined, typed place and area forgotten) and clear.
    @discardableResult
    public func turnOff() -> Task<Void, Never> {
        store.withdraw()
        return consentChanged()
    }

    /// The location prompt rule (Sentinel, #410): ask ONLY right after the listener switched on a
    /// kind that needs their area (weather or local news), and only while location consent does
    /// not already hold. Never before a switch is on, and never for national news alone.
    public static func shouldAskForLocation(switchedOn kinds: Set<BroadcastFactKind>, consent: LocationConsentState) -> Bool {
        !consent.allowsLocation && kinds.contains(where: \.needsLocation)
    }

    /// `shouldAskForLocation(switchedOn:consent:)` for one Tune switch: the kinds it turned on are
    /// the ones this build has providers for (the live build has local news but no national news).
    public func shouldAskForLocation(afterSwitchingOn which: LocalFactsSwitch) -> Bool {
        toggles.isOn(which) && Self.shouldAskForLocation(switchedOn: kinds(of: which), consent: store.consent)
    }

    /// The prompt was answered or dismissed. Without location consent, a switch whose kinds all
    /// need the area ("Not now", or swiped away) goes back off: declining keeps weather and local
    /// news off. Then as `consentChanged()`.
    @discardableResult
    public func locationPromptClosed() -> Task<Void, Never> {
        if !store.consent.allowsLocation {
            for which in LocalFactsSwitch.allCases where toggles.isOn(which) {
                let kinds = kinds(of: which)
                if !kinds.isEmpty, kinds.allSatisfy(\.needsLocation) { toggles.set(which, on: false) }
            }
        }
        return consentChanged()
    }

    private func kinds(of which: LocalFactsSwitch) -> Set<BroadcastFactKind> {
        Set(providers.map(\.kind).filter(which.covers))
    }

    /// N3: the Weather switch. Off drops queued weather now (the source is refilled with the rest
    /// on the next refresh) and planned weather lines at the take.
    public func setWeather(_ on: Bool) {
        toggles.set(weather: on)
        invalidate()
    }

    /// N3: the News switch. Off also empties news providers' caches (N2: news withdrawal).
    @discardableResult
    public func setNews(_ on: Bool) -> Task<Void, Never> {
        toggles.set(news: on)
        invalidate()
        guard !on else { return Task {} }
        let purgeable = providers.compactMap { $0 as? any PurgeableFactProvider }.filter { $0.kind == .localNews || $0.kind == .news }
        return Task { for provider in purgeable { await provider.purgeCache() } }
    }

    private func invalidate() {
        lock.withLock {
            generation += 1
            lastRefresh = nil
        }
        source.clear()
    }

    public enum RefreshOutcome: Equatable, Sendable {
        /// Every switched-on kind needs the area and consent does not allow location: nothing
        /// resolved, no provider called, source emptied.
        case noConsent
        /// Weather and news both switched off (the default): nothing resolved or called, no
        /// request of any kind, source emptied.
        case allOff
        /// Refreshed less than `interval` ago.
        case notDue
        /// Consent holds but no area resolved: no provider called, source emptied.
        case noArea
        /// Consent or a switch changed while this refresh ran: its facts were discarded.
        case superseded
        /// `FactRefresh.run` ran; counts only.
        case refreshed(FactCueCounts, ParaphraseCounts)
    }

    /// One refresh if due. Switches first (#410: both off, nothing at all), then location consent
    /// for the kinds that need the area; then resolve the area (only if a switched-on kind needs
    /// it) and `FactRefresh.run` into `source` with only those providers, re-checking consent,
    /// switches and this refresh's generation just before the facts are handed over (N2).
    @discardableResult
    public func refreshIfDue() async -> RefreshOutcome {
        let toggles = toggles
        let switchedOn = providers.filter { toggles.allows($0.kind) }
        guard !switchedOn.isEmpty else {
            source.clear()
            return .allOff
        }
        let located = store.consent.allowsLocation
        var enabled = switchedOn.filter { located || !$0.kind.needsLocation }
        guard !enabled.isEmpty else {
            source.clear()
            return .noConsent
        }
        let start = now()
        let ticket: Int? = lock.withLock {
            if let last = lastRefresh, start.timeIntervalSince(last) < interval { return nil }
            lastRefresh = start
            return generation
        }
        guard let ticket else { return .notDue }
        var area: LocalArea?
        if enabled.contains(where: \.kind.needsLocation) {
            area = await store.resolveArea(device: device, manual: manual)
            if area == nil { enabled.removeAll(where: \.kind.needsLocation) }
        }
        guard !enabled.isEmpty else {
            guard isCurrent(ticket) else { return .superseded }
            source.clear()
            return .noArea
        }
        let kinds = Set(enabled.map(\.kind))
        let refresh = FactRefresh(gatherer: BroadcastFactGatherer(providers: enabled), summarizer: summarizer)
        let (counts, paraphrase) = await refresh.run(FactRequest(now: start, area: area, unit: unit()), into: source,
                                                     stillAllowed: { [self] in allowed(ticket, kinds) })
        guard allowed(ticket, kinds) else {
            source.clear()
            return .superseded
        }
        return .refreshed(counts, paraphrase)
    }

    private func isCurrent(_ ticket: Int) -> Bool { lock.withLock { generation == ticket } }

    private func allowed(_ ticket: Int, _ kinds: Set<BroadcastFactKind>) -> Bool {
        isCurrent(ticket) && kinds.allSatisfy { toggles.allows($0) && (!$0.needsLocation || store.consent.allowsLocation) }
    }
}

/// Which provider mark the player shows while a fact line plays (#401 UI handoffs 1 and 5).
/// Weather: the Apple Weather mark and legal link (a WeatherKit display requirement). Local
/// news: the GDELT citation and link (GDELT's terms). Other lines: none.
public enum FactAttributionMark: String, Equatable, Sendable {
    case appleWeather
    case gdelt

    public static func mark(for cue: NarrationCue) -> FactAttributionMark? {
        switch FactProvenance.kind(of: cue.provenance) {
        case .weather?: .appleWeather
        case .localNews?: .gdelt
        default: nil
        }
    }

    /// One per clip of `prepared`, in order, like `BreakResumeLine.lines(for:)`.
    public static func marks(for prepared: PreparedDJBreak) -> [FactAttributionMark?] {
        let byID = Dictionary(prepared.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return prepared.clips.map { byID[$0.cueID].flatMap(mark(for:)) }
    }
}

/// Tune copy for the local weather and news card. The prompt itself is `LocalAreaConsentCopy`.
public enum LocalFactsCopy {
    public static let title = "Local weather & news"
    public static let weatherToggle = "Weather"
    public static let newsToggle = "Local news"
    public static func detail(_ status: LocalFactsStatus) -> String {
        switch status {
        case .off: "Location off. The DJ never mentions where you are."
        case .approximate: "Location: approximate, only while the app is open."
        case .manual(let place): "Location: \(place)."
        }
    }
    public static let weatherLegal = "Weather legal"
    public static let forgetLocation = "Forget my location"
}
