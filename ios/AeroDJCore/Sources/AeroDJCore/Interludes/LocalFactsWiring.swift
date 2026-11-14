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
// flight cancels it (#410 n2: no later provider call or GDELT request) and discards its facts.
// Location revoked in iOS Settings counts as no location (#410 n5).

/// Where the location prompt lives and what the Tune card shows (`LocalFactsCopy`).
public enum LocalFactsStatus: Equatable, Sendable {
    case off
    case approximate
    case manual(String)
    /// #410 n5: approximate was chosen, but location is now off for the app in iOS Settings.
    case offInSettings

    public init(consent: LocationConsentState, manualPlace: String?, systemDenied: Bool = false) {
        switch consent {
        case .approximate: self = systemDenied ? .offInSettings : .approximate
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

/// #410 n1 (Sentinel; -Fry): a per-key in-memory cache with a purge epoch. `removeAll()` bumps
/// the epoch; a fetch reads `epoch` before it starts and `put` drops its result if a purge came
/// in between, so a purge during an in-flight fetch is never undone. GDELT's headline cache.
public actor PurgeableQueryCache<Value: Sendable> {
    private var entries: [String: (Date, Value)] = [:]
    public private(set) var epoch = 0
    private let limit: Int

    public init(limit: Int = 8) { self.limit = limit }

    public func get(_ key: String, now: Date, ttl: TimeInterval) -> Value? {
        guard let (at, value) = entries[key], now.timeIntervalSince(at) < ttl else { return nil }
        return value
    }

    /// Stores `value` only if no purge happened since `epoch` was read. Returns whether it stored.
    @discardableResult
    public func put(_ key: String, _ value: Value, at: Date, epoch fetchedAt: Int) -> Bool {
        guard fetchedAt == epoch else { return false }
        if entries.count > limit { entries.removeAll() }
        entries[key] = (at, value)
        return true
    }

    public func removeAll() {
        epoch += 1
        entries.removeAll()
    }

    public var isEmpty: Bool { entries.isEmpty }
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
    /// #410 n2: the refreshes in flight, cancelled by every consent or switch change and purge.
    private var inflight: Set<Task<RefreshOutcome, Never>> = []
    /// #410 n5: the app's live location authorization says no (revoked in iOS Settings).
    private var systemDenied = false

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

    public var status: LocalFactsStatus {
        LocalFactsStatus(consent: store.consent, manualPlace: store.manualPlace, systemDenied: lock.withLock { systemDenied })
    }

    /// Location consent holds AND, for approximate, iOS still allows it (#410 n5).
    public var locationUsable: Bool {
        let consent = store.consent
        return consent.allowsLocation && !(consent == .approximate && lock.withLock { systemDenied })
    }

    /// #410 n5: the app's live location authorization, re-read on foreground and from the location
    /// manager's authorization callback. Revoked: the card says so, nothing is read or fetched for
    /// weather or local news, queued facts and provider caches are emptied (the returned task).
    @discardableResult
    public func systemLocationChanged(authorized: Bool) -> Task<Void, Never> {
        let changed: Bool = lock.withLock {
            defer { systemDenied = !authorized }
            return systemDenied == authorized
        }
        guard changed else { return Task {} }
        return authorized ? { invalidate(); return Task {} }() : consentChanged()
    }

    /// The take-time gate (`DJBreakPreparer.setFactCueGate`, re-read at every take like the
    /// cloud-voice consent): a fact line airs only while location consent holds for its kind
    /// (`LocalAreaStore.allowsFactCue`, and iOS still allows it, #410 n5) AND its own switch is on (N3).
    public func attach(to preparer: DJBreakPreparer) async {
        let store = store, toggles = toggles
        await preparer.setFactCueGate { [weak self] cue in
            guard store.allowsFactCue(cue), toggles.allowsFactCue(cue) else { return false }
            guard let kind = FactProvenance.kind(of: cue.provenance), kind.needsLocation else { return true }
            return self?.locationUsable ?? false
        }
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
    public static func shouldAskForLocation(switchedOn kinds: Set<BroadcastFactKind>, consent: LocationConsentState,
                                            systemDenied: Bool = false) -> Bool {
        let usable = consent.allowsLocation && !(consent == .approximate && systemDenied)
        return !usable && kinds.contains(where: \.needsLocation)
    }

    /// `shouldAskForLocation(switchedOn:consent:)` for one Tune switch: the kinds it turned on are
    /// the ones this build has providers for (the live build has local news but no national news).
    public func shouldAskForLocation(afterSwitchingOn which: LocalFactsSwitch) -> Bool {
        toggles.isOn(which) && Self.shouldAskForLocation(switchedOn: kinds(of: which), consent: store.consent,
                                                         systemDenied: lock.withLock { systemDenied })
    }

    /// The prompt was answered or dismissed. Without location consent, a switch whose kinds all
    /// need the area ("Not now", or swiped away) goes back off: declining keeps weather and local
    /// news off. Then as `consentChanged()`.
    @discardableResult
    public func locationPromptClosed() -> Task<Void, Never> {
        if !locationUsable {
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
        let running: Set<Task<RefreshOutcome, Never>> = lock.withLock {
            generation += 1
            lastRefresh = nil
            defer { inflight = [] }
            return inflight
        }
        running.forEach { $0.cancel() }   // #410 n2: no later provider call or GDELT request from it
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
    ///
    /// #410 n2: the refresh runs as its own task, cancelled by any consent or switch change or
    /// purge (`invalidate`): the gatherer asks no further provider, GDELT sends no further rung or
    /// rate-gated request, and the generation check drops whatever came back.
    @discardableResult
    public func refreshIfDue() async -> RefreshOutcome {
        // #410 n6: the generation is taken before anything is read (switches, consent, location),
        // and the task is registered under the same check: a switch-off, withdrawal or purge at
        // any point after this line supersedes (and cancels) this refresh.
        let ticket = lock.withLock { generation }
        testBeforeTask?()
        let task = Task { [self] in await refreshBody(ticket) }
        // #487: nil in production, so this does not suspend and the insert stays where it was.
        // A test holds the gap open until a provider has withdrawn, before this task is registered.
        if let testBeforeRegister { await testBeforeRegister() }
        lock.withLock {
            inflight.insert(task)
            if generation != ticket { task.cancel() }   // invalidated before it was registered
        }
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        lock.withLock { _ = inflight.remove(task) }
        return outcome
    }

    /// Test seam (#410 n6): runs after the generation is taken, before the switches are read.
    var testAfterTicket: (@Sendable () async -> Void)?
    /// Test seam (Sentinel's #410 n6b, -Fry): runs after the generation is taken, before the
    /// refresh task exists, so a test can invalidate in the gap the late-registration cancel covers.
    var testBeforeTask: (@Sendable () -> Void)?
    /// Test seam (#487, -Echo): runs after the refresh task is created, before it is inserted
    /// into `inflight`. Nil unless a test sets it.
    var testBeforeRegister: (@Sendable () async -> Void)?

    private func refreshBody(_ ticket: Int) async -> RefreshOutcome {
        await testAfterTicket?()
        let toggles = toggles
        let switchedOn = providers.filter { toggles.allows($0.kind) }
        guard !switchedOn.isEmpty else {
            source.clear()
            return .allOff
        }
        let located = locationUsable
        var enabled = switchedOn.filter { located || !$0.kind.needsLocation }
        guard !enabled.isEmpty else {
            source.clear()
            return .noConsent
        }
        let start = now()
        let due: RefreshOutcome? = lock.withLock {
            guard generation == ticket else { return .superseded }   // n6: switched off or purged since
            if let last = lastRefresh, start.timeIntervalSince(last) < interval { return .notDue }
            lastRefresh = start
            return nil
        }
        if let due { return due }
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
        guard !Task.isCancelled, isCurrent(ticket) else {
            source.clear()
            return .superseded
        }
        let kinds = Set(enabled.map(\.kind))
        let refresh = FactRefresh(gatherer: BroadcastFactGatherer(providers: enabled), summarizer: summarizer)
        let (counts, paraphrase) = await refresh.run(FactRequest(now: start, area: area, unit: unit()), into: source,
                                                     stillAllowed: { [self] in allowed(ticket, kinds) },
                                                     shouldContinue: { [self] in isCurrent(ticket) })
        guard allowed(ticket, kinds) else {
            source.clear()
            return .superseded
        }
        return .refreshed(counts, paraphrase)
    }

    private func isCurrent(_ ticket: Int) -> Bool { lock.withLock { generation == ticket } }

    private func allowed(_ ticket: Int, _ kinds: Set<BroadcastFactKind>) -> Bool {
        isCurrent(ticket) && kinds.allSatisfy { toggles.allows($0) && (!$0.needsLocation || locationUsable) }
    }
}

/// Which provider mark the player shows while a fact line plays (#401 UI handoffs 1 and 5).
/// Weather: the Apple Weather mark and legal link (a WeatherKit display requirement). Any line
/// built from GDELT data, national `.news` or `.localNews`: the GDELT citation and link (GDELT's
/// terms; #410, keyed on the provider in the provenance, not on whether the line is local). A news
/// line with no provider recorded also cites GDELT, the only news source (fail toward citing).
/// Other lines: none.
public enum FactAttributionMark: String, Equatable, Sendable {
    case appleWeather
    case gdelt

    public static func mark(for cue: NarrationCue) -> FactAttributionMark? {
        mark(forProvenance: cue.provenance)
    }

    public static func mark(forProvenance provenance: String?) -> FactAttributionMark? {
        guard let kind = FactProvenance.kind(of: provenance) else { return nil }
        // Sentinel's #410 n8 (-Fry): the kind first for weather, so no provider ID can displace
        // the WeatherKit mark (a display requirement).
        if kind == .weather { return .appleWeather }
        let provider = FactProvenance.provider(of: provenance)
        if provider == FactAttribution.gdeltProviderID { return .gdelt }
        switch kind {
        case .news, .localNews: return provider == nil ? .gdelt : nil
        default: return nil
        }
    }

    /// One per clip of `prepared`, in order, like `BreakResumeLine.lines(for:)`.
    public static func marks(for prepared: PreparedDJBreak) -> [FactAttributionMark?] {
        let byID = Dictionary(prepared.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return prepared.clips.map { byID[$0.cueID].flatMap(mark(for:)) }
    }
}

/// The player's provider-mark state (#401; Echo's #410 nit 2, -Fry), a value so its rules run on
/// Linux. `InterludePlaybackAdapter` owns one and publishes `shown`.
/// - `stage`: the caller stages one mark per clip just before `play` or `playTalkover`; a stage
///   with no mark at all is not kept.
/// - `lineStarted`: a clip starts; its staged mark is shown only when the stage is for this break
///   and its count matches (a mismatch shows none, never the wrong one).
/// - `handOutAbandoned`: the boundary dropped the hand-out for `afterTrack`. A stage for that
///   track goes, unless that break is the one speaking. With nothing on air, no mark stays on
///   screen. A stage for another track is left for its own break.
/// - `breakNotPlayed`: a handed-out break that will not start drops its own stage.
/// - `breakEnded`: everything goes.
public struct FactAttributionStage: Equatable, Sendable {
    private struct Staged: Equatable, Sendable {
        let afterTrack: Int
        let marks: [FactAttributionMark?]
    }

    public private(set) var shown: FactAttributionMark?
    private var staged: Staged?

    public init() {}

    /// The track of the current stage, if any (tests and diagnostics).
    public var stagedTrack: Int? { staged?.afterTrack }

    public mutating func stage(_ marks: [FactAttributionMark?], afterTrack: Int) {
        staged = marks.contains { $0 != nil } ? Staged(afterTrack: afterTrack, marks: marks) : nil
    }

    /// Clip `line` (nil: not one of the break's script lines) of a break of `lineCount` clips for
    /// `afterTrack` starts.
    public mutating func lineStarted(_ line: Int?, of lineCount: Int, afterTrack: Int) {
        guard let staged, staged.afterTrack == afterTrack, staged.marks.count == lineCount,
              let line, staged.marks.indices.contains(line) else {
            shown = nil
            return
        }
        shown = staged.marks[line]
    }

    /// `afterTrack`: the hand-out that was dropped (nil: none was pending). `speakingTrack`: the
    /// break on air now, else nil.
    public mutating func handOutAbandoned(afterTrack: Int?, speakingTrack: Int?) {
        if let staged, let afterTrack, staged.afterTrack == afterTrack, staged.afterTrack != speakingTrack {
            self.staged = nil
        }
        if speakingTrack == nil { shown = nil }
    }

    /// The break for `afterTrack` was handed out and will not play (refused, revoked before its
    /// audio, or a clip would not decode): its stage goes. A mark on screen stays only while
    /// another break is speaking.
    public mutating func breakNotPlayed(afterTrack: Int, whileAnotherSpeaks: Bool) {
        if staged?.afterTrack == afterTrack { staged = nil }
        if !whileAnotherSpeaks { shown = nil }
    }

    public mutating func breakEnded() {
        staged = nil
        shown = nil
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
        case .offInSettings: "Location is off for \(AppName.display) in iOS Settings. The DJ won't mention where you are."
        }
    }
    public static let weatherLegal = "Weather legal"
    public static let forgetLocation = "Forget my location"
}
