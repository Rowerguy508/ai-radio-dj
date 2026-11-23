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
    /// Next is offered only while a next song is queued (same rule as `RemoteNextCommand`).
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
    public static func make(snapshot: PlaybackSnapshot, dj: DJStudioState,
                            duration: TimeInterval? = nil) -> OnAirlyNowPlayingCard? {
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
            nextEnabled: track != nil && !snapshot.upNext.isEmpty,
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
    /// Kill switch for the iOS 27 OnAirly session. Off restores build 56 behaviour exactly
    /// (MusicKit's card, MediaPlayer remote commands, the CarPlay info-center bridge).
    public static let sessionEnabled = true
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
