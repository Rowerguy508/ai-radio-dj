import Foundation

/// Inputs to the engine. The MusicKit adapter translates player events into these;
/// nothing else changes the snapshot.
public enum PlaybackEvent: Equatable, Sendable {
    /// The user started a queue. `tracks` is the full queue, `startIndex` the first song.
    case queueStarted(tracks: [TrackInfo], startIndex: Int, station: StationRef?)
    /// The current song ended on its own and the queue moved to `nextIndex`.
    case naturalBoundary(nextIndex: Int)
    /// The last song ended on its own and nothing is queued.
    case queueFinished
    /// The user skipped to `nextIndex` (never a DJ break).
    case userSkipped(nextIndex: Int)
    case userPaused
    /// The system interrupted playback. Not a user pause.
    case interruptionPaused
    /// The output route was removed. Not a user pause.
    case routePaused
    case userResumed
    case djStarted(line: String)
    case djFinished
    /// The speech was cancelled or timed out. Music has already been resumed by the adapter.
    case djCancelled
    /// The speech engine failed. The show goes on; the UI is told.
    case djFailed(message: String)
    /// The user edited the songs after the one playing. The playing song is never affected.
    case upNextEdited(UpNextEdit)
    case errorRaised(PlaybackError)
    case errorCleared
}

/// Pure, deterministic state machine. Given the same events it always produces the
/// same snapshots, so it is tested on Linux and never depends on the device.
public struct PlaybackEngine: Sendable {
    public private(set) var snapshot = PlaybackSnapshot()
    private var tracks: [TrackInfo] = []
    private var index = 0

    public init() {}

    @discardableResult
    public mutating func apply(_ event: PlaybackEvent) -> PlaybackSnapshot {
        switch event {
        case let .queueStarted(tracks, startIndex, station):
            guard !tracks.isEmpty else {
                self.tracks = []
                index = 0
                snapshot = PlaybackSnapshot(station: station, error: snapshot.error)
                return snapshot
            }
            self.tracks = tracks
            index = min(max(startIndex, 0), tracks.count - 1)
            snapshot.station = station
            publishPosition(transport: .playing)

        case let .naturalBoundary(nextIndex), let .userSkipped(nextIndex):
            // A natural end and a user skip both move to `nextIndex`; only the natural
            // one may have a DJ break, and the adapter decides that, not the engine.
            guard tracks.indices.contains(nextIndex) else {
                return apply(.queueFinished)
            }
            index = nextIndex
            publishPosition(transport: snapshot.transport == .stopped ? .playing : snapshot.transport)

        case .queueFinished:
            tracks = []
            index = 0
            snapshot.nowPlaying = nil
            snapshot.upNext = []
            snapshot.transport = .stopped

        case .userPaused, .interruptionPaused, .routePaused:
            // The new cases pause transport and do not record which hold it was.
            if snapshot.transport == .playing { snapshot.transport = .paused }

        case .userResumed:
            if snapshot.transport == .paused { snapshot.transport = .playing }

        case let .djStarted(line):
            snapshot.dj = line.isEmpty ? .idle : .speaking(line: line)

        case .djFinished, .djCancelled:
            snapshot.dj = .idle

        case let .djFailed(message):
            snapshot.dj = .idle
            snapshot.error = PlaybackError(kind: .speechFailed, message: message, isRecoverable: true)

        case let .upNextEdited(edit):
            // Only the tracks after the current one change. An invalid edit is reported, not applied.
            let remaining = tracks.indices.contains(index) ? Array(tracks[(index + 1)...]) : []
            switch UpNextEditor.apply(edit, to: remaining, nowPlaying: snapshot.nowPlaying) {
            case let .success(newUpNext):
                tracks = (tracks.indices.contains(index) ? Array(tracks[...index]) : []) + newUpNext
                snapshot.upNext = newUpNext
            case let .failure(reason):
                snapshot.error = PlaybackError(kind: .playbackFailed, message: Self.message(for: reason), isRecoverable: true)
            }

        case let .errorRaised(error):
            snapshot.error = error

        case .errorCleared:
            snapshot.error = nil
        }
        return snapshot
    }

    private static func message(for reason: UpNextEditError) -> String {
        switch reason {
        case .outOfRange: "That song is no longer in the queue."
        case .alreadyQueued: "That song is already queued."
        case .isPlayingNow: "That song is playing now."
        }
    }

    private mutating func publishPosition(transport: TransportState) {
        snapshot.nowPlaying = tracks.indices.contains(index) ? tracks[index] : nil
        snapshot.upNext = tracks.indices.contains(index) ? Array(tracks[(index + 1)...]) : []
        snapshot.transport = transport
    }
}
