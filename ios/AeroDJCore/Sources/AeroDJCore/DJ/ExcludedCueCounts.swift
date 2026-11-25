import Foundation

/// Echo's #396 room N1 (#388, -Nova): how many cues a break lost because they name a song the
/// station now leaves out (`DJBreakSession.songsExcluded`), by kind, for the P0 trace. Counts only:
/// never a song ID, title, artist or name, and nothing says why the song is left out.
public struct ExcludedCueCounts: Equatable, Sendable {
    public var timeChecks: Int
    /// Briefing items (`NarrationCue.isContent`). Never a song by construction; counted apart so
    /// the trace shows it.
    public var briefing: Int
    public var other: Int
    /// Cues left in the break (0: nothing was left, the break was dropped).
    public var kept: Int

    public var dropped: Int { timeChecks + briefing + other }

    public init(timeChecks: Int = 0, briefing: Int = 0, other: Int = 0, kept: Int = 0) {
        self.timeChecks = timeChecks
        self.briefing = briefing
        self.other = other
        self.kept = kept
    }

    /// `droppedCues` by kind: the time-check cue (`timeCheckCueID`), briefing items, everything else.
    public init(dropped droppedCues: [NarrationCue], timeCheckCueID: UUID?, kept: Int) {
        self.init(kept: kept)
        for cue in droppedCues {
            if cue.id == timeCheckCueID { timeChecks += 1 } else if cue.isContent { briefing += 1 } else { other += 1 }
        }
    }
}
