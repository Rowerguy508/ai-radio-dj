import Foundation

/// Shared sample snapshots for SwiftUI previews and tests. The same values drive
/// both, so a preview shows exactly what the tests check.
public enum PlaybackFixtures {
    public static let station = StationRef(id: "morning-calm", name: "Morning Calm")

    public static let songs: [TrackInfo] = [
        TrackInfo(id: "1", title: "Morning Light", artistName: "The Calm Collective"),
        TrackInfo(id: "2", title: "Slow Burn", artistName: "Neon Harbor"),
        TrackInfo(id: "3", title: "Golden Hour", artistName: "Paper Satellites"),
    ]

    /// Playing song one, with song two queued. Used for compact and studio layouts.
    public static let playing = PlaybackSnapshot(
        station: station,
        nowPlaying: songs[0],
        upNext: Array(songs[1...]),
        transport: .playing,
        dj: .idle
    )

    /// A DJ break is speaking; the show is still on and the next song is shown.
    public static let djSpeaking = PlaybackSnapshot(
        station: station,
        nowPlaying: songs[1],
        upNext: [songs[2]],
        transport: .playing,
        dj: .speaking(line: "That was Morning Light. Here comes Slow Burn.")
    )

    public static let paused = PlaybackSnapshot(
        station: station,
        nowPlaying: songs[0],
        upNext: Array(songs[1...]),
        transport: .paused,
        dj: .idle
    )

    /// A recoverable failure: the show keeps going and the UI offers a dismiss.
    public static let recoverableError = PlaybackSnapshot(
        station: station,
        nowPlaying: songs[1],
        upNext: [songs[2]],
        transport: .playing,
        dj: .idle,
        error: PlaybackError(kind: .speechFailed, message: "The DJ line could not play.", isRecoverable: true)
    )

    public static let stopped = PlaybackSnapshot(station: station)
}
