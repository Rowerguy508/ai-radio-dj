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
    /// The real Apple Music permission request (`MusicKitService.authorize()`). Bound to the
    /// "Allow" button of a `.notAuthorized` error, so that button is never a no-op.
    var authorize: () async -> Void = {}
    /// Up Next edits. `nil` means editing is not available: the UI must hide the
    /// controls rather than show them and change nothing. Live stays `nil` until the
    /// app applies the same edit to MusicKit's queue, which needs SDK verification.
    var editUpNext: ((UpNextEdit) -> Void)? = nil

    /// Bound to the one app-wide `MusicKitService`.
    static func live(_ music: MusicKitService) -> PlaybackActions {
        PlaybackActions(
            pause: { music.pause() },
            // resume raises a snapshot error before throwing; try? only drops the throw.
            resume: { _ = try? await music.resume() },
            skip: { _ = try? await music.skip() },
            dismissError: { music.dismissError() },
            authorize: { await music.authorize() }
        )
    }

    /// For SwiftUI previews and UI tests. Does nothing; edits are accepted and ignored.
    static let preview = PlaybackActions(
        pause: {},
        resume: {},
        skip: {},
        dismissError: {},
        authorize: {},
        editUpNext: nil
    )
}

/// Starting music: the real Apple Music catalog search and `play(_:station:)`. Playing a
/// result queues it and the results after it, replacing the current queue.
@MainActor
struct MusicSearch {
    let search: (String) async throws -> [TrackInfo]
    let play: (_ results: [TrackInfo], _ startIndex: Int) async throws -> Void

    /// Same path as #58's search (ebc3042): the DJ session learns the new queue (the tapped
    /// song and the ones after it), then the player loads it one song at a time.
    ///
    /// The MusicKit `Track` cache lives on `music` (`searchResults`), not in this value, so
    /// `PlayerView` may rebuild `.live(music, …)` on every body without wiping hits (P0 build 7).
    ///
    /// `briefing` is read when play starts. There is no default: omitting it does not
    /// compile, so an unapproved handoff cannot slip back in. `PlayerView` passes
    /// `LiveQueueBriefing.provider`, which speaks an approved morning row and nothing else.
    static func live(_ music: MusicKitService, station: StationRef, djSession: DJBreakSession,
                     briefing: @escaping @MainActor () -> ApprovedShowHandoff) -> MusicSearch {
        return MusicSearch(
            search: { query in
                let tracks = try await music.search(query)
                music.searchResults.store(tracks)
                return tracks.map(\.info)
            },
            play: { results, startIndex in
                // Resolve before touching the DJ session. Out-of-range / expired cache throw a
                // visible TEMPORARY error; queueStarted never runs with an empty queue.
                let tracks = try music.searchResults.resolve(results: results, startIndex: startIndex)
                let handoff = briefing()
                await djSession.queueStarted(
                    tracks.map { DJTrack(id: $0.id, title: $0.title, artist: $0.artistName) },
                    briefing: handoff.forQueue(), sources: handoff.connectionItems)
                try await music.play(tracks, station: station)
            })
    }
}
