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

    /// Bound to the one app-wide `MusicKitService`.
    static func live(_ music: MusicKitService) -> PlaybackActions {
        PlaybackActions(
            pause: { music.pause() },
            resume: { _ = try? await music.resume() },
            skip: { _ = try? await music.skip() },
            dismissError: { music.dismissError() }
        )
    }

    /// For SwiftUI previews and UI tests. Does nothing.
    static let preview = PlaybackActions(
        pause: {},
        resume: {},
        skip: {},
        dismissError: {}
    )
}
