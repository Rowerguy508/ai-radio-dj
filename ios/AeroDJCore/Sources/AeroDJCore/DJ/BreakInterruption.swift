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
    }

    /// `AVAudioSession.interruptionNotification` `.began`.
    public mutating func interruptionBegan() -> Action {
        switch phase {
        case .idle, .paused, .held:
            return .none
        case .speaking(let line):
            if kind == .talkover {
                phase = .idle
                return .stopTalkover
            }
            phase = .paused(line: line)
            return .pause(line: line)
        case .acknowledging(let resumeLine):
            // The acknowledgement itself was interrupted: the script line is still owed.
            phase = .paused(line: resumeLine)
            return .pause(line: resumeLine)
        }
    }

    /// `.ended`. `acknowledgementReady`: an acknowledgement clip is decoded and playable now.
    public mutating func interruptionEnded(shouldResume: Bool, acknowledgementReady: Bool) -> Action {
        guard case .paused(let line) = phase else { return .none }
        guard shouldResume else {
            phase = .held(line: line)
            return .stayPaused(line: line)
        }
        if acknowledgementReady {
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
