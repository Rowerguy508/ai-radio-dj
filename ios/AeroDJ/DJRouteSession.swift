import AVFoundation
import AeroDJCore
import Foundation
import OSLog

/// #525 (-Atlas): the DJ voice follows the music to AirPlay. Decisions are Core's
/// `DJSessionConfig`; this type only probes the long-form route and applies the AirPlay
/// gap-break session. With the remote flag off (`DJAirPlayRouteFlag`, default OFF) nothing here
/// touches the audio session, so every route runs exactly today's session.
///
/// NOT device-validated. Only the owner's AirPlay, Bluetooth and CarPlay check can prove routing.
///
/// Route detection: the long-form route is the one a session with `.longFormAudio` reports in
/// `currentRoute` (Apple: that policy "routes output to the shared long-form audio output", the
/// one the Music app uses). The probe sets that category on our INACTIVE session (setting a
/// category activates nothing), reads the output port types, and puts today's category back
/// unless a gap break is about to use the long-form one. It never runs while the app's session
/// is active (a talk-over duck or a clip), so it cannot interrupt anything.
enum DJRouteSession {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    /// One flag fetch per launch.
    @MainActor private static var fetched = false

    /// Refreshes the remote flag once per launch, off the play path. A bare GET to the proxy;
    /// nothing about the route or the listener is sent. A failure keeps the stored value.
    @MainActor static func refreshFlagOnce() {
        guard !fetched else { return }
        fetched = true
        Task.detached(priority: .utility) {
            await DJAirPlayRouteFlag.refresh(transport: URLSessionTransport(), baseURL: CloudVoiceCredentialPolicy.baseURL)
        }
    }

    /// Probes the long-form route before a song starts (music not playing yet), so the
    /// preparer and the talk-over coordinator see the route for the break after it. Flag off:
    /// returns at once and touches nothing.
    @MainActor static func probeBeforeSong() {
        guard DJAirPlayRouteFlag.isEnabled() else { return }
        _ = probe(keepLongForm: false)
    }

    /// Before a gap break's first clip (music already paused). Flag off, or not AirPlay: today's
    /// session, exactly. AirPlay: the long-form category stays set, and the clip's `play()`
    /// activates it on the AirPlay route. Returns the shape for `endGapBreak`.
    @MainActor static func beginGapBreak(afterTrack k: Int) -> DJSessionShape {
        guard DJAirPlayRouteFlag.isEnabled() else { return .mixDefault }
        let route = probe(keepLongForm: true)
        let config = DJSessionConfig.resolve(route: route, kind: .gap, airPlayFlag: true)
        if config.shape != .longFormAirPlay { restoreNormal() }
        trace(.shape(config.shape, route, k))
        return config.shape
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
    @MainActor private static func probe(keepLongForm: Bool) -> LongFormRouteKind {
        let flag = DJAirPlayRouteFlag.isEnabled()
        guard !TalkoverAudioSession.appActivated else {
            trace(.skipped(flag: flag))
            return DJLongFormRouteState.shared.lastRoute
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
        return route
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
