/// What the app does when the player's single-song queue ends on its own.
///
/// The player holds one song at a time, so its end is the end of that song. If the
/// station has another song, that end is a planned natural boundary: the DJ break runs
/// and the next song is loaded after it. Pure, so the rule is tested on every platform.
public enum QueueHandoff: Equatable, Sendable {
    /// Load the song at this index after the boundary.
    case advance(to: Int)
    /// No song follows: the station is finished.
    case stop

    public static func afterSongEnds(finishedIndex: Int, count: Int) -> QueueHandoff {
        guard finishedIndex >= 0, finishedIndex + 1 < count else { return .stop }
        return .advance(to: finishedIndex + 1)
    }
}
