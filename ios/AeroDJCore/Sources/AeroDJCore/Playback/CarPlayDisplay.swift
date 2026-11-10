import Foundation

// CarPlay (#438). The car shows station names, the current song's title, artist, and
// artwork, and the station that song belongs to. Spoken lines, playback errors, the
// rest of the queue, and a created station's kind summary are not fields on this
// screen: a caller cannot put them on the car by passing the snapshot through.

/// One station row on the car. The text is the name only.
public struct CarPlayStationRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let pick: CarPlayStationPick

    public init(id: String, name: String, pick: CarPlayStationPick) {
        self.id = id
        self.name = name
        self.pick = pick
    }
}

public enum CarPlayStationPick: Equatable, Sendable {
    /// Morning Calm or Late Night. The phone tap does not load a queue for that row.
    case builtIn
    /// A station the listener created. The car opens it with `openCreatedStation(.userTap)`.
    case created(UUID)
}

/// What picking a row does.
public enum CarPlayPickEffect: Equatable, Sendable {
    /// `StationQueuePlayer.openCreatedStation(.userTap)` for this recipe.
    case openCreatedStation(UUID)
    /// The phone's built-in row: `cancelCreatedStationStart()` then `authorize()`.
    /// That path does not replace the queue with another station.
    case openBuiltInShell
}

/// The phone's created-station row tap.
public enum CarPlayStationStart {
    public static let trigger = StationOpenTrigger.userTap
}

/// A built-in station name, as the phone list already shows it.
public struct CarPlayBuiltInStation: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Song title, artist, station name, and the track's artwork URL. Nothing else.
public struct CarPlayNowPlaying: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let stationName: String
    public let artworkURL: URL?

    public init(title: String, artist: String, stationName: String, artworkURL: URL?) {
        self.title = title
        self.artist = artist
        self.stationName = stationName
        self.artworkURL = artworkURL
    }

    public var visibleText: [String] { [title, artist, stationName] }
}

/// Now-playing text plus the transport at the time it was taken. Transport is not
/// shown. It is part of equality so a playback confirm republishes the station name
/// after the player writes its own now-playing info. A spoken line is not part of it.
public struct CarPlayNowPlayingPublication: Equatable, Sendable {
    public let fields: CarPlayNowPlaying
    public let transport: TransportState

    public init(fields: CarPlayNowPlaying, transport: TransportState) {
        self.fields = fields
        self.transport = transport
    }
}

/// The whole car screen.
public struct CarPlayScreenModel: Equatable, Sendable {
    public let rows: [CarPlayStationRow]
    public let nowPlaying: CarPlayNowPlaying?
    public let publication: CarPlayNowPlayingPublication?
    public let accessNotice: String?
    /// Shown when the list has no rows. Not a station.
    public let emptyMessage: String?

    public var visibleText: [String] {
        var lines = rows.map(\.name)
        if let emptyMessage { lines.append(emptyMessage) }
        if let nowPlaying { lines.append(contentsOf: nowPlaying.visibleText) }
        if let accessNotice { lines.append(accessNotice) }
        return lines
    }
}

public enum CarPlayScreen {
    public static let emptyListMessage = "Save a station in \(AppName.display) to play it here."

    /// Built-ins first, then created stations, matching the phone list.
    /// A blank name is left off. Created summaries are not read.
    public static func project(builtIn: [CarPlayBuiltInStation],
                               created: [CreatedStationEntry],
                               snapshot: PlaybackSnapshot,
                               opened: StationRef?,
                               access: PlaybackAccess) -> CarPlayScreenModel {
        let rows = stationRows(builtIn: builtIn, created: created)
        let nowPlaying = nowPlayingItem(snapshot: snapshot, opened: opened)
        let publication = nowPlaying.map { CarPlayNowPlayingPublication(fields: $0, transport: snapshot.transport) }
        return CarPlayScreenModel(rows: rows, nowPlaying: nowPlaying, publication: publication,
                                  accessNotice: accessNotice(for: access),
                                  emptyMessage: rows.isEmpty ? emptyListMessage : nil)
    }

    /// The recipe id the phone's `openCreatedStation(.userTap)` starts. Transport does not
    /// change the call: the starter itself starts now when nothing is queued, and switches
    /// at the song boundary while a song is playing or paused.
    public static func effect(for pick: CarPlayStationPick) -> CarPlayPickEffect {
        switch pick {
        case .created(let id):
            return .openCreatedStation(id)
        case .builtIn:
            return .openBuiltInShell
        }
    }

    /// Fixed phone copy for a block that is not "authorized". Nil when the list can just show stations.
    public static func accessNotice(for access: PlaybackAccess) -> String? {
        switch access {
        case .checking, .authorized:
            nil
        case .needsAuthorization:
            NowPlayingContent.needsAuthorization.title
        case .denied:
            NowPlayingContent.accessDenied.title
        case .subscriptionRequired:
            NowPlayingContent.subscriptionRequired.title
        }
    }

    private static func stationRows(builtIn: [CarPlayBuiltInStation],
                                    created: [CreatedStationEntry]) -> [CarPlayStationRow] {
        let shells = builtIn.compactMap { station -> CarPlayStationRow? in
            guard let name = displayName(station.name) else { return nil }
            return CarPlayStationRow(id: station.id, name: name, pick: .builtIn)
        }
        let made = created.compactMap { station -> CarPlayStationRow? in
            guard let name = displayName(station.name) else { return nil }
            return CarPlayStationRow(id: station.id.uuidString, name: name, pick: .created(station.id))
        }
        return shells + made
    }

    private static func displayName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : name
    }

    /// Title, artist, and artwork come from the current track only.
    /// The station name is `StationHeading.nowPlaying` (the session's station, or the
    /// one the listener just opened, or the app name when neither is known).
    private static func nowPlayingItem(snapshot: PlaybackSnapshot, opened: StationRef?) -> CarPlayNowPlaying? {
        guard let track = snapshot.nowPlaying else { return nil }
        let fallback = opened ?? StationRef(id: "app", name: AppName.display)
        let station = StationHeading(opened: fallback, playing: snapshot.station).nowPlaying
        return CarPlayNowPlaying(title: track.title, artist: track.artistName,
                                 stationName: station.name, artworkURL: track.artworkURL)
    }
}

/// Play, pause, and next stay on `MPRemoteCommandCenter` (the lock-screen path).
/// Previous has no app path and stays off. This type does not perform a skip.
public enum CarPlayTransport {
    public static let previousTrackEnabled = false

    public static func nextTrackEnabled(queueIndex: Int, queueCount: Int) -> Bool {
        RemoteNextCommand.isEnabled(queueIndex: queueIndex, queueCount: queueCount)
    }
}

/// Writes the car's now-playing text onto the dictionary the system template already shows.
///
/// The string values are MediaPlayer's item keys (`title`, `artist`, `albumTitle`,
/// `lyrics`, `comments`). The station name uses the album line, which is where CarPlay
/// shows a second credit under the artist. Elapsed time, duration, and rate are left
/// as the player published them. Lyrics and comments are removed.
public enum CarPlayNowPlayingMerge {
    public static let titleKey = "title"
    public static let artistKey = "artist"
    public static let stationNameKey = "albumTitle"
    public static let lyricsKey = "lyrics"
    public static let commentsKey = "comments"
    public static let removedKeys = [lyricsKey, commentsKey]

    public static func apply(fields: CarPlayNowPlaying, to info: [String: Any]) -> [String: Any] {
        var next = info
        next[titleKey] = fields.title
        next[artistKey] = fields.artist
        next[stationNameKey] = fields.stationName
        for key in removedKeys { next.removeValue(forKey: key) }
        return next
    }
}

/// Decides what a now-playing publish does to text and artwork.
///
/// The publication generation is the track. The URL is the artwork. A fetch may set
/// artwork only when its token is still the open one and the URL is still the latest
/// publication's URL. It never carries title, artist, or station name, so a late fetch
/// cannot write an older song back over the one on screen.
public struct CarPlayArtworkGate: Equatable, Sendable {
    public struct Token: Equatable, Sendable, Hashable {
        public var id: UInt64
        public var url: URL

        public init(id: UInt64, url: URL) {
            self.id = id
            self.url = url
        }
    }

    public enum Command: Equatable, Sendable {
        /// Replace title, artist, and station name. Does not touch artwork.
        case writeText(CarPlayNowPlaying)
        /// Remove the current image now. No text.
        case clearArtwork
        /// Load this URL for this publication. A newer publish invalidates the token.
        case startFetch(Token)
    }

    public enum Arrival: Equatable, Sendable {
        /// The publication moved on. Do not write text or artwork.
        case ignore
        /// Set the image for this URL only. Do not write title, artist, or station name.
        case setArtwork(URL)
    }

    private var generation: UInt64 = 0
    private var latestURL: URL?
    private var openFetch: Token?
    private var showing: URL?

    public init() {}

    public mutating func publish(_ fields: CarPlayNowPlaying) -> [Command] {
        generation += 1
        var commands: [Command] = [.writeText(fields)]
        guard let url = fields.artworkURL else {
            if showing != nil || openFetch != nil { commands.append(.clearArtwork) }
            showing = nil
            openFetch = nil
            latestURL = nil
            return commands
        }
        latestURL = url
        if showing == url, openFetch == nil { return commands }
        if openFetch?.url == url { return commands }
        if showing != nil || openFetch != nil { commands.append(.clearArtwork) }
        showing = nil
        let token = Token(id: generation, url: url)
        openFetch = token
        commands.append(.startFetch(token))
        return commands
    }

    /// A fetch finished. The caller supplies the token it started with, not a copy of the
    /// song that was current then.
    public mutating func fetchArrived(_ token: Token) -> Arrival {
        guard openFetch == token, latestURL == token.url else { return .ignore }
        openFetch = nil
        showing = token.url
        return .setArtwork(token.url)
    }

    /// The load failed or produced no image. A later publish of the same URL may try again.
    public mutating func fetchFailed(_ token: Token) {
        guard openFetch == token else { return }
        openFetch = nil
    }
}
