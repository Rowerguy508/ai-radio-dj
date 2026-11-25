import Foundation

/// #304 R2 (-Atlas): one bounded retry for a post-break resume that failed in the background.
///
/// After a DJ break, `MusicKitService.resumeIfAllowed` starts the music again. If the app is in the
/// background, `setActive` or `play()` can throw there. The failure is already surfaced as a visible
/// error; this policy adds exactly one retry when the app comes back to the foreground.
///
/// Rules, all pure so they are tested on Linux:
/// - Only a post-break resume that failed while the app was in the background arms a retry.
/// - Back in the foreground, the armed retry runs once, and only if nothing happened in between:
///   the failed attempt is still the current one (no tap, skip, Play, Stop or next song began a
///   new start), the queue generation is unchanged, and the user still wants playback.
/// - A failed retry never arms another one. The existing visible error stays.
/// - A retry that MusicKit confirms clears the error it was retrying.
/// - A user pause or a new queue drops any armed retry.
public struct ForegroundResumeRetry: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case foreground
        case background
    }

    /// The failed post-break resume that may be retried once in the foreground.
    public struct Pending: Equatable, Sendable {
        public let failedAttempt: PlaybackAttemptID
        public let generation: Int
    }

    public enum FailureDecision: Equatable, Sendable {
        /// Keep the visible error. Nothing more happens.
        case keepError
        /// Keep the visible error, and retry once when the app returns to the foreground.
        case keepErrorRetryInForeground
    }

    public enum DropReason: Equatable, Sendable {
        /// A newer start (or a Stop) replaced the failed attempt.
        case attemptSuperseded
        /// The user replaced the queue or skipped.
        case queueChanged
        /// The user paused, or the system holds playback.
        case mayNotAutoResume
    }

    public enum ForegroundDecision: Equatable, Sendable {
        /// No failed post-break resume is armed.
        case none
        /// Run the post-break resume once more.
        case retryResume
        /// A retry was armed, but something changed since the failure: no retry.
        case dropped(DropReason)
    }

    public private(set) var phase: Phase = .foreground
    public private(set) var pending: Pending?
    /// The foreground decided to retry; the next start that begins is that retry.
    public private(set) var retryRequested = false
    /// The start that is the retry. Its failure is final; its confirmation clears the error.
    public private(set) var retryAttempt: PlaybackAttemptID?
    /// A DJ break ended and handed the music back: the next automatic resume is the post-break one.
    public private(set) var breakResumeDue = false

    public init() {}

    public mutating func sceneEnteredBackground() {
        phase = .background
    }

    /// A DJ break ended (`completeNarration`). `resumesMusic` is the break's resume decision.
    public mutating func breakEnded(resumesMusic: Bool) {
        breakResumeDue = resumesMusic
    }

    /// Asked once by each automatic resume, before it begins a start: true for the resume that
    /// follows a break. Consumed either way, so a later interruption resume is not post-break.
    public mutating func takeBreakResume() -> Bool {
        defer { breakResumeDue = false }
        return breakResumeDue
    }

    /// Back in the foreground. Consumes any armed retry, whatever the decision.
    public mutating func sceneBecameActive(current: PlaybackAttemptID?, generation: Int,
                                           mayAutoResume: Bool) -> ForegroundDecision {
        phase = .foreground
        guard let armed = pending else { return .none }
        pending = nil
        guard current == armed.failedAttempt else { return .dropped(.attemptSuperseded) }
        guard generation == armed.generation else { return .dropped(.queueChanged) }
        guard mayAutoResume else { return .dropped(.mayNotAutoResume) }
        retryRequested = true
        return .retryResume
    }

    /// A start began. The first one after `.retryResume` is the retry; any other start is something
    /// new (a tap, a skip, Play, the next song), so an armed retry no longer applies.
    public mutating func attemptBegan(_ attempt: PlaybackAttemptID) {
        if retryRequested {
            retryRequested = false
            retryAttempt = attempt
        } else {
            retryAttempt = nil
        }
        pending = nil
        breakResumeDue = false
    }

    /// The foreground retry returned without beginning a start (a skip owns the player, the policy
    /// no longer allows a resume, or a start is already preparing).
    public mutating func retryReturned() {
        retryRequested = false
    }

    /// An automatic resume threw for `attempt`. `afterBreak` is true for the resume that follows a DJ break.
    public mutating func resumeFailed(attempt: PlaybackAttemptID, generation: Int,
                                      afterBreak: Bool) -> FailureDecision {
        if attempt == retryAttempt {
            // The one retry failed: final. The visible error stays; nothing is armed again.
            retryAttempt = nil
            return .keepError
        }
        guard afterBreak, phase == .background else { return .keepError }
        pending = Pending(failedAttempt: attempt, generation: generation)
        return .keepErrorRetryInForeground
    }

    /// MusicKit confirmed `attempt` playing. True when it was the retry: the error it retried is cleared.
    public mutating func confirmed(_ attempt: PlaybackAttemptID) -> Bool {
        guard attempt == retryAttempt else { return false }
        retryAttempt = nil
        return true
    }

    /// The user paused, stopped or replaced the queue: nothing is retried for them.
    public mutating func userIntervened() {
        pending = nil
        retryRequested = false
        retryAttempt = nil
        breakResumeDue = false
    }
}
