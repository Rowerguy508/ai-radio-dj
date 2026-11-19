import Foundation

// #388 (-Nova): a never while the DJ speaks. Every decision here is by song ID from the cue's own
// `SpokenAttribution.trackMetadata(trackIDs:)` (Echo, #388): no title matching, no new field.
// Editorial connectors, presenter lines, station IDs and briefing items never name a song, so
// they never match. Pure, so the order of start, rating, fade and end is tested on Linux.
// Nothing here logs a song, a title, an artist or a rating.

/// One spoken line of a prepared break, in clip order: the songs its words name, and whether it
/// is a briefing item (`NarrationCue.isContent`). Never the text.
public struct StationRatingBreakLine: Equatable, Sendable {
    public let trackIDs: Set<String>
    public let isBriefing: Bool

    public init(trackIDs: Set<String> = [], isBriefing: Bool = false) {
        self.trackIDs = trackIDs
        self.isBriefing = isBriefing
    }

    /// Whether this line speaks any of `songIDs`.
    public func names(_ songIDs: Set<String>) -> Bool { !trackIDs.isDisjoint(with: songIDs) }

    /// One per clip, in clip order (same order and count as `BreakResumeLine.lines(for:)`).
    public static func lines(for prepared: PreparedDJBreak) -> [StationRatingBreakLine] {
        prepared.clips.map { clip in
            let briefing = prepared.cues.first { $0.id == clip.cueID }?.isContent ?? false
            guard case .trackMetadata(let ids, _)? = prepared.attributions[clip.cueID] else {
                return StationRatingBreakLine(isBriefing: briefing)
            }
            return StationRatingBreakLine(trackIDs: Set(ids), isBriefing: briefing)
        }
    }
}

/// Narrows a prepared break to the lines that do not name an excluded song (Echo's #387 N2: a
/// rating cuts only the cues that name the song, not briefing items or a time check). Nil when
/// no line is left. The rebuild matches `DJBreakSession.naturalBoundary`'s stale-next filter:
/// the talk-over closing and the time check are kept only if their cue survived.
public enum StationRatingBreakNarrowing {
    public static func names(_ cue: NarrationCue, in prepared: PreparedDJBreak, _ songIDs: Set<String>) -> Bool {
        guard !songIDs.isEmpty, case .trackMetadata(let ids, _)? = prepared.attributions[cue.id] else { return false }
        return !songIDs.isDisjoint(with: ids)
    }

    /// Echo's #396 room N1: what `narrowed` drops, by kind, for the P0 trace. Nil when no cue names
    /// one of `songIDs` (nothing is narrowed, no row).
    public static func droppedCounts(_ prepared: PreparedDJBreak, excluding songIDs: Set<String>) -> ExcludedCueCounts? {
        let dropped = prepared.cues.filter { names($0, in: prepared, songIDs) }
        guard !dropped.isEmpty else { return nil }
        return ExcludedCueCounts(dropped: dropped, timeCheckCueID: prepared.timeCheck?.cueID,
                                 kept: prepared.cues.count - dropped.count)
    }

    public static func narrowed(_ prepared: PreparedDJBreak, excluding songIDs: Set<String>) -> PreparedDJBreak? {
        let cues = prepared.cues.filter { !names($0, in: prepared, songIDs) }
        guard cues.count != prepared.cues.count else { return prepared }
        guard !cues.isEmpty else { return nil }
        let kept = Set(cues.map(\.id))
        var rest = PreparedDJBreak(
            afterTrack: prepared.afterTrack, cues: cues, clips: prepared.clips.filter { kept.contains($0.cueID) },
            attributions: prepared.attributions.filter { kept.contains($0.key) },
            talkOverCueID: prepared.talkOverCueID.flatMap { kept.contains($0) ? $0 : nil })
        if let check = prepared.timeCheck, kept.contains(check.cueID) {
            rest.timeCheck = check
            rest.timeCheckAirTime = prepared.timeCheckAirTime
        }
        rest.droppedTimeCheck = prepared.droppedTimeCheck
        return rest
    }
}

/// A talk-over on air when a song is rated never (#388, Orion's spec). One per talk-over voice.
/// - The line speaking now names an excluded song: fade it (`TalkoverVoiceRamp.fadeSeconds`) and
///   drop the rest of the break, once.
/// - It does not: it plays on. Later lines of the same talk-over that name the song are dropped
///   before they start (they would otherwise speak a song the listener just ruled out).
/// - Not speaking (never started, ended, stopped, or stopped by an interruption): nothing.
public struct StationRatingTalkoverCut: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Fade the speaking line and drop the rest of the break. Counts from the faded line on.
        case fadeAndDropBreak(afterTrack: Int, StationRatingWithdrawnLines)
        /// Drop these queued (not yet started) lines; the speaking line plays on.
        case dropQueued(afterTrack: Int, lines: [Int])
    }

    public private(set) var afterTrack: Int?
    public private(set) var lines: [StationRatingBreakLine] = []
    private var resumeLines: [BreakResumeLine] = []
    private var droppedLines: Set<Int> = []
    /// The break was already faded and dropped: never twice.
    public private(set) var faded = false

    public init() {}

    /// The talk-over voice for boundary `k` started. `lines` and `resumeLines`: one per clip
    /// handed to the voice, in order (other counts: no line is known to name a song, and the
    /// counts fall back to `other`).
    public mutating func speechStarted(afterTrack k: Int, lines: [StationRatingBreakLine],
                                       resumeLines: [BreakResumeLine] = []) {
        afterTrack = k
        self.lines = lines
        self.resumeLines = resumeLines.count == lines.count ? resumeLines : []
        droppedLines = []
        faded = false
    }

    /// The voice ended for any reason (finished, failed, faded, stopped, interrupted).
    public mutating func speechEnded() {
        self = StationRatingTalkoverCut()
    }

    /// The listener's ratings changed. `excluded`: songs the station now leaves out, still queued.
    /// `speakingLine`: the talk-over line on air now (nil: no talk-over voice is on air).
    public mutating func ratingChanged(excluded: Set<String>, speakingLine: Int?) -> Action {
        guard let k = afterTrack, !faded, !excluded.isEmpty, let i = speakingLine, lines.indices.contains(i) else {
            return .none
        }
        if lines[i].names(excluded) {
            faded = true
            let kinds = resumeLines.isEmpty ? lines.map { _ in BreakResumeLine(seconds: 0) } : resumeLines
            let left = Array(lines.indices[i...]).filter { $0 == i || !droppedLines.contains($0) }
            let rest = StationRatingWithdrawnLines.remaining(left.map { kinds[$0] }, from: 0,
                                                             ratingLines: left.map { lines[$0] })
            return .fadeAndDropBreak(afterTrack: k, StationRatingWithdrawnLines(
                line: i, timeChecks: rest.timeChecks, other: rest.other, briefing: rest.briefing))
        }
        let queued = lines.indices.filter { $0 > i && !droppedLines.contains($0) && lines[$0].names(excluded) }
        guard !queued.isEmpty else { return .none }
        droppedLines.formUnion(queued)
        return .dropQueued(afterTrack: k, lines: queued)
    }
}
