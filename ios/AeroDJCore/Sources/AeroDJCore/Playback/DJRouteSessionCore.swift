import Foundation

// #525 (-Atlas), Fry's bar on #527 (agreed by Echo, Orion, Nov 14): the AirPlay path adds NO
// audio-session calls where it is not needed, compared with 4a2537b2.
// - Killed: zero extra `setCategory` / `setActive` calls on any route.
// - Switch on, not AirPlay: at most one probe-and-restore `setCategory` pair per gap break (music
//   paused), never `setActive`.
// - Talk-over (music playing): no probe at all. The pre-duck re-check reads only the route cached
//   from the last probe, the route-change mark (`routeChangeNotification`) and the app session's
//   route as it is, and never changes the category.
// The one exception outside a gap break is the launch probe (Fry's conditions): one pair at the
// FIRST song start of a launch, switch on only, never `setActive`, synchronous on the main actor
// before our first `play()` (so it cannot race MusicKit's start), with a DIAG row of raw port types.
// A listener already on AirPlay at launch is seen before the first talk-over, and the launch probe
// is where an AirPlay launch fetches the kill switch (once per launch, memory only).
//
// Why a route change downgrades the next talk-over (Apple docs, NOT device evidence): content
// without the long-form policy "remains local to the playback device even when the system is
// routing long-form ... content to AirPlay" (`RouteSharingPolicy.longFormVideo`). So the app's
// normal session (`.playback`, `.mixWithOthers`, default policy) may report the phone's speaker in
// `currentRoute` while the music plays on AirPlay, and it may not get a route-change notification
// at all when only the long-form route moves. Its `currentRoute` cannot be trusted to show
// AirPlay; only the long-form probe can. Hence the fallback: any counted route change since the
// last probe downgrades the next talk-over to a gap break (`routeChanged`), whose probe then reads
// the real long-form route.

/// The app's `AVAudioSession`, reduced to the calls this path may make. The app maps it onto
/// `AVAudioSession.sharedInstance()`; tests count every call.
@MainActor
public protocol DJAudioSessionPort: AnyObject {
    /// The output port types of the app session's `currentRoute`, read as-is (no session call).
    var currentOutputs: [LongFormPortType] { get }
    /// The app activated its session (a talk-over duck or a clip): never set a category then.
    var appActivated: Bool { get }
    /// `setCategory(.playback, mode: .default, policy:, options:)`. Failures are logged by the app.
    func setCategory(_ config: DJSessionConfig)
    /// `setActive(_:options:)`. This path never calls it; it is here so tests can count it.
    func setActive(_ active: Bool, notifyOthers: Bool)
}

/// `AVAudioSession.RouteChangeReason`, reduced in the app (codes only).
public enum DJRouteChangeReason: String, Equatable, Sendable, CaseIterable {
    case newDeviceAvailable, oldDeviceUnavailable, categoryChange, override, wakeFromSleep
    case noSuitableRouteForCategory, routeConfigurationChange, otherReason

    /// A category change is our own `setCategory` (the probe, the duck, the restore): not a route
    /// the listener picked. Every other reason counts.
    public var counts: Bool { self != .categoryChange }
}

/// The re-check mark: a counted route change since the last long-form probe. Set by the
/// notification (switch on only), consumed by the next talk-over boundary, cleared by any probe.
public struct DJRouteRecheck: Equatable, Sendable {
    public private(set) var pending = false
    public private(set) var probedThisLaunch = false

    public init() {}

    /// Returns true when the change was marked. Killed: no effect.
    @discardableResult
    public mutating func routeChanged(_ reason: DJRouteChangeReason, airPlayFlag: Bool) -> Bool {
        guard airPlayFlag, reason.counts else { return false }
        pending = true
        return true
    }

    /// A long-form probe ran: its route is the truth, the mark is spent.
    public mutating func probed() {
        pending = false
        probedThisLaunch = true
    }

    /// The pre-duck decision. Killed, or no talk-over planned: `planned`. On AirPlay (the last
    /// probe, or the session's own route if it shows it): `.hardBreak(.airPlayRoute)`. A counted
    /// route change since the last probe: `.hardBreak(.routeChanged)` (the mark is consumed; the
    /// gap break's probe reads the real route). Otherwise `planned`, unchanged.
    public mutating func talkoverBoundary(_ planned: TalkoverDecision, lastProbedRoute: LongFormRouteKind,
                                          sessionRoute: LongFormRouteKind, airPlayFlag: Bool) -> TalkoverDecision {
        guard airPlayFlag, planned.plan != nil else { return planned }
        if lastProbedRoute == .airPlay || sessionRoute == .airPlay {
            pending = false
            return .hardBreak(.airPlayRoute)
        }
        if pending {
            pending = false
            return .hardBreak(.routeChanged)
        }
        return planned
    }
}

/// The #525 route logic over a `DJAudioSessionPort`. The app owns one (main actor).
@MainActor
public final class DJRouteSessionCore {
    /// Where a probe ran.
    public enum ProbeSite: String, Equatable, Sendable { case launch, gapBreak }

    /// One long-form probe, for the DIAG row.
    public struct Probe: Equatable, Sendable {
        public var site: ProbeSite
        public var route: LongFormRouteKind
        /// The long-form route's output port types, read under the long-form category.
        public var ports: [LongFormPortType]
        /// The app session's own `currentRoute` port types, read as-is before the probe.
        public var sessionPorts: [LongFormPortType]
        public var keptLongForm: Bool
        public var changed: Bool
        /// Fetch the kill switch now (`DJAirPlayFlagFetchGate`).
        public var fetch: Bool
    }

    /// The pre-duck re-check, for the DIAG row.
    public struct Recheck: Equatable, Sendable {
        public var decision: TalkoverDecision
        /// The route the last long-form probe saw.
        public var lastProbedRoute: LongFormRouteKind
        /// The app session's own `currentRoute` port types, read as-is (no session call).
        public var sessionPorts: [LongFormPortType]
        /// A route change was marked before this boundary.
        public var marked: Bool
        public var flag: Bool
    }

    /// What a gap break did.
    public struct GapBreak: Equatable, Sendable {
        public var shape: DJSessionShape
        public var route: LongFormRouteKind
        /// Fetch the kill switch now (`DJAirPlayFlagFetchGate`).
        public var fetch: Bool
        /// Nil: no probe (killed, or the session was active).
        public var probe: Probe?
        public var skipped: Bool
        /// The app session's own `currentRoute` port types, read as-is before any probe.
        public var sessionPorts: [LongFormPortType]
    }

    public let state: DJLongFormRouteState
    public private(set) var recheck = DJRouteRecheck()
    public private(set) var fetchGate = DJAirPlayFlagFetchGate()
    private let flag: () -> Bool

    public init(state: DJLongFormRouteState = .shared, flag: @escaping () -> Bool = { DJAirPlayRouteFlag.isEnabled() }) {
        self.state = state
        self.flag = flag
    }

    /// Before a song starts (music not playing): the launch probe, once per launch, switch on,
    /// the app's session inactive. Nil: nothing was touched.
    public func probeBeforeSong(_ session: DJAudioSessionPort) -> Probe? {
        guard flag(), !recheck.probedThisLaunch, !session.appActivated else { return nil }
        return probe(session, keepLongForm: false, site: .launch)
    }

    /// Before a gap break's first clip (music paused).
    /// - Killed: no session call. The route is read as-is only for the fetch gate, so the first
    ///   AirPlay gap break of a launch can lift a `false` IF the session's own route shows AirPlay
    ///   (it may not: see the file header).
    /// - Switch on: one long-form probe. AirPlay keeps the long-form category for the clip; any
    ///   other route puts today's category back at once (one pair).
    public func beginGapBreak(_ session: DJAudioSessionPort) -> GapBreak {
        let sessionPorts = session.currentOutputs
        guard flag() else {
            let route = LongFormRouteKind.classify(sessionPorts)
            return GapBreak(shape: .mixDefault, route: route,
                            fetch: fetchGate.shouldFetch(route: route, at: .gapBreak), probe: nil, skipped: false,
                            sessionPorts: sessionPorts)
        }
        guard !session.appActivated else {
            return GapBreak(shape: .mixDefault, route: state.lastRoute, fetch: false, probe: nil, skipped: true,
                            sessionPorts: sessionPorts)
        }
        let p = probe(session, keepLongForm: true, site: .gapBreak)
        return GapBreak(shape: p.keptLongForm ? .longFormAirPlay : .mixDefault, route: p.route,
                        fetch: p.fetch, probe: p, skipped: false, sessionPorts: sessionPorts)
    }

    /// After the clip released the session: today's category back, only after a long-form break.
    public func endGapBreak(_ session: DJAudioSessionPort, shape: DJSessionShape) {
        guard shape == .longFormAirPlay else { return }
        session.setCategory(.normal)
    }

    /// The pre-duck re-check (music playing). Reads only; never a session call.
    public func talkoverDecision(_ planned: TalkoverDecision, session: DJAudioSessionPort) -> TalkoverDecision {
        talkoverRecheck(planned, session: session).decision
    }

    /// The same re-check with what it read, for the DIAG row. Reads only; never a session call.
    public func talkoverRecheck(_ planned: TalkoverDecision, session: DJAudioSessionPort) -> Recheck {
        let sessionPorts = session.currentOutputs
        let lastProbed = state.lastRoute
        let marked = recheck.pending
        let on = flag()
        let decision = recheck.talkoverBoundary(planned, lastProbedRoute: lastProbed,
                                                sessionRoute: LongFormRouteKind.classify(sessionPorts), airPlayFlag: on)
        return Recheck(decision: decision, lastProbedRoute: lastProbed, sessionPorts: sessionPorts, marked: marked, flag: on)
    }

    /// `AVAudioSession.routeChangeNotification`. Marks the next talk-over for the re-check.
    /// Killed or a category change: no effect. No session call, no network.
    @discardableResult
    public func routeChanged(_ reason: DJRouteChangeReason) -> Bool {
        recheck.routeChanged(reason, airPlayFlag: flag())
    }

    private func probe(_ session: DJAudioSessionPort, keepLongForm: Bool, site: ProbeSite) -> Probe {
        let sessionPorts = session.currentOutputs
        session.setCategory(.airPlayGap)
        let ports = session.currentOutputs
        let route = LongFormRouteKind.classify(ports)
        let changed = state.record(route)
        recheck.probed()
        let keep = keepLongForm && DJSessionConfig.resolve(route: route, kind: .gap, airPlayFlag: flag()) == .airPlayGap
        if !keep { session.setCategory(.normal) }
        let fetch = fetchGate.shouldFetch(route: route, at: site == .launch ? .songStart : .gapBreak)
        return Probe(site: site, route: route, ports: ports, sessionPorts: sessionPorts, keptLongForm: keep,
                     changed: changed, fetch: fetch)
    }
}
