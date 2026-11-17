import Foundation

/// What an awaited skip step may tell `SkipCoordinator`.
///
/// A throw is a `.failed` only while this attempt and queue generation still own the load.
/// A newer Play in the same generation, or a replaced queue, is `.cancelled` before the
/// coordinator can retry, run a stored Next, or surface an error.
public enum SkipStepOutcome {
    public static func admit(
        _ result: SkipLoadResult,
        attempt: PlaybackAttemptID?,
        generation: Int,
        attempts: PlaybackAttempts
    ) -> SkipLoadResult {
        guard attempts.ownsLoad(attempt: attempt, generation: generation) else {
            return .cancelled
        }
        return result
    }
}
