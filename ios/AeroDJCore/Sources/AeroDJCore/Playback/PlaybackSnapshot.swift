import Foundation

/// Public playback contract for the UI. The UI reads only these value types;
/// it never sees MusicKit, AVFoundation or the speech synthesizer.
public struct TrackInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let artistName: String
    public let artworkURL: URL?

    public init(id: String, title: String, artistName: String, artworkURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artworkURL = artworkURL
    }
}

/// The station the current session was started from. One app-wide session plays
/// at a time: opening another station shows its context but never starts a second player.
public struct StationRef: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the user asked for. `.playing` means the show is on, even during a DJ break.
public enum TransportState: String, Equatable, Sendable {
    case stopped
    case playing
    case paused
}

/// What the DJ is doing right now.
public enum DJActivity: Equatable, Sendable {
    case idle
    case speaking(line: String)
}

/// A recoverable problem the UI can show. `isRecoverable` means playback continues
/// or the user can retry without restarting the app.
public struct PlaybackError: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case notAuthorized
        case subscriptionRequired
        case playbackFailed
        case speechFailed
        case resumeFailed
    }

    public let kind: Kind
    public let message: String
    public let isRecoverable: Bool

    public init(kind: Kind, message: String, isRecoverable: Bool) {
        self.kind = kind
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

/// Everything the UI needs, in one value. Equal snapshots mean nothing visible changed.
public struct PlaybackSnapshot: Equatable, Sendable {
    public var station: StationRef?
    public var nowPlaying: TrackInfo?
    public var upNext: [TrackInfo]
    public var transport: TransportState
    public var dj: DJActivity
    public var error: PlaybackError?

    public init(
        station: StationRef? = nil,
        nowPlaying: TrackInfo? = nil,
        upNext: [TrackInfo] = [],
        transport: TransportState = .stopped,
        dj: DJActivity = .idle,
        error: PlaybackError? = nil
    ) {
        self.station = station
        self.nowPlaying = nowPlaying
        self.upNext = upNext
        self.transport = transport
        self.dj = dj
        self.error = error
    }
}
