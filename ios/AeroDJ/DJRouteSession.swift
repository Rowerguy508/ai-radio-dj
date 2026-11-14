import AVFoundation
import AeroDJCore
import Foundation
import OSLog

/// #525 (-Atlas): the DJ voice follows the music to AirPlay. Decisions are Core's
/// (`DJSessionConfig`, `DJRouteSessionCore`); this type maps them onto `AVAudioSession` and
/// carries the route-change observer. Kill switch: `DJAirPlayRouteFlag` (default ON; only a
/// fetched `false` turns it off). Off AirPlay every route runs exactly today's session.
///
/// NOT device-validated. Only the owner's AirPlay, Bluetooth and CarPlay check can prove routing.
///
/// Session calls (Fry's bar on #527, pinned with a counting fake in `DJSessionRouteTests`):
/// - Killed: none, on any route (exactly 4a2537b2).
/// - Switch on, not AirPlay: one probe-and-restore `setCategory` pair per gap break (music paused),
///   plus one pair at the first song start of a launch. Never `setActive`.
/// - Talk-over: no probe. The pre-duck re-check reads the cached route, the route-change mark and
///   the session's route as it is.
/// The probe sets the long-form category on our INACTIVE session (setting a category activates
/// nothing), reads the output port types, and puts today's category back unless an AirPlay gap
/// break is about to use the long-form one.
///
/// Network (privacy, Orion and Fry): the kill switch is fetched ONLY at the first gap break whose
/// route is AirPlay, at most once per launch (`DJAirPlayFlagFetchGate`). A listener off AirPlay
/// never makes the request. The fetch is never awaited: that break runs with the stored value
/// (on unless a previous fetch said `false`), and the answer applies from the next break.
enum DJRouteSession {
    fileprivate static let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    @MainActor private static let session = AppAudioSessionPort()
    @MainActor private static let core = DJRouteSessionCore()

    /// Before a song starts (music not playing yet): the launch probe, once per launch, switch on.
    /// Killed, already probed this launch, or the session active: touches nothing. Never fetches.
    @MainActor static func probeBeforeSong() {
        guard let p = core.probeBeforeSong(session) else { return }
        trace(.probe(p, flag: true, allowed: DJLongFormRouteState.shared.talkoverAllowed))
    }

    /// The pre-duck re-check (Echo's N1, Orion's route-change call): music is playing, so no probe
    /// and no session call. AirPlay (last probe or the session's own route): `airPlayRoute`. A
    /// route change since the last probe: `routeChanged`. Killed, or any other route: `planned`.
    @MainActor static func talkoverDecision(_ planned: TalkoverDecision) -> TalkoverDecision {
        core.talkoverDecision(planned, session: session)
    }

    /// `AVAudioSession.routeChangeNotification` (`DJRouteChangeObserver`). Marks the next talk-over
    /// for the re-check. Killed or our own category change: no effect. No session call, no network.
    @MainActor static func routeChanged(_ reason: DJRouteChangeReason) {
        let marked = core.routeChanged(reason)
        trace(.change(reason, marked: marked, flag: DJAirPlayRouteFlag.isEnabled()))
    }

    /// Before a gap break's first clip (music already paused). Killed: no session call (the route
    /// is read as-is, only for the fetch gate). Switch on: one probe; AirPlay keeps the long-form
    /// category and the clip's `play()` activates it on the AirPlay route. Returns the shape for
    /// `endGapBreak`.
    @MainActor static func beginGapBreak(afterTrack k: Int) -> DJSessionShape {
        let gap = core.beginGapBreak(session)
        if let p = gap.probe {
            trace(.probe(p, flag: true, allowed: DJLongFormRouteState.shared.talkoverAllowed))
        } else if gap.skipped {
            trace(.skipped(flag: true))
        }
        if gap.fetch {
            // A bare HTTPS GET on an ephemeral session (no cookies, no cache, 5 s): nothing about
            // the route or the listener is sent. A failure keeps the stored value (fail open).
            Task.detached(priority: .utility) {
                await DJAirPlayRouteFlag.refresh(transport: DJAirPlayRouteFlag.makeTransport(), baseURL: DJAirPlayRouteFlag.proxyBaseURL)
            }
        }
        trace(.shape(gap.shape, gap.route, k))
        return gap.shape
    }

    /// After `completeNarration` released the session (`.notifyOthersOnDeactivation`): back to
    /// today's category, on the inactive session, before music resumes. Only after a long-form break.
    @MainActor static func endGapBreak(_ shape: DJSessionShape) {
        core.endGapBreak(session, shape: shape)
    }

    /// Talk-over on AirPlay falls back to the gap break (a long-form session cannot duck).
    static var talkoverAllowed: Bool { DJLongFormRouteState.shared.talkoverAllowed }

    fileprivate static func portType(_ port: AVAudioSession.Port) -> LongFormPortType {
        switch port {
        case .airPlay: .airPlay
        case .bluetoothA2DP: .bluetoothA2DP
        case .bluetoothLE: .bluetoothLE
        case .bluetoothHFP: .bluetoothHFP
        case .carAudio: .carAudio
        case .builtInSpeaker: .builtInSpeaker
        case .builtInReceiver: .builtInReceiver
        case .headphones: .headphones
        case .usbAudio: .usbAudio
        case .HDMI: .hdmi
        case .lineOut: .lineOut
        default: .other
        }
    }

    fileprivate static func reason(_ raw: UInt?) -> DJRouteChangeReason {
        guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return .otherReason }
        switch reason {
        case .newDeviceAvailable: return .newDeviceAvailable
        case .oldDeviceUnavailable: return .oldDeviceUnavailable
        case .categoryChange: return .categoryChange
        case .override: return .override
        case .wakeFromSleep: return .wakeFromSleep
        case .noSuitableRouteForCategory: return .noSuitableRouteForCategory
        case .routeConfigurationChange: return .routeConfigurationChange
        default: return .otherReason
        }
    }

    /// DIAG rows. `P0EventTrace` exists only in DEBUG and P0_DIAG builds, so plain values are
    /// passed and the host builds the row (the `TalkoverCoordinator` pattern). Codes only.
    private enum RouteTrace {
        case probe(DJRouteSessionCore.Probe, flag: Bool, allowed: Bool)
        case skipped(flag: Bool)
        case shape(DJSessionShape, LongFormRouteKind, Int)
        case change(DJRouteChangeReason, marked: Bool, flag: Bool)
    }

    @MainActor private static func trace(_ event: RouteTrace) {
        #if AERODJ_P0_DIAG
        P0EventTraceHost.shared.talkover { trace, t in
            switch event {
            case let .probe(p, flag, allowed):
                _ = trace.sessionRouteProbe(route: p.route, ports: p.ports, flag: flag, talkoverAllowed: allowed,
                                            changed: p.changed, at: t)
            case let .skipped(flag): _ = trace.sessionRouteProbeSkipped(flag: flag, at: t)
            case let .shape(shape, route, k): _ = trace.sessionBreakShape(shape, route: route, afterTrack: k, at: t)
            case let .change(reason, marked, flag): _ = trace.sessionRouteChange(reason, marked: marked, flag: flag, at: t)
            }
        }
        #endif
    }
}

/// `AVAudioSession.sharedInstance()` as Core's `DJAudioSessionPort`.
@MainActor private final class AppAudioSessionPort: DJAudioSessionPort {
    var currentOutputs: [LongFormPortType] {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { DJRouteSession.portType($0.portType) }
    }

    var appActivated: Bool { TalkoverAudioSession.appActivated }

    func setCategory(_ config: DJSessionConfig) {
        let policy: AVAudioSession.RouteSharingPolicy = config.policy == .longFormAudio ? .longFormAudio : .default
        var options: AVAudioSession.CategoryOptions = []
        if config.options.contains(.mixWithOthers) { options.insert(.mixWithOthers) }
        if config.options.contains(.duckOthers) { options.insert(.duckOthers) }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: policy, options: options)
        } catch {
            DJRouteSession.log.error("route setCategory failed code=\((error as NSError).code, privacy: .public)")
        }
    }

    func setActive(_ active: Bool, notifyOthers: Bool) {
        // Never called by the #525 path (Core pins it); kept faithful for completeness.
        do {
            try AVAudioSession.sharedInstance().setActive(active, options: notifyOthers ? [.notifyOthersOnDeactivation] : [])
        } catch {
            DJRouteSession.log.error("route setActive failed code=\((error as NSError).code, privacy: .public)")
        }
    }
}

/// Orion's call (Nov 14, 3:34 PM): `AVAudioSession.routeChangeNotification` marks the next
/// talk-over for a route re-check (`DJRouteSession.routeChanged`). Owned by the talk-over
/// coordinator: `start()` adds the observer once, `stop()` and `deinit` remove it. The handler
/// reads only the reason code; no session call, no network. Killed: no effect.
@MainActor final class DJRouteChangeObserver {
    /// Written only on the main actor; read once more in `deinit` (NotificationCenter's remove is
    /// thread-safe), hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    func start() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                       object: AVAudioSession.sharedInstance(), queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { DJRouteSession.routeChanged(DJRouteSession.reason(raw)) }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
