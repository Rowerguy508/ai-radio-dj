import Foundation

// Active vs pending configuration, and when a pending change becomes active.
// Edits never touch the song that is playing: they wait for a boundary event from
// the scheduler. Privacy reductions (turning off an integration or the briefing,
// turning commentary off) are the exception and apply immediately.

/// One user-facing control. Used for per-control pending/status reporting.
public enum StationSetting: Hashable, Sendable {
    case genres, moods, energy, discovery, personality, commentary, briefing
    /// What the station is built from, and how far it reaches (Fry's rule (c): own cases,
    /// applied at the next song boundary like the other music settings).
    case seeds, reach
    case integration(StationIntegration)

    public static let all: [StationSetting] =
        [.genres, .moods, .energy, .discovery, .seeds, .reach, .personality, .commentary, .briefing]
        + StationIntegration.allCases.map(StationSetting.integration)

    /// The Station Tuner controls: everything except connections.
    public static let tuning: [StationSetting] =
        [.genres, .moods, .energy, .discovery, .seeds, .reach, .personality, .commentary, .briefing]

    func differs(_ a: StationConfiguration, _ b: StationConfiguration) -> Bool {
        switch self {
        case .genres: a.genres != b.genres
        case .moods: a.moods != b.moods
        case .energy: a.energy != b.energy
        case .discovery: a.discovery != b.discovery
        case .seeds: a.seeds != b.seeds
        case .reach: a.reach != b.reach
        case .personality: a.personality != b.personality
        case .commentary: a.commentary != b.commentary
        case .briefing: a.briefing != b.briefing
        case .integration(let i): a.requestedIntegrations.contains(i) != b.requestedIntegrations.contains(i)
        }
    }

    /// Copies this setting's value from `source` into `target`.
    func copy(from source: StationConfiguration, into target: inout StationConfiguration) {
        switch self {
        case .genres: target.genres = source.genres
        case .moods: target.moods = source.moods
        case .energy: target.energy = source.energy
        case .discovery: target.discovery = source.discovery
        case .seeds: target.seeds = source.seeds
        case .reach: target.reach = source.reach
        case .personality: target.personality = source.personality
        case .commentary: target.commentary = source.commentary
        case .briefing: target.briefing = source.briefing
        case .integration(let i):
            if source.requestedIntegrations.contains(i) { target.requestedIntegrations.insert(i) }
            else { target.requestedIntegrations.remove(i) }
        }
    }

    /// When a change from `active` to `proposed` takes effect.
    func timing(from active: StationConfiguration, to proposed: StationConfiguration) -> StationChangeTiming {
        switch self {
        case .genres, .moods, .energy, .discovery, .seeds, .reach: .nextSongBoundary
        case .commentary: proposed.commentary == .off ? .immediate : .nextSongBoundary
        case .personality: .nextDJBreak
        case .briefing: (active.briefing.enabled && !proposed.briefing.enabled) ? .immediate : .nextBriefing
        case .integration(let i): proposed.requestedIntegrations.contains(i) ? .nextBriefing : .immediate
        }
    }
}

/// When an edited setting becomes active. Every non-immediate change is active
/// no later than the next song boundary; the earlier events only let it apply sooner
/// where that cannot affect playback.
public enum StationChangeTiming: String, Codable, Sendable, Comparable {
    /// Privacy or silence reductions: applied as soon as the user makes them.
    case immediate
    /// The next DJ break that starts preparing (or the next song boundary, if sooner).
    case nextDJBreak
    /// The next briefing that is planned (or the next song boundary, if sooner).
    case nextBriefing
    /// After the song that is playing ends. Music selection for later songs only.
    case nextSongBoundary

    private var order: Int {
        switch self { case .immediate: 0; case .nextDJBreak: 1; case .nextBriefing: 2; case .nextSongBoundary: 3 }
    }
    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
}

/// Safe points supplied by the broadcast scheduler (see `StationBoundaryEventSource`).
public enum StationBoundaryEvent: Equatable, Sendable {
    /// A song ended and the next one has not started. Applies every pending change.
    case songBoundary(afterTrack: Int)
    /// The DJ break after `afterTrack` is about to start preparing. Applies `.nextDJBreak` changes.
    case djBreakWillPrepare(afterTrack: Int)
    /// A briefing is about to be planned. Applies `.nextBriefing` changes.
    case briefingWillPlan
    /// Nothing is holding a song (no queue, or playback stopped with no mid-song hold).
    /// Applies every pending change, same as a song boundary. Paused mid-song is not idle.
    case playbackIdle

    func applies(_ timing: StationChangeTiming) -> Bool {
        switch self {
        case .songBoundary, .playbackIdle: true
        case .djBreakWillPrepare: timing <= .nextDJBreak
        case .briefingWillPlan: timing == .nextBriefing || timing == .immediate
        }
    }
}

/// Whether a song is loaded on the real player. Idle Save (and going idle) apply pending
/// changes immediately; holding a song keeps them pending until the next safe boundary.
/// Paused mid-song is `.holdingSong`, not idle (including a system interruption hold).
public enum StationPlaybackActivity: Equatable, Sendable {
    case idle
    case holdingSong

    /// From real `PlaybackSnapshot.transport`, never a UI "playing" flag.
    /// Only `.stopped` is idle. `.playing`, `.paused` (user or system hold), and any
    /// future case (Atlas #109 may add `.preparing`) fail toward `.holdingSong` so
    /// Tune Save stays pending until a real boundary. Follow up the switch after #109.
    public init(transport: TransportState) {
        switch transport {
        case .stopped:
            self = .idle
        // `.preparing` (a song is starting, #109) holds too: Save must not apply mid-start.
        case .preparing, .playing, .paused:
            self = .holdingSong
        }
    }
}

/// Implemented by the broadcast scheduler (Claude, #34). Emit events only at real safe
/// points; never emit `songBoundary` for a song that is still playing.
public protocol StationBoundaryEventSource: Sendable {
    func stationBoundaryEvents() -> AsyncStream<StationBoundaryEvent>
}

/// An active-configuration change, for consumers that tune playback or DJ preparation.
public struct StationConfigurationChange: Equatable, Sendable {
    public let previous: StationConfiguration
    public let active: StationConfiguration
    public let applied: Set<StationSetting>
    /// `nil` when the change was immediate.
    public let boundary: StationBoundaryEvent?

    /// Integrations that were requested before and are not now. Consumers must stop using them now.
    public var withdrawnIntegrations: Set<StationIntegration> {
        previous.requestedIntegrations.subtracting(active.requestedIntegrations)
    }

    /// Breaks prepared under `previous` but not yet played should be discarded: they may
    /// carry withdrawn sources or briefing content, or the listener turned commentary off.
    public var invalidatesPreparedBreaks: Bool {
        !withdrawnIntegrations.isEmpty
            || (previous.briefing.enabled && !active.briefing.enabled)
            || (previous.commentary != .off && active.commentary == .off)
    }
}

/// Active + pending configuration. Pure value: survives fold/unfold, relaunch, and tests.
public struct StationConfigurationState: Codable, Equatable, Sendable {
    public private(set) var active: StationConfiguration
    public private(set) var pending: StationConfiguration?

    public init(active: StationConfiguration = .default, pending: StationConfiguration? = nil) {
        self.active = active.validated()
        let p = pending?.validated()
        self.pending = p == self.active ? nil : p
    }

    /// What the controls should display: pending if any, else active.
    public var displayed: StationConfiguration { pending ?? active }

    /// Settings whose displayed value is not active yet, with when each applies.
    public var pendingSettings: [StationSetting: StationChangeTiming] {
        guard let pending else { return [:] }
        var result: [StationSetting: StationChangeTiming] = [:]
        for setting in StationSetting.all where setting.differs(active, pending) {
            result[setting] = setting.timing(from: active, to: pending)
        }
        return result
    }

    public enum EditOutcome: Equatable, Sendable {
        /// The edit produced no change (same value, or clamped to the same value).
        case unchanged
        /// Recorded as pending; nothing active changed.
        case pending(Set<StationSetting>)
        /// Some settings applied immediately (privacy/silence reductions); the rest are pending.
        case applied(StationConfigurationChange, stillPending: Set<StationSetting>)
    }

    /// Applies `transform` to the displayed configuration, validates it, and records the result.
    @discardableResult
    public mutating func edit(_ transform: (inout StationConfiguration) -> Void) -> EditOutcome {
        let before = displayed
        var proposed = before
        transform(&proposed)
        proposed = proposed.validated()
        guard proposed != before else { return .unchanged }

        let previousActive = active
        var immediate = Set<StationSetting>()
        for setting in StationSetting.all where setting.differs(active, proposed)
            && setting.timing(from: active, to: proposed) == .immediate {
            setting.copy(from: proposed, into: &active)
            immediate.insert(setting)
        }
        pending = proposed == active ? nil : proposed
        let stillPending = Set(pendingSettings.keys)
        guard !immediate.isEmpty else { return .pending(stillPending) }
        let change = StationConfigurationChange(previous: previousActive, active: active, applied: immediate, boundary: nil)
        return .applied(change, stillPending: stillPending)
    }

    /// Promotes the pending settings that `event` allows. Returns `nil` when nothing changed.
    @discardableResult
    public mutating func apply(_ event: StationBoundaryEvent) -> StationConfigurationChange? {
        guard let pending else { return nil }
        let previousActive = active
        var applied = Set<StationSetting>()
        for (setting, timing) in pendingSettings where event.applies(timing) {
            setting.copy(from: pending, into: &active)
            applied.insert(setting)
        }
        if active == pending { self.pending = nil }
        guard !applied.isEmpty else { return nil }
        return StationConfigurationChange(previous: previousActive, active: active, applied: applied, boundary: event)
    }

    /// Promotes any `.immediate` reduction found in `pending` (briefing off, commentary off,
    /// an integration withdrawn). `edit` never leaves one there, but a decoded snapshot skips
    /// `init` and could: left pending, the next song boundary would promote it and cancel the
    /// break already prepared for that boundary. Call on load. Returns `nil` when none.
    public mutating func promotePendingReductions() -> StationConfigurationChange? {
        guard let pending else { return nil }
        let previousActive = active
        var applied = Set<StationSetting>()
        for setting in StationSetting.all where setting.differs(active, pending)
            && setting.timing(from: active, to: pending) == .immediate {
            setting.copy(from: pending, into: &active)
            applied.insert(setting)
        }
        guard !applied.isEmpty else { return nil }
        if active == pending { self.pending = nil }
        return StationConfigurationChange(previous: previousActive, active: active, applied: applied, boundary: nil)
    }

    /// Drops every pending edit. Active is untouched.
    public mutating func discardPending() { pending = nil }

    /// Undo for one setting after a failed save: restores its value from `snapshot`.
    mutating func restore(_ setting: StationSetting, from snapshot: StationConfigurationState) {
        var target = displayed
        setting.copy(from: snapshot.displayed, into: &target)
        setting.copy(from: snapshot.active, into: &active)
        pending = target == active ? nil : target
    }
}
