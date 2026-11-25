import Foundation

/// How a talk-over reports which of its lines aired (#409 / Fry's #403 nit 2; Fry's #409 nits).
/// The app's `InterludePlaybackAdapter.playTalkover` asks this before it plays.
/// - Cue ids that match the clips one for one: the break reports its lines (`.reportsLines`),
///   and each line that plays to its end reports its own cue id (`.lineFinished`).
/// - Any mismatch (unreachable today: `TalkoverCoordinator` hands one id per clip): the break
///   still says it reports lines, but no line has a cue id, so no line counts as aired. It fails
///   closed: before, the mismatch fell back to counting every line on `.finished`. -Nova
public struct TalkoverLineReporting: Equatable, Sendable {
    /// Always true for a talk-over: the session counts only reported lines.
    public let reportsLines: Bool
    /// One per clip, in order; empty on a mismatch.
    public let cueIDs: [UUID]

    public init(cueIDs: [UUID], clipCount: Int) {
        reportsLines = true
        self.cueIDs = clipCount > 0 && cueIDs.count == clipCount ? cueIDs : []
    }

    /// The cue id to report when the clip at `index` played to its end, if any.
    public func finishedCueID(atClip index: Int) -> UUID? {
        cueIDs.indices.contains(index) ? cueIDs[index] : nil
    }
}
