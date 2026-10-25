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
    case userResumed
    case djStarted(line: String)
    case djFinished
    /// The speech was cancelled or timed out. Music has already been resumed by the adapter.
    case djCancelled
    /// The speech engine failed. The show goes on; the UI is told.
    case djFailed(message: String)
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

        case .userPaused:
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

        case let .errorRaised(error):
            snapshot.error = error

        case .errorCleared:
            snapshot.error = nil
        }
        return snapshot
    }

    private mutating func publishPosition(transport: TransportState) {
        snapshot.nowPlaying = tracks.indices.contains(index) ? tracks[index] : nil
        snapshot.upNext = tracks.indices.contains(index) ? Array(tracks[(index + 1)...]) : []
        snapshot.transport = transport
    }
}
