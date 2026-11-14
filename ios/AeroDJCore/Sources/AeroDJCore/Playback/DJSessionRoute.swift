import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// #525 (-Atlas): the DJ voice follows the music to AirPlay.
//
// Root cause (Apple docs, code reading; NOT device evidence): `ApplicationMusicPlayer` plays like
// the built-in Music app, so AirPlay takes it on the shared long-form route. Our DJ clips play in
// the app's own session, `.playback` with `.mixWithOthers` and the default route-sharing policy,
// which stays on the system route (the phone) while long-form audio is on AirPlay.
// - `RouteSharingPolicy.longFormAudio`: "routes output to the shared long-form audio output ...
//   to play to the same output as the built-in Music and Podcast apps."
// - `RouteSharingPolicy.longFormVideo`: content not using that policy "remains local to the
//   playback device even when the system is routing long-form ... content to AirPlay."
// - `setCategory(_:mode:policy:options:)`: "You specify options only with a default routing
//   policy." So a long-form session can neither mix (`.mixWithOthers`) nor duck (`.duckOthers`),
//   and activating it interrupts other audio (Build 10 P0). Hence the narrow design below:
//   long-form ONLY for a gap break (music already paused) and ONLY while the long-form route is
//   AirPlay and the remote flag is on. Everything else is exactly the session it was before.

/// One output port type of the long-form route, reduced from `AVAudioSession.Port` in the app.
/// Types only: never a port or device name.
public enum LongFormPortType: String, Equatable, Sendable, CaseIterable {
    case airPlay, bluetoothA2DP, bluetoothLE, bluetoothHFP, carAudio
    case builtInSpeaker, builtInReceiver, headphones, usbAudio, hdmi, lineOut, other
}

/// What the long-form route is, decided from its output port types.
public enum LongFormRouteKind: String, Equatable, Sendable, CaseIterable {
    case airPlay, bluetooth, carPlay, wired, builtIn, other
    /// No probe yet, the probe was skipped, or the route reported no outputs.
    case unknown

    /// AirPlay wins when any output is AirPlay (a multi-room group can mix types).
    public static func classify(_ ports: [LongFormPortType]) -> LongFormRouteKind {
        guard !ports.isEmpty else { return .unknown }
        if ports.contains(.airPlay) { return .airPlay }
        if ports.contains(.carAudio) { return .carPlay }
        if ports.contains(where: { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0) }) { return .bluetooth }
        if ports.contains(where: { [.headphones, .usbAudio, .hdmi, .lineOut].contains($0) }) { return .wired }
        if ports.contains(where: { [.builtInSpeaker, .builtInReceiver].contains($0) }) { return .builtIn }
        return .other
    }
}

/// The kind of DJ break the session is asked for.
public enum DJBreakSessionKind: String, Equatable, Sendable, CaseIterable {
    /// The voice in the gap: music is paused (or the song ended) before the first clip.
    case gap
    /// The voice over the outro: the music keeps playing, ducked.
    case talkover
}

/// Which session a break ran with (DIAG and tests).
public enum DJSessionShape: String, Equatable, Sendable, CaseIterable {
    /// Today's normal session: `.playback`, `.default`, default policy, `[.mixWithOthers]`.
    case mixDefault
    /// Today's talk-over duck: `.playback`, `.default`, default policy, `[.duckOthers]`.
    case duckDefault
    /// #525: `.playback`, `.default`, `.longFormAudio`, no options.
    case longFormAirPlay
}

/// The audio-session configuration for one DJ break, as plain values. The app maps them onto
/// `AVAudioSession` (no iOS SDK in Core). Raw option values mirror `AVAudioSession.CategoryOptions`.
public struct DJSessionConfig: Equatable, Sendable {
    public enum Category: String, Equatable, Sendable { case playback }
    public enum Mode: String, Equatable, Sendable { case `default` }
    public enum Policy: String, Equatable, Sendable { case `default`, longFormAudio }
    public struct Options: OptionSet, Equatable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        /// `AVAudioSession.CategoryOptions.mixWithOthers` (0x1).
        public static let mixWithOthers = Options(rawValue: 0x1)
        /// `AVAudioSession.CategoryOptions.duckOthers` (0x2).
        public static let duckOthers = Options(rawValue: 0x2)
    }

    public var category: Category
    public var mode: Mode
    public var policy: Policy
    public var options: Options
    public var shape: DJSessionShape
    /// False: a talk-over must not run; the break airs in the gap instead (AirPlay).
    public var talkoverAllowed: Bool
    /// The caller asked for a talk-over and got the gap break instead.
    public var fellBackToGap: Bool

    /// Today's normal session (`AppAudioSessionConfig.mixesWithOthers`). Unchanged by #525.
    public static let normal = DJSessionConfig(category: .playback, mode: .default, policy: .default,
                                               options: AppAudioSessionConfig.mixesWithOthers ? [.mixWithOthers] : [],
                                               shape: .mixDefault, talkoverAllowed: true, fellBackToGap: false)
    /// Today's talk-over duck (`TalkoverSessionStep.setDuckCategory`). Unchanged by #525.
    public static let talkoverDuck = DJSessionConfig(category: .playback, mode: .default, policy: .default,
                                                     options: [.duckOthers], shape: .duckDefault,
                                                     talkoverAllowed: true, fellBackToGap: false)
    /// #525: the long-form gap-break session on AirPlay. No options: Apple allows none with a
    /// long-form policy.
    public static let airPlayGap = DJSessionConfig(category: .playback, mode: .default, policy: .longFormAudio,
                                                   options: [], shape: .longFormAirPlay,
                                                   talkoverAllowed: false, fellBackToGap: false)

    /// The one decision. Off AirPlay, or with the flag off, the result is today's session.
    public static func resolve(route: LongFormRouteKind, kind: DJBreakSessionKind, airPlayFlag: Bool) -> DJSessionConfig {
        let airPlay = airPlayFlag && route == .airPlay
        switch (kind, airPlay) {
        case (.gap, false): return .normal
        case (.talkover, false): return .talkoverDuck
        case (.gap, true): return .airPlayGap
        case (.talkover, true):
            var fallback = DJSessionConfig.airPlayGap
            fallback.fellBackToGap = true
            return fallback
        }
    }
}

/// The remote kill switch for the #525 AirPlay path (`djAirPlayLongForm`). Default ON (Orion,
/// Nov 14): only a fetched JSON `false` turns it off. Never fetched, a failed fetch or an
/// unreadable answer keeps the stored value, and with nothing stored the path is on. Served by the
/// aerodj-tts proxy at `GET /api/flags` from `AERODJ_DJ_AIRPLAY_LONGFORM` (only the exact string
/// `false` kills it). Fetched only from an AirPlay route (`DJAirPlayFlagFetchGate`).
public enum DJAirPlayRouteFlag {
    public static let jsonKey = "djAirPlayLongForm"
    public static let defaultsKey = "dj.remote.airPlayLongForm"
    public static let defaultValue = true
    public static let path = "api/flags"
    /// The aerodj-tts proxy (the same pinned host as the voice routes).
    public static var proxyBaseURL: URL { TesterVoice.baseURL }
    public static let timeout: TimeInterval = 5

    /// The last fetched value, else `defaultValue` (on).
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: defaultsKey) as? Bool) ?? defaultValue
    }

    /// `true` / `false` from a small JSON object; nil for anything else (the cached value stays).
    /// `JSONDecoder` reads only a JSON boolean as `Bool` (not `1` or `"true"`).
    public static func parse(_ body: Data) -> Bool? {
        guard !body.isEmpty, body.count <= 1024 else { return nil }
        return (try? JSONDecoder().decode(Body.self, from: body))?.djAirPlayLongForm
    }

    private struct Body: Decodable { let djAirPlayLongForm: Bool }

    /// A bare GET: no body, no token, no identifier, no route information.
    public static func request(baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        return request
    }

    /// Fetches the flag and stores a parsed value. A failure, a non-200 or an unreadable body
    /// leaves the stored value as it was. Returns the value now in effect.
    @discardableResult
    public static func refresh(transport: any HTTPTransport, baseURL: URL,
                               defaults: UserDefaults = .standard) async -> Bool {
        if let (data, response) = try? await transport.send(request(baseURL: baseURL)),
           response.statusCode == 200, let value = parse(data) {
            defaults.set(value, forKey: defaultsKey)
        }
        return isEnabled(defaults: defaults)
    }
}

/// When the app may fetch the kill switch (privacy, Orion and Fry, Nov 14): only at a gap break
/// whose probed long-form route is AirPlay, and at most once per launch. A listener off AirPlay
/// never makes the request; a song-start probe never does either. The probe itself is local.
public struct DJAirPlayFlagFetchGate: Equatable, Sendable {
    /// Where the route was probed.
    public enum ProbeEvent: String, Equatable, Sendable, CaseIterable {
        case songStart, gapBreak
    }

    public private(set) var fetched = false

    public init() {}

    /// True exactly once per gate (one gate per launch): the first gap break on AirPlay.
    public mutating func shouldFetch(route: LongFormRouteKind, at event: ProbeEvent) -> Bool {
        guard route == .airPlay, event == .gapBreak, !fetched else { return false }
        fetched = true
        return true
    }
}

/// The last long-form route the app probed, readable from any thread (the preparer reads it
/// off the main actor). Written only by the app's probe.
public final class DJLongFormRouteState: @unchecked Sendable {
    public static let shared = DJLongFormRouteState()

    private let lock = NSLock()
    private var route: LongFormRouteKind = .unknown
    private let flag: () -> Bool

    public init(flag: @escaping () -> Bool = { DJAirPlayRouteFlag.isEnabled() }) { self.flag = flag }

    public var lastRoute: LongFormRouteKind { lock.withLock { route } }

    /// Records a probe. Returns true when the talk-over permission changed (a DIAG change row).
    @discardableResult
    public func record(_ newRoute: LongFormRouteKind) -> Bool {
        let before = talkoverAllowed
        lock.withLock { route = newRoute }
        return before != talkoverAllowed
    }

    /// False only while the flag is on and the last probe saw AirPlay.
    public var talkoverAllowed: Bool {
        DJSessionConfig.resolve(route: lastRoute, kind: .talkover, airPlayFlag: flag()).talkoverAllowed
    }

    /// The preparer's `talkOverEnabled`: the Settings talk-over flag AND the route. On AirPlay the
    /// break is prepared on the gap-break path (the closing line carries no talk-over marker).
    public func preparerTalkOverEnabled(talkoverFlag: Bool) -> Bool { talkoverFlag && talkoverAllowed }
}
