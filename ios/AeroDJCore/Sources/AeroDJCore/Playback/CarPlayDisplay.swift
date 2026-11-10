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
    /// A built-in row. It does not apply a recipe.
    case builtIn
    /// A station the listener created. `StationQueuePlayer.openCreatedStation(.userTap)`.
    case created(UUID)
}

/// What picking a row does. Both cases call paths the phone already has.
public enum CarPlayPickEffect: Equatable, Sendable {
    case openCreatedStation(UUID)
    /// `cancelCreatedStationStart`, then `authorize`. `resumePlayback` also calls
    /// `MusicKitService.resume()` — the Play button and the remote play command.
    case openBuiltIn(resumePlayback: Bool)
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

    public var visibleText: [String] {
        var lines = rows.map(\.name)
        if let nowPlaying { lines.append(contentsOf: nowPlaying.visibleText) }
        if let accessNotice { lines.append(accessNotice) }
        return lines
    }
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

public enum CarPlayScreen {
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
                                  accessNotice: accessNotice(for: access))
    }

    public static func effect(for pick: CarPlayStationPick, transport: TransportState) -> CarPlayPickEffect {
        switch pick {
        case .created(let id):
            return .openCreatedStation(id)
        case .builtIn:
            switch transport {
            case .playing, .preparing:
                return .openBuiltIn(resumePlayback: false)
            case .paused, .stopped:
                return .openBuiltIn(resumePlayback: true)
            }
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
        let built = builtIn.compactMap { station -> CarPlayStationRow? in
            guard let name = displayName(station.name) else { return nil }
            return CarPlayStationRow(id: station.id, name: name, pick: .builtIn)
        }
        let made = created.compactMap { station -> CarPlayStationRow? in
            guard let name = displayName(station.name) else { return nil }
            return CarPlayStationRow(id: station.id.uuidString, name: name, pick: .created(station.id))
        }
        return built + made
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
