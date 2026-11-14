import AVFoundation
import AeroDJCore
import Foundation
import OSLog

/// #525 (-Atlas): the DJ voice follows the music to AirPlay. Decisions are Core's
/// `DJSessionConfig`; this type only probes the long-form route and applies the AirPlay
/// gap-break session. Kill switch: `DJAirPlayRouteFlag` (default ON; only a fetched `false` turns
/// it off). Off AirPlay every route runs exactly today's session.
///
/// NOT device-validated. Only the owner's AirPlay, Bluetooth and CarPlay check can prove routing.
///
/// Route detection: the long-form route is the one a session with `.longFormAudio` reports in
/// `currentRoute` (Apple: that policy "routes output to the shared long-form audio output", the
/// one the Music app uses). The probe sets that category on our INACTIVE session (setting a
/// category activates nothing), reads the output port types, and puts today's category back
/// unless a gap break is about to use the long-form one. It never runs while the app's session
/// is active (a talk-over duck or a clip), so it cannot interrupt anything. The probe is local.
///
/// Network (privacy, Orion and Fry): the kill switch is fetched ONLY at the first gap break whose
/// route is AirPlay, at most once per launch (`DJAirPlayFlagFetchGate`). A listener off AirPlay
/// never makes the request. The fetch is never awaited: that break runs with the stored value
/// (on unless a previous fetch said `false`), and the answer applies from the next break.
enum DJRouteSession {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    /// One fetch per launch, only from an AirPlay gap break.
    @MainActor private static var fetchGate = DJAirPlayFlagFetchGate()

    /// A bare GET to the proxy: nothing about the route or the listener is sent. A failure keeps
    /// the stored value (fail open: on unless a fetched `false`).
    @MainActor private static func fetchFlagIfAllowed(route: LongFormRouteKind) {
        guard fetchGate.shouldFetch(route: route, at: .gapBreak) else { return }
        Task.detached(priority: .utility) {
            await DJAirPlayRouteFlag.refresh(transport: URLSessionTransport(), baseURL: DJAirPlayRouteFlag.proxyBaseURL)
        }
    }

    /// Probes the long-form route before a song starts (music not playing yet), so the
    /// preparer and the talk-over coordinator see the route for the break after it. Killed:
    /// returns at once and touches nothing. Never fetches.
    @MainActor static func probeBeforeSong() {
        guard DJAirPlayRouteFlag.isEnabled() else { return }
        _ = probe(keepLongForm: false)
    }

    /// Before a gap break's first clip (music already paused). Not AirPlay, or killed: today's
    /// session, exactly. AirPlay: the long-form category stays set, and the clip's `play()`
    /// activates it on the AirPlay route. Returns the shape for `endGapBreak`.
    /// The probe runs even when killed (local, restored at once) so the first AirPlay gap break
    /// of a launch can fetch the switch again; otherwise a `false` could never be lifted.
    @MainActor static func beginGapBreak(afterTrack k: Int) -> DJSessionShape {
        let flag = DJAirPlayRouteFlag.isEnabled()
        let (route, keptLongForm) = probe(keepLongForm: flag)
        fetchFlagIfAllowed(route: route)
        // The probe already put today's category back unless it kept the long-form one (AirPlay,
        // switch on, session inactive). A skipped probe keeps today's session.
        let shape: DJSessionShape = keptLongForm ? .longFormAirPlay : .mixDefault
        trace(.shape(shape, route, k))
        return shape
    }

    /// After `completeNarration` released the session (`.notifyOthersOnDeactivation`): back to
    /// today's category, on the inactive session, before music resumes. Only after a long-form break.
    @MainActor static func endGapBreak(_ shape: DJSessionShape) {
        guard shape == .longFormAirPlay else { return }
        restoreNormal()
    }

    /// Talk-over on AirPlay falls back to the gap break (a long-form session cannot duck).
    static var talkoverAllowed: Bool { DJLongFormRouteState.shared.talkoverAllowed }

    // MARK: Private

    /// Sets the long-form category, reads the output port types, records the route. With
    /// `keepLongForm` false (or no AirPlay) today's category is put back. Skipped while the app
    /// has activated its session: the last route stays in effect.
    @MainActor private static func probe(keepLongForm: Bool) -> (route: LongFormRouteKind, keptLongForm: Bool) {
        let flag = DJAirPlayRouteFlag.isEnabled()
        guard !TalkoverAudioSession.appActivated else {
            trace(.skipped(flag: flag))
            return (DJLongFormRouteState.shared.lastRoute, false)
        }
        let session = AVAudioSession.sharedInstance()
        let config = DJSessionConfig.airPlayGap
        var ports: [LongFormPortType] = []
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            ports = session.currentRoute.outputs.map { portType($0.portType) }
        } catch {
            log.error("route probe failed code=\((error as NSError).code, privacy: .public)")
        }
        let route = LongFormRouteKind.classify(ports)
        let changed = DJLongFormRouteState.shared.record(route)
        let keep = keepLongForm && DJSessionConfig.resolve(route: route, kind: .gap, airPlayFlag: flag) == config
        if !keep { restoreNormal() }
        let allowed = DJLongFormRouteState.shared.talkoverAllowed
        trace(.probe(route, ports, flag: flag, allowed: allowed, changed: changed))
        return (route, keep)
    }

    /// Today's normal category (`DJSessionConfig.normal`), with the default route-sharing policy
    /// named explicitly so the long-form policy cannot linger.
    private static func restoreNormal() {
        let normal = DJSessionConfig.normal
        let options: AVAudioSession.CategoryOptions = normal.options.contains(.mixWithOthers) ? [.mixWithOthers] : []
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .default, options: options)
        } catch {
            log.error("route restore failed code=\((error as NSError).code, privacy: .public)")
        }
    }

    private static func portType(_ port: AVAudioSession.Port) -> LongFormPortType {
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

    /// DIAG rows. `P0EventTrace` exists only in DEBUG and P0_DIAG builds, so plain values are
    /// passed and the host builds the row (the `TalkoverCoordinator` pattern). Codes only.
    private enum RouteTrace {
        case probe(LongFormRouteKind, [LongFormPortType], flag: Bool, allowed: Bool, changed: Bool)
        case skipped(flag: Bool)
        case shape(DJSessionShape, LongFormRouteKind, Int)
    }

    @MainActor private static func trace(_ event: RouteTrace) {
        #if AERODJ_P0_DIAG
        P0EventTraceHost.shared.talkover { trace, t in
            switch event {
            case let .probe(route, ports, flag, allowed, changed):
                _ = trace.sessionRouteProbe(route: route, ports: ports, flag: flag, talkoverAllowed: allowed,
                                            changed: changed, at: t)
            case let .skipped(flag): _ = trace.sessionRouteProbeSkipped(flag: flag, at: t)
            case let .shape(shape, route, k): _ = trace.sessionBreakShape(shape, route: route, afterTrack: k, at: t)
            }
        }
        #endif
    }
}
