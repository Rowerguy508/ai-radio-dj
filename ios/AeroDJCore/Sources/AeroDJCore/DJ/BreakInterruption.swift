import Foundation

// DJ break interruptions (-Fry, owner-reported on the Duo: a Siri interruption mid-break left
// the DJ voice and Siri talking over each other). Pure: `InterludePlaybackAdapter` reports the
// break's line starts and the session's interruption notices, and executes the actions.
// Nothing here touches audio, MusicKit or the session. See docs/dj-break-interruption.md.
//
// NOT device-validated. Linux/simulator green is not device evidence.

/// Which kind of break is on air.
public enum BreakInterruptionKind: Equatable, Sendable {
    /// A gap break between two songs: music is already paused for it.
    case boundary
    /// A talk-over voice over the song's outro (`docs/dj-talkover.md`).
    case talkover
}

/// The one short line the DJ says when a paused break picks up again after an interruption.
public enum BreakInterruptionAcknowledgement {
    /// Orion's example wording for the owner's report. One constant; rendered on-device only.
    public static let line = "Sorry, little interruption there."
    /// Bound for the rendered clip: a longer clip is not used (the script resumes without it).
    public static let maxSeconds = 4
    /// No apology for a very short interruption (Echo, #379 N3): one that lasted less than this,
    /// from `.began` to `.ended`, resumes the script at once with no acknowledgement. 2 s covers
    /// a blip (a notification sound, a Siri call that is cancelled at once) without hiding a real
    /// interruption, where a listener noticed the gap. Exactly 2 s or longer is apologized for.
    public static let minInterruptionSeconds: Double = 2

    /// The cue the app renders. A local-only cue (no attribution): `VoiceRenderer` sends it to
    /// on-device, free routes only, so no paid or cloud voice is ever asked for it.
    public static func cue(id: UUID = UUID()) -> NarrationCue {
        NarrationCue(id: id, order: 0, group: 0, kind: .transition, text: line,
                     estimatedSeconds: 2, maxSeconds: maxSeconds, sourceItemID: nil, source: nil, provenance: nil)
    }
}

/// The state machine for one break across system interruptions (Siri, a call, an alarm).
///
/// - `.began` while a gap break speaks: pause the voice AND the break timeline (no timeout, no
///   ramp, no next line) and remember the line that was interrupted.
/// - `.ended` with `shouldResume`: one short acknowledgement (`BreakInterruptionAcknowledgement`),
///   then the planned script again FROM THE INTERRUPTED LINE (that line restarts from its
///   beginning). No acknowledgement clip ready: the script resumes at once (music never waits).
///   No acknowledgement for an interruption shorter than
///   `BreakInterruptionAcknowledgement.minInterruptionSeconds`, and at most ONE per break: a
///   later interruption in the same break resumes without one (#379 N3). Lines that are no
///   longer true when the script resumes (a time check past its window) are dropped by
///   `BreakResumePlan`, not by this machine.
/// - `.ended` without `shouldResume`, or no `.ended` within `maxPausedSeconds`: stays held;
///   nothing restarts on its own.
/// - Talk-over: the voice is pinned to the song's outro, which moved on while the system held
///   the music, so the talk-over voice stops cleanly at `.began` and is never replayed.
/// - Notices with no break on air, a second `.began` or a second `.ended` change nothing.
public struct BreakInterruptionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No break on air.
        case idle
        /// Line `line` of the break's script is (or is about to be) on air.
        case speaking(line: Int)
        /// The acknowledgement is playing; the script resumes at `resumeLine` after it.
        case acknowledging(resumeLine: Int)
        /// An interruption is ongoing; everything is paused at `line`.
        case paused(line: Int)
        /// The interruption ended without `shouldResume`: held at `line`, nothing restarts.
        case held(line: Int)
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Pause the voice that is playing (a script line or the acknowledgement) and freeze the
        /// break timeline: cancel the timeout and voice ramps, start no next clip.
        case pause(line: Int)
        /// Talk-over: stop the voice now (the break ends as cancelled and is not replayed).
        case stopTalkover
        /// Play the acknowledgement, then report `acknowledgementEnded()`.
        case playAcknowledgement(thenLine: Int)
        /// Play the script again from line `fromLine` (restarted from its beginning) to the end.
        case resume(fromLine: Int)
        /// Stay paused. Nothing restarts on its own.
        case stayPaused(line: Int)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var kind: BreakInterruptionKind = .boundary
    /// The acknowledgement already started in this break (at most one per break).
    public private(set) var apologized = false
    /// When the current interruption began (caller's monotonic seconds).
    private var beganAt: Double = 0

    public init() {}

    /// True while an interruption holds the break (paused or held). Read-only and observable
    /// for the stop detection in #373 (Echo): while this is true the app itself holds the DJ
    /// voice; MusicKit is never paused, cleared or rewound by this machine.
    public var isHolding: Bool {
        switch phase {
        case .paused, .held: return true
        case .idle, .speaking, .acknowledging: return false
        }
    }

    /// A break's audio really started (its first line).
    public mutating func breakStarted(_ kind: BreakInterruptionKind) {
        self.kind = kind
        phase = .speaking(line: 0)
        apologized = false
    }

    /// Script line `index` started. Only tracked while speaking (the acknowledgement and a
    /// paused break never move the line).
    public mutating func lineStarted(_ index: Int) {
        guard case .speaking = phase, index >= 0 else { return }
        phase = .speaking(line: index)
    }

    /// The break ended (finished, failed, cancelled or revoked): back to idle.
    public mutating func breakEnded() {
        phase = .idle
        kind = .boundary
        apologized = false
    }

    /// `AVAudioSession.interruptionNotification` `.began`, at `uptime` (monotonic seconds).
    public mutating func interruptionBegan(at uptime: Double) -> Action {
        switch phase {
        case .idle, .paused, .held:
            return .none
        case .speaking(let line):
            if kind == .talkover {
                phase = .idle
                return .stopTalkover
            }
            phase = .paused(line: line)
            beganAt = uptime
            return .pause(line: line)
        case .acknowledging(let resumeLine):
            // The acknowledgement itself was interrupted: the script line is still owed. The
            // apology counts as said (at most one per break): it is not played again.
            phase = .paused(line: resumeLine)
            beganAt = uptime
            return .pause(line: resumeLine)
        }
    }

    /// `.ended` at `uptime` (same clock as `interruptionBegan`). `acknowledgementReady`: an
    /// acknowledgement clip is decoded and playable now. The acknowledgement plays only when it
    /// is ready, none was played in this break yet, and the interruption lasted at least
    /// `BreakInterruptionAcknowledgement.minInterruptionSeconds`.
    public mutating func interruptionEnded(shouldResume: Bool, acknowledgementReady: Bool, at uptime: Double) -> Action {
        guard case .paused(let line) = phase else { return .none }
        guard shouldResume else {
            phase = .held(line: line)
            return .stayPaused(line: line)
        }
        let long = uptime - beganAt >= BreakInterruptionAcknowledgement.minInterruptionSeconds
        if acknowledgementReady, !apologized, long {
            apologized = true
            phase = .acknowledging(resumeLine: line)
            return .playAcknowledgement(thenLine: line)
        }
        phase = .speaking(line: line)
        return .resume(fromLine: line)
    }

    /// The longest a break stays paused waiting for `.ended` (Apple does not promise an
    /// `.ended` for every `.began`). Then it is dropped as for an end without `shouldResume`,
    /// so no break stays open; `MusicKitService` resumes music at a later `.ended` as before.
    public static let maxPausedSeconds: Double = 45

    /// No `.ended` within `maxPausedSeconds`: held, nothing restarts.
    public mutating func pauseExpired() -> Action {
        guard case .paused(let line) = phase else { return .none }
        phase = .held(line: line)
        return .stayPaused(line: line)
    }

    /// The acknowledgement finished (or could not play): the script resumes.
    public mutating func acknowledgementEnded() -> Action {
        guard case .acknowledging(let line) = phase else { return .none }
        phase = .speaking(line: line)
        return .resume(fromLine: line)
    }
}

// MARK: - Resume validity (#379 N1, Echo)

/// What a resumed script needs to know about one of its lines (one per clip, in play order).
public struct BreakResumeLine: Equatable, Sendable {
    public enum Sensitivity: Equatable, Sendable {
        /// Still true whenever it airs.
        case none
        /// A time check: its plan, the words rendered, and the air time they were written for
        /// (`PreparedDJBreak.timeCheckAirTime`). Re-checked with the take-time rule
        /// (`DJBreakPreparer.timeCheckStillTrue`) at the moment it would air after the resume.
        case timeCheck(DJPlannedTimeCheck, text: String, airTime: Date?)
    }

    /// The clip's rendered length, in seconds.
    public let seconds: Double
    public let sensitivity: Sensitivity

    public init(seconds: Double, sensitivity: Sensitivity = .none) {
        self.seconds = seconds
        self.sensitivity = sensitivity
    }

    /// One line per clip of `prepared`, in clip order. The time-check clip (when it is still in
    /// the break, `PreparedDJBreak.timeCheck`) carries its plan, words and air time.
    public static func lines(for prepared: PreparedDJBreak) -> [BreakResumeLine] {
        prepared.clips.map { clip in
            guard let check = prepared.timeCheck, clip.cueID == check.cueID else {
                return BreakResumeLine(seconds: clip.audio.seconds)
            }
            let text = prepared.cues.first { $0.id == check.cueID }?.text ?? ""
            return BreakResumeLine(seconds: clip.audio.seconds,
                                   sensitivity: .timeCheck(check, text: text, airTime: prepared.timeCheckAirTime))
        }
    }

    /// Whether the line is still true if it starts airing at `date`.
    public func stillTrue(airingAt date: Date) -> Bool {
        switch sensitivity {
        case .none: return true
        case .timeCheck(let check, let text, let airTime):
            return DJBreakPreparer.timeCheckStillTrue(check, saying: text, airTime: airTime, now: date)
        }
    }

    var dropKind: BreakResumeDrop.Kind {
        if case .timeCheck = sensitivity { return .timeCheck }
        return .other
    }
}

/// Lines of a paused break that did not air, by kind, and why (#379 N2, for the P0 trace).
/// Counts and codes only; no text.
public struct BreakResumeDrop: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case timeCheck, other }

    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// On resume, a time-sensitive line was past its window and was skipped; the rest aired.
        case stale
        /// On resume, every line still to play was past its window: the break was dropped.
        case allStale
        /// `.ended` without `shouldResume`: the break was dropped.
        case noResume
        /// `.ended` with `shouldResume` while the listener already had music playing.
        case musicPlaying
        /// No `.ended` within `BreakInterruptionState.maxPausedSeconds`.
        case pauseExpired
    }

    public let reason: Reason
    /// The line the break was paused at.
    public let line: Int
    public let timeChecks: Int
    public let other: Int
    public var count: Int { timeChecks + other }
    /// Whether the whole break was dropped (no line from `line` on aired).
    public var breakDropped: Bool { reason != .stale }

    public init(reason: Reason, line: Int, timeChecks: Int, other: Int) {
        self.reason = reason
        self.line = line
        self.timeChecks = timeChecks
        self.other = other
    }

    /// Every line from `line` on, dropped for `reason`.
    public static func remaining(_ lines: [BreakResumeLine], from line: Int, reason: Reason) -> BreakResumeDrop {
        let rest = lines.indices.contains(line) ? Array(lines[line...]) : []
        let checks = rest.filter { $0.dropKind == .timeCheck }.count
        return BreakResumeDrop(reason: reason, line: line, timeChecks: checks, other: rest.count - checks)
    }
}

/// Which lines a resumed break still plays (#379 N1, Echo: a time check resumed after a pause
/// could air up to ~49 s late and name the wrong minute). Each line from the interrupted one on
/// is checked at the moment it would START airing: `now`, plus `leadSeconds` (the
/// acknowledgement, when it plays first), plus the kept lines before it. A time check that is
/// no longer true then (`DJBreakPreparer.timeCheckStillTrue`, the same rule as at the take:
/// within `timeCheckTolerance` of its air time and its rounded-time claim still true) is
/// dropped rather than spoken; other lines always play. Pure; the caller reads the clock.
public struct BreakResumePlan: Equatable, Sendable {
    /// Script line indices to play, in order.
    public let lines: [Int]
    /// What was dropped, when anything was (`.stale`, or `.allStale` when nothing is left).
    public let drop: BreakResumeDrop?

    public static func plan(from line: Int, lines: [BreakResumeLine], now: Date, leadSeconds: Double = 0) -> BreakResumePlan {
        guard line >= 0, line < lines.count else { return BreakResumePlan(lines: [], drop: nil) }
        var kept: [Int] = [], checks = 0, other = 0
        var offset = max(0, leadSeconds)
        for index in line..<lines.count {
            let entry = lines[index]
            if entry.stillTrue(airingAt: now.addingTimeInterval(offset)) {
                kept.append(index)
                offset += max(0, entry.seconds)
            } else if entry.dropKind == .timeCheck {
                checks += 1
            } else {
                other += 1
            }
        }
        guard checks + other > 0 else { return BreakResumePlan(lines: kept, drop: nil) }
        let reason: BreakResumeDrop.Reason = kept.isEmpty ? .allStale : .stale
        return BreakResumePlan(lines: kept, drop: BreakResumeDrop(reason: reason, line: line, timeChecks: checks, other: other))
    }
}
