import Foundation

/// Why a play, resume or start did not reach playback, in terms the listener can act on (#133).
///
/// Same pattern as `SearchFailureCopy` (#124): the app picks the kind, this file owns the
/// words, so the copy is testable on Linux.
public enum PlaybackFailureKind: Equatable, Sendable, CaseIterable {
    /// Play was tapped with nothing to queue.
    case nothingToPlay
    /// Play was pressed with an empty queue.
    case nothingToResume
    /// The queue entry has no playable Apple Music song.
    case songUnavailable
    /// A pause or interruption hold kept the song from starting.
    case onHold
    /// The tapped result is no longer in the search results.
    case resultsExpired
    /// The 8 s start deadline passed and Apple Music is still not playing. Stop works from here.
    case slowStart
    /// Apple Music reported an interruption while the song was starting.
    case interrupted
    /// `prepareToPlay()`, `play()` or session activation failed.
    case couldNotStart
    /// The song ended or changed before it played.
    case stoppedEarly
    /// A newer tap, resume or skip replaced this start. Not shown as an error.
    case superseded
}

/// Fixed, plain-language copy for playback errors (#133). Never an error code, domain, type
/// name, attempt number, index, title or ID: every message is a constant string.
public enum PlaybackFailureCopy {
    public static let fallback = "Apple Music couldn't start this song. Try again."

    public static func message(for kind: PlaybackFailureKind) -> String {
        switch kind {
        case .nothingToPlay:
            "There's nothing to play yet. Pick a song to start listening."
        case .nothingToResume:
            "Nothing is queued. Pick a song to start listening."
        case .songUnavailable:
            "This song isn't available in Apple Music. Try another song."
        case .onHold:
            "Playback is on hold. Press Play when you're ready."
        case .resultsExpired:
            "These results have expired. Search again."
        case .slowStart:
            "Apple Music is taking longer than usual to start this song. Keep waiting, or press Stop."
        case .interrupted:
            "Something interrupted Apple Music before the song started. Press Stop, then try again."
        case .couldNotStart:
            fallback
        case .stoppedEarly:
            "The song stopped before it started playing. Try again, or pick another song."
        case .superseded:
            "Switched to your newer pick."
        }
    }
}
