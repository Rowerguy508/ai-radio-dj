import Foundation

/// P0 lock-screen skip (-Echo): what `MusicKitService`'s `nextTrackCommand` target does. The app's
/// MusicKit queue holds only the current song, so a Next the system handles itself has nothing to
/// skip to and just ends playback. When the target is reached, it runs the in-app skip; with no
/// next song in the app's queue it reports that there is nothing to act on and changes nothing.
public enum RemoteNextCommand: Equatable, Sendable {
    /// Run `MusicKitService.skip()`: the same path as the in-app Skip button.
    case skip
    /// The last song of the queue is playing (or nothing is). The command reports
    /// `.noActionableNowPlayingItem` and playback is left alone.
    case noNextSong

    public static func decide(queueIndex: Int, queueCount: Int) -> RemoteNextCommand {
        queueIndex >= 0 && queueIndex + 1 < queueCount ? .skip : .noNextSong
    }

    /// `nextTrackCommand.isEnabled`: true only while a next song is queued.
    public static func isEnabled(queueIndex: Int, queueCount: Int) -> Bool {
        decide(queueIndex: queueIndex, queueCount: queueCount) == .skip
    }
}
