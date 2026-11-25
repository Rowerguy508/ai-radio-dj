import Foundation

// #454 (-Nova): one route for every station tap. A list row, a carousel card, a Duo grid card, and
// a Duo dial stop (or its Tune button) all select the tapped station in the split and then start it
// through the one start path (`StationListView.openStation` -> `StationQueuePlayer.openStation`).
// Before this, a dial tap started the station but left the split on the old one, so Now Playing
// kept the old header, never showed the new station's Starting / Couldn't start state, a song tap
// queued from the old station, and the dial would not reopen the old station afterwards.
// Restore never comes through here (`StationSplitNavigation.restore`), so a relaunch still never
// starts playback or asks for Apple Music. No playback state lives here.
public enum StationTapRoute {
    /// A station tap from any surface. Selects the station (so Now Playing is that station's) and
    /// returns the id to start. Nil, and nothing changes, for no id (the split clearing its
    /// binding while it builds the list) or an id that is not one of `available`.
    public static func tap<ID: Hashable & Sendable>(_ id: ID?, navigation: inout StationSplitNavigation<ID>,
                                                    available: [ID]) -> ID? {
        guard let id, available.contains(id) else { return nil }
        navigation.select(id)
        return id
    }

    /// A Duo dial stop id (`Station.id.uuidString`) as one of `available`, or nil.
    public static func stationID(forStop stopID: String, in available: [UUID]) -> UUID? {
        guard let id = UUID(uuidString: stopID), available.contains(id) else { return nil }
        return id
    }

    /// What the Duo dial treats as already playing (`DuoStationSwitch.Flight.receive`): the session's
    /// station while it plays or is getting ready to, otherwise "" (none). The opened station is not
    /// the playing one: after a restore it is idle, so its stop must still start it. A paused session
    /// is not playing either; the start path resumes it (`.resumed`) like a row tap does.
    public static func dialPlayingID(_ snapshot: PlaybackSnapshot) -> String {
        switch snapshot.transport {
        case .playing, .preparing: snapshot.station?.id ?? ""
        case .stopped, .paused: ""
        }
    }
}
