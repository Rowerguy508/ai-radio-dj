import Foundation

/// How a DJ break ended. The player applies this immediately; it does not wait out a deadline.
/// How the clip player ended a break, before it becomes a narration event.
public enum BreakPlayerOutcome: Equatable, Sendable {
    case finished
    case failed
    case cancelled
    /// Consent revoke cut the clip. Not a natural finish and not a playback failure.
    case revoked
}

public enum NarrationEnd: Equatable, Sendable {
    case finished
    case failed
    case cancelled
    /// Consent revoke cut a clip that was already playing. Not a natural end.
    case revoked
    /// Nothing was prepared, or preparation was too late.
    case skipped
}

public enum NarrationPlaybackEvent: Equatable, Sendable {
    case finished
    case cancelled
    case failed
}

/// Return to music, and whether music may start on its own.
public struct NarrationResumeDecision: Equatable, Sendable {
    /// False when the user paused or the system is still holding playback.
    public let resumeMusic: Bool
    /// Nil when the audio state is already music or idle. Otherwise one event back to music.
    public let audioEvent: AudioEvent?
    public let playbackEvent: NarrationPlaybackEvent

    public init(resumeMusic: Bool, audioEvent: AudioEvent?, playbackEvent: NarrationPlaybackEvent) {
        self.resumeMusic = resumeMusic
        self.audioEvent = audioEvent
        self.playbackEvent = playbackEvent
    }
}

/// What plays when a DJ break ends.
public enum MusicAfterBreak: Equatable, Sendable {
    /// Play the entry that is already current.
    case resumeCurrentEntry
    /// The entry that just finished must not play again. Load the next song.
    case startNextTrack
    case hold
}

public enum NarrationResumePolicy {
    /// A finished entry is never resumed. When playback is still allowed, the next track starts.
    /// A break that did not finish the entry resumes that entry only when auto-resume is allowed.
    public static func musicAfterBreak(
        entryAlreadyFinished: Bool,
        mayAutoResume: Bool,
        queueHasEntry: Bool
    ) -> MusicAfterBreak {
        guard mayAutoResume else { return .hold }
        if entryAlreadyFinished { return .startNextTrack }
        return queueHasEntry ? .resumeCurrentEntry : .hold
    }

    /// A clip that fails is a failure. A user stop or a timeout is a cancel.
    public static func narrationEnd(for outcome: BreakPlayerOutcome) -> NarrationEnd {
        switch outcome {
        case .finished:
            .finished
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        case .revoked:
            .revoked
        }
    }

    public static func decide(_ end: NarrationEnd, mayAutoResume: Bool, phase: AudioState) -> NarrationResumeDecision {
        let playbackEvent: NarrationPlaybackEvent
        switch end {
        case .finished:
            playbackEvent = .finished
        case .failed:
            playbackEvent = .failed
        case .cancelled, .skipped:
            playbackEvent = .cancelled
        case .revoked:
            playbackEvent = .cancelled
        }
        return NarrationResumeDecision(
            resumeMusic: mayAutoResume,
            audioEvent: audioEvent(for: phase),
            playbackEvent: playbackEvent
        )
    }

    /// One transition back to music. A failure does not stay in `.voice` or `.transition`.
    public static func audioEvent(for phase: AudioState) -> AudioEvent? {
        switch phase {
        case .voice: .interludeEnded
        case .transition: .noInterlude
        case .music, .idle: nil
        }
    }
}

public enum BreakHandoff: Equatable, Sendable {
    case play(PreparedDJBreak)
    case continueMusic
}

/// The boundary either plays one prepared break or continues music. A skip is one transition.
public enum BreakHandoffPolicy {
    public static func decide(prepared: PreparedDJBreak?) -> BreakHandoff {
        guard let prepared else { return .continueMusic }
        let line = prepared.cues.map(\.text).joined(separator: " ")
        guard !prepared.clips.isEmpty, !line.isEmpty else { return .continueMusic }
        return .play(prepared)
    }

    public static func decide(_ outcome: DJBreakOutcome) -> BreakHandoff {
        if case let .ready(prepared) = outcome {
            return decide(prepared: prepared)
        }
        return .continueMusic
    }
}

/// Why a prepared break was handed to the player and never started audio.
public enum HandedOutBreakSkip: Equatable, Sendable {
    /// PlayerView refused an empty line or empty clips.
    case emptyLine
    /// The adapter refused to start: already speaking, an empty line, or no clips.
    case notPlayable
    /// The clips did not decode.
    case decodeFailed
}

/// `.playbackFailed` for that break, plus the transition back to music.
/// The song has ended and voice never started, so the phase is `.transition`.
public struct HandedOutBreakEffect: Equatable, Sendable {
    public var event: DJPresentationEvent
    public var resume: NarrationResumeDecision

    public init(event: DJPresentationEvent, resume: NarrationResumeDecision) {
        self.event = event
        self.resume = resume
    }
}

public enum HandedOutBreakReport {
    /// Every path reports the same failure. DJ state leaves `.ready`. Music resumes
    /// from the boundary when auto-resume is allowed.
    public static func skipped(
        _ reason: HandedOutBreakSkip,
        afterTrack: Int,
        mayAutoResume: Bool
    ) -> HandedOutBreakEffect {
        switch reason {
        case .emptyLine, .notPlayable, .decodeFailed:
            return HandedOutBreakEffect(
                event: .playbackFailed(afterTrack: afterTrack),
                resume: NarrationResumePolicy.decide(.failed, mayAutoResume: mayAutoResume, phase: .transition)
            )
        }
    }
}

/// Whether `play` may start a clip. A system hold refuses through the unplayed report.
///
/// `pausedBySystem` is the route-removal or interruption hold on `PlaybackIntent`.
/// `mayAutoResume` and `phase` are the player's existing flags. A refusal never
/// asks music to resume, including when `mayAutoResume` is still true.
public struct BreakPlayAdmission: Equatable, Sendable {
    public var startAudio: Bool
    public var unplayed: HandedOutBreakEffect?

    public init(startAudio: Bool, unplayed: HandedOutBreakEffect?) {
        self.startAudio = startAudio
        self.unplayed = unplayed
    }
}

public enum BreakPlayAdmissionPolicy {
    public static func decide(
        pausedBySystem: Bool,
        mayAutoResume: Bool,
        phase: AudioState,
        afterTrack: Int
    ) -> BreakPlayAdmission {
        guard pausedBySystem else {
            return BreakPlayAdmission(startAudio: true, unplayed: nil)
        }
        let skipped = HandedOutBreakReport.skipped(
            .notPlayable, afterTrack: afterTrack, mayAutoResume: false)
        let live = NarrationResumePolicy.decide(
            .failed,
            mayAutoResume: mayAutoResume && !pausedBySystem,
            phase: phase
        )
        let effect = HandedOutBreakEffect(
            event: skipped.event,
            resume: NarrationResumeDecision(
                resumeMusic: false,
                audioEvent: live.audioEvent,
                playbackEvent: live.playbackEvent
            )
        )
        return BreakPlayAdmission(startAudio: false, unplayed: effect)
    }
}
