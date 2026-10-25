import Foundation
import AeroDJCore

/// What the UI may ask playback to do. Views receive a `PlaybackSnapshot` and this
/// value; they never hold MusicKit or the engine. Previews pass `.preview`.
@MainActor
struct PlaybackActions {
    let pause: () -> Void
    let resume: () async -> Void
    let skip: () async -> Void
    let dismissError: () -> Void
    /// Up Next edits. `nil` means editing is not available: the UI must hide the
    /// controls rather than show them and change nothing. Live stays `nil` until the
    /// app applies the same edit to MusicKit's queue, which needs SDK verification.
    var editUpNext: ((UpNextEdit) -> Void)? = nil

    /// Bound to the one app-wide `MusicKitService`.
    static func live(_ music: MusicKitService) -> PlaybackActions {
        PlaybackActions(
            pause: { music.pause() },
            resume: { _ = try? await music.resume() },
            skip: { _ = try? await music.skip() },
            dismissError: { music.dismissError() }
        )
    }

    /// For SwiftUI previews and UI tests. Does nothing; edits are accepted and ignored.
    static let preview = PlaybackActions(
        pause: {},
        resume: {},
        skip: {},
        dismissError: {},
        editUpNext: { _ in }
    )
}
