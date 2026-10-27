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
    /// MusicKit confirmed `playbackStatus == .playing` after a start or resume.
    case playbackConfirmed
    /// A start/resume gate refused after transport moved to `.preparing`. Restore `.paused`
    /// without clearing a system hold (unplug / interruption).
    case playbackStartRefused
    /// Build 9 P0 (-Atlas, Sentinel): the current start passed its 8 s confirm deadline (or MusicKit
    /// said `.interrupted`) and is still `.preparing`. From here a transport tap may cancel it.
    case startConfirmTimedOut
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
            snapshot.startTimedOut = false
            // Preparing until MusicKit confirms playback; do not claim .playing early.
            publishPosition(transport: .preparing)

        case let .naturalBoundary(nextIndex), let .userSkipped(nextIndex):
            // A natural end and a user skip both move to `nextIndex`; only the natural
            // one may have a DJ break, and the adapter decides that, not the engine.
            guard tracks.indices.contains(nextIndex) else {
                return apply(.queueFinished)
            }
            index = nextIndex
            if case .userSkipped = event { snapshot.startTimedOut = false }
            // Keep preparing if we were still waiting on MusicKit; otherwise preserve transport.
            // A stopped show that advances (shouldn't) goes to preparing, not optimistic playing.
            let nextTransport: TransportState
            switch snapshot.transport {
            case .stopped: nextTransport = .preparing
            case .preparing, .playing, .paused: nextTransport = snapshot.transport
            }
            publishPosition(transport: nextTransport)

        case .queueFinished:
            tracks = []
            index = 0
            snapshot.nowPlaying = nil
            snapshot.upNext = []
            snapshot.transport = .stopped
            snapshot.hold = nil

        case .userPaused:
            holdTransport(.user)
        case .interruptionPaused:
            holdTransport(.interruption)
        case .routePaused:
            holdTransport(.routeRemoved)

        case .userResumed:
            // User asked to resume; stay in preparing until MusicKit confirms.
            // Do not clear a system hold here — only playbackConfirmed clears it, and only
            // from .preparing. A refused gate uses playbackStartRefused to keep the hold.
            if snapshot.transport == .paused { snapshot.transport = .preparing }
            snapshot.startTimedOut = false

        case .playbackConfirmed:
            // Only .preparing may become .playing. A late confirm must not override a
            // route-removed or interruption hold that already moved transport to .paused.
            guard snapshot.transport == .preparing else { break }
            snapshot.transport = .playing
            snapshot.hold = nil

        case .playbackStartRefused:
            if snapshot.transport == .preparing {
                snapshot.transport = .paused
            }
            // hold unchanged (including .routeRemoved / .interruption captions)

        case .startConfirmTimedOut:
            // Only a start still waiting on MusicKit can be timed out.
            if snapshot.transport == .preparing { snapshot.startTimedOut = true }

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
        // The flag belongs to one `.preparing` start; it never outlives it.
        if snapshot.transport != .preparing { snapshot.startTimedOut = false }
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
        if transport == .playing { snapshot.hold = nil }
    }

    private mutating func holdTransport(_ hold: PlaybackHold) {
        if snapshot.transport == .playing || snapshot.transport == .preparing {
            snapshot.transport = .paused
        }
        snapshot.hold = hold
    }
}
