import AeroDJCore

/// Maps an app error onto Core's `ThrownPlaybackFailure` so `PlaybackFailureCopy` picks the
/// banner (#136 follow-up). Reads only the case, never the error's own text, type or code.
extension ThrownPlaybackFailure {
    init(_ error: Error) {
        switch error {
        case let MusicKitError.playbackFailed(message):
            self = .carriesCopy(message)
        case MusicKitError.superseded:
            self = .superseded
        default:
            self = .unrecognized
        }
    }
}
