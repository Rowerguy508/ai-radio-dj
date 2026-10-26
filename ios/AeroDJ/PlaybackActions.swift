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
    /// `briefing` is read when play starts. The default is unapproved, so nothing personal
    /// airs until a caller passes an `ApprovedShowHandoff`. Morning passes that handoff;
    /// a later show passes only `carryForward.eligibleNextShow`.
    static func live(_ music: MusicKitService, station: StationRef, djSession: DJBreakSession,
                     briefing: @escaping () -> ApprovedShowHandoff = { .unapproved }) -> MusicSearch {
        let cache = SearchResultCache()
        return MusicSearch(
            search: { query in
                let tracks = try await music.search(query)
                cache.store(tracks)
                return tracks.map(\.info)
            },
            play: { results, startIndex in
                guard results.indices.contains(startIndex) else { return }
                let tracks = results[startIndex...].compactMap { cache.track(for: $0.id) }
                await djSession.queueStarted(
                    tracks.map { DJTrack(id: $0.id, title: $0.title, artist: $0.artistName) },
                    briefing: briefing().forQueue())
                try await music.play(tracks, station: station)
            })
    }
}

/// Keeps the MusicKit tracks behind the UI-facing `TrackInfo` results. Main actor only.
@MainActor
private final class SearchResultCache {
    private var tracks: [String: Track] = [:]
    func store(_ list: [Track]) { tracks = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    func track(for id: String) -> Track? { tracks[id] }
}
