import Foundation

// #539 follow-up (owner, Nov 23: "I just want the live player to replace the Apple Music one"). -Fry
//
// What iOS lets us own on the one system lock-screen player (docs, not device evidence):
// - `ApplicationMusicPlayer` already reports OnAirly, not Music, as the Now Playing app (WWDC21
//   "Meet MusicKit for Swift"). Its card's title, artist and artwork are the catalog song's, and
//   the framework handles that client's remote commands itself (MPMusicPlayerController docs:
//   "you don't provide code to handle them"). The player is hosted out of process
//   (com.apple.MediaPlayer.RemotePlayerService), so `MPNowPlayingInfoCenter.default()` in our
//   process is a second Now Playing client, not a way to edit that card.
// - iOS 27's NowPlaying framework (`MediaSession`) lets the app publish its own session (title,
//   subtitle, artwork, commands) and ask, from the foreground, to be the system primary session
//   (`requestToBecomeSystemPrimary()`). Apple: that "doesn't guarantee the system displays your
//   session". Whether it wins over MusicKit's out-of-process client while a song plays is the
//   build-57 device check.
//
// This file is the pure part: what the OnAirly session says and which commands it offers, built
// only from `PlaybackSnapshot` and `DJStudioState` (the same privacy rules as
// `NowPlayingDisplay`: no script or briefing text, the DJ lines are fixed copy).

/// The content of the OnAirly Now Playing session. Nil from `make` means no session.
public struct OnAirlyNowPlayingCard: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case playing
        case paused
        /// MusicKit has not confirmed the song yet (`.preparing`).
        case buffering
    }

    /// Stable per song (or per station before the first song), so artwork is re-requested only
    /// when the song changes.
    public let contentID: String
    /// The song title, or the station name before the first song.
    public let title: String
    /// "Artist · status", where status is the DJ line or the station name (see `subtitle(...)`).
    public let subtitle: String
    /// The current song's catalog artwork. Nil before the first song.
    public let artworkURL: URL?
    public let transport: Transport
    /// Catalog duration, when known and above 0.
    public let duration: TimeInterval?
    /// Seek commands are offered only while `PlaybackSnapshot.canSeek` (never in a DJ break).
    public let canSeek: Bool
    /// `RemoteNextCommand.isEnabled(queueIndex:queueCount:)`, the MediaPlayer path's rule.
    public let nextEnabled: Bool
    /// True while the DJ is speaking. Elapsed time is not published then (a gap break holds the
    /// song, and a frozen clock reads better than one the system extrapolates past the song).
    public let djOnAir: Bool

    /// Fixed copy. Never taken from `DJStudioState.detail` or any script.
    public static let onAirCopy = "DJ on air"
    public static let readyCopy = NowPlayingDisplay.readyLineCopy
    public static let separator = " · "

    public init(contentID: String, title: String, subtitle: String, artworkURL: URL?, transport: Transport,
                duration: TimeInterval?, canSeek: Bool, nextEnabled: Bool, djOnAir: Bool) {
        self.contentID = contentID
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.transport = transport
        self.duration = duration
        self.canSeek = canSeek
        self.nextEnabled = nextEnabled
        self.djOnAir = djOnAir
    }

    /// Nil when stopped, or when there is neither a song nor a station to show.
    /// `queueIndex`/`queueCount` are `MusicKitService`'s own, so Next follows `RemoteNextCommand`
    /// exactly as the MediaPlayer path's `nextTrackCommand` does (through loads and DJ breaks).
    public static func make(snapshot: PlaybackSnapshot, dj: DJStudioState, duration: TimeInterval? = nil,
                            queueIndex: Int, queueCount: Int) -> OnAirlyNowPlayingCard? {
        let transport: Transport
        switch snapshot.transport {
        case .stopped: return nil
        case .preparing: transport = .buffering
        case .playing: transport = .playing
        case .paused: transport = .paused
        }
        let track = snapshot.nowPlaying
        let stationName = snapshot.station.flatMap { nonEmpty($0.name) }
        guard track != nil || stationName != nil else { return nil }
        let title = track.flatMap { nonEmpty($0.title) } ?? stationName ?? AppName.display
        let contentID = track.map { "track:\($0.id)" } ?? "station:\(snapshot.station?.id ?? "app")"
        let validDuration = track == nil ? nil : duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return OnAirlyNowPlayingCard(
            contentID: contentID, title: title,
            subtitle: subtitle(artist: track?.artistName, station: stationName, dj: dj),
            artworkURL: track?.artworkURL, transport: transport, duration: validDuration,
            canSeek: track != nil && snapshot.canSeek && !dj.isOnAir,
            nextEnabled: RemoteNextCommand.isEnabled(queueIndex: queueIndex, queueCount: queueCount),
            djOnAir: dj.isOnAir)
    }

    /// "Artist · DJ on air", "Artist · DJ break after this song", or "Artist · Station". The last
    /// part falls back to the app name, so the card always says OnAirly somewhere when the
    /// station is unknown.
    public static func subtitle(artist: String?, station: String?, dj: DJStudioState) -> String {
        let status: String
        if dj.isOnAir {
            status = onAirCopy
        } else if NowPlayingDisplay.readyLabel(for: dj) != nil {
            status = readyCopy
        } else {
            status = station.flatMap(nonEmpty) ?? AppName.display
        }
        return ([artist.flatMap(nonEmpty)].compactMap { $0 } + [status]).joined(separator: separator)
    }

    /// Elapsed time to publish: only while the song is the audible thing.
    public func publishedElapsed(_ playerTime: TimeInterval) -> TimeInterval? {
        guard transport == .playing || transport == .paused, !djOnAir, duration != nil,
              playerTime.isFinite, playerTime >= 0 else { return nil }
        return duration.map { min(playerTime, $0) }
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Which Now Playing API the app uses. Apple: don't mix the NowPlaying framework with
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` for local playback ("undefined behavior"),
/// so exactly one of the two paths is on for a launch.
public enum OnAirlyNowPlayingPolicy {
    /// Kill switch for the iOS 27 OnAirly session: this launch's `onAirlyNowPlayingSession`, the
    /// value cached by the previous launch's `GET /api/flags` fetch (`OnAirlySessionFlag`). Read
    /// once per process; a fetch during this launch never changes it.
    public static var sessionEnabled: Bool { OnAirlySessionFlag.launchValue }
    /// The NowPlaying framework's first release.
    public static let minimumOSMajor = 27

    public static func usesSession(osMajor: Int, enabled: Bool = sessionEnabled) -> Bool {
        enabled && osMajor >= minimumOSMajor
    }

    /// `MusicKitService.installRemoteCommands()` runs only on the MediaPlayer path.
    public static func installsMediaPlayerRemoteCommands(usesSession: Bool) -> Bool { !usesSession }

    /// The CarPlay bridge writes `MPNowPlayingInfoCenter` only on the MediaPlayer path. On the
    /// session path the car reads the system's Now Playing like the lock screen.
    public static func carPlayBridgeWrites(usesSession: Bool) -> Bool { !usesSession }

    /// Ask to be the system's primary session: only from the foreground (Apple: a background
    /// request has no effect), only once audio is playing, and only when not already primary.
    public static func shouldRequestSystemPrimary(card: OnAirlyNowPlayingCard?, appInForeground: Bool,
                                                  isSystemPrimary: Bool) -> Bool {
        guard let card, appInForeground, !isSystemPrimary else { return false }
        return card.transport == .playing
    }
}

/// Where the last fetched `onAirlyNowPlayingSession` value is kept between launches.
public protocol OnAirlySessionFlagCache: AnyObject, Sendable {
    /// The value the last successful fetch answered, or nil (never fetched, or the server had no key).
    func cachedValue() -> Bool?
    /// Nil removes it (next launch: the default, on).
    func setCachedValue(_ value: Bool?)
}

/// The app's cache: one Bool in `UserDefaults` (no identifier, no timestamp, nothing else).
public final class UserDefaultsOnAirlySessionFlagCache: OnAirlySessionFlagCache, @unchecked Sendable {
    public static let key = "onAirlyNowPlayingSessionFlag"
    public static let shared = UserDefaultsOnAirlySessionFlagCache(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func cachedValue() -> Bool? { defaults.object(forKey: Self.key) as? Bool }

    public func setCachedValue(_ value: Bool?) {
        if let value { defaults.set(value, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }
}

/// #539 follow-up (Orion's condition on #600, Atlas's timing rule): the remote kill switch for the
/// OnAirly Now Playing session, `onAirlyNowPlayingSession` in the aerodj-tts proxy's
/// `GET /api/flags` (served from `AERODJ_ONAIRLY_NOW_PLAYING_SESSION`; only the exact string
/// `false` turns it off).
///
/// - This launch uses the value CACHED BY AN EARLIER LAUNCH, read once and synchronously before
///   anything installs remote commands, so a launch is wholly on the session path or wholly on
///   the MediaPlayer path: never both, never neither. No cached value: ON.
/// - This launch's fetch only updates the cache for the NEXT launch. A JSON `true`/`false` is
///   cached; a 200 JSON object without the key clears the cache (next launch on); a failed fetch,
///   a non-200, an unreadable body or being offline leaves the cache as it is.
/// - The request is `DJAirPlayRouteFlag.request(baseURL:)`: a bare HTTPS GET with no token,
///   cookie or identifier. Fetched once per launch, only on iOS 27 and later.
public enum OnAirlySessionFlag {
    public static let jsonKey = "onAirlyNowPlayingSession"
    public static let defaultValue = true

    /// This process's value, read once from the app's cache.
    public static let launchValue: Bool = launchValue(cache: UserDefaultsOnAirlySessionFlagCache.shared)

    /// The value a launch starts with: the cached value, else on.
    public static func launchValue(cache: any OnAirlySessionFlagCache) -> Bool {
        cache.cachedValue() ?? defaultValue
    }

    /// What one fetched body says.
    public enum Answer: Equatable, Sendable {
        case value(Bool)
        /// A JSON object without the key: the server no longer serves it, so the default applies.
        case missing
        /// Not a small JSON object, or the key is not a JSON boolean: ignored.
        case unreadable
    }

    public static func parse(_ body: Data) -> Answer {
        guard !body.isEmpty, body.count <= 1024,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .unreadable }
        guard object.keys.contains(jsonKey) else { return .missing }
        guard let body = try? JSONDecoder().decode(Body.self, from: body) else { return .unreadable }
        return .value(body.onAirlyNowPlayingSession)
    }

    private struct Body: Decodable { let onAirlyNowPlayingSession: Bool }

    /// Fetches the flags and updates the cache for the next launch. Never changes `launchValue`.
    /// Returns the value the next launch will start with.
    @discardableResult
    public static func refresh(transport: any HTTPTransport, baseURL: URL,
                               cache: any OnAirlySessionFlagCache) async -> Bool {
        if let request = DJAirPlayRouteFlag.request(baseURL: baseURL),
           let (data, response) = try? await transport.send(request), response.statusCode == 200 {
            switch parse(data) {
            case .value(let value): cache.setCachedValue(value)
            case .missing: cache.setCachedValue(nil)
            case .unreadable: break
            }
        }
        return launchValue(cache: cache)
    }
}
