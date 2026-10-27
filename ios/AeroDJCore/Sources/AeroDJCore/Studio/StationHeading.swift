import Foundation

/// Which station the playing screen names. The header (nav title, station tile, compact
/// sheet title) is always the station the listener opened. The app-wide session may still be
/// playing a queue started from another station; that one is reported separately and only
/// labels the now-playing track.
///
/// Build 9: the header used `playing ?? opened`. Opening Late Night while Morning Calm played
/// kept the header on "Morning Calm", so the next song tap (which correctly starts the queue
/// from the opened station) looked like the tap had switched the station to Late Night.
public struct StationHeading: Equatable, Sendable {
    /// The station the listener opened in the list (the selected row).
    public let opened: StationRef
    /// The station the current session was started from (`PlaybackSnapshot.station`).
    public let playing: StationRef?

    public init(opened: StationRef, playing: StationRef?) {
        self.opened = opened
        self.playing = playing
    }

    /// The header shows the opened station, never the playing one.
    public var header: StationRef { opened }

    /// The station the now-playing track belongs to: the session's, or the opened one when
    /// nothing has been started yet.
    public var nowPlaying: StationRef { playing ?? opened }

    /// The session is still playing a queue started from a different station. A song tap
    /// here replaces it with a queue from `opened`.
    public var isPlayingAnotherStation: Bool {
        guard let playing else { return false }
        return playing.id != opened.id
    }
}
