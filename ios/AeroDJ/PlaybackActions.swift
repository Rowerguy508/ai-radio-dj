import Foundation
import OSLog
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

    #if DEBUG
    /// Capture harness only. Resume and a search play are counted and do not touch MusicKit.
    static let counting = PlaybackActions(
        pause: {},
        resume: { PlaybackCallLog.shared.recordPlay() },
        skip: {},
        dismissError: {},
        authorize: {},
        editUpNext: nil
    )
    #endif
}

#if DEBUG
/// Counts catalog search and queue play. A compact-to-regular change must leave both at zero.
/// Not main-actor isolated: the search and play closures are not `@MainActor`.
final class PlaybackCallLog: ObservableObject, @unchecked Sendable {
    static let shared = PlaybackCallLog()
    /// `plays/searches` — unchanged so existing UI tests keep matching `0/0`.
    @Published private(set) var label = "0/0"
    /// How many times `MusicKitService.authorize()` ran (permission request path).
    @Published private(set) var authorizeCount = 0
    private var plays = 0
    private var searches = 0
    private var authorizes = 0
    private let lock = NSLock()

    nonisolated func recordSearch() { bump(play: false) }
    nonisolated func recordPlay() { bump(play: true) }
    nonisolated func recordAuthorize() {
        lock.lock()
        authorizes += 1
        let next = authorizes
        lock.unlock()
        DispatchQueue.main.async { self.authorizeCount = next }
    }

    private nonisolated func bump(play: Bool) {
        lock.lock()
        if play { plays += 1 } else { searches += 1 }
        let next = "\(plays)/\(searches)"
        lock.unlock()
        DispatchQueue.main.async {
            self.label = next
        }
    }

    private init() {}
}
#endif

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
    ///
    /// P0 build 8: `music.play` runs first. `queueStarted` / break prep runs in a cancellable
    /// background task via `beginQueueInBackground` and must never delay the song.
    static func live(_ music: MusicKitService, station: StationRef, djSession: DJBreakSession,
                     briefing: @escaping @MainActor () -> ApprovedShowHandoff) -> MusicSearch {
        return MusicSearch(
            search: { query in
                let tracks = try await music.search(query)
                music.searchResults.store(tracks)
                return tracks.map(\.info)
            },
            play: { results, startIndex in
                // TEMPORARY P0 diagnostics -Atlas: offsets are measured from this tap; the
                // overlay freezes a reading 3 s later.
                P0TapDiagnostics.shared.markTap(transport: { music.snapshot.transport.rawValue })
                // Station jump check: does the on-screen station match the view that took the tap?
                let shown = music.snapshot.station.map { $0 == station ? "same" : "other" } ?? "none"
                P0TapDiagnostics.shared.record("tap.station", detail: "snapshotStation=\(shown)")
                // Resolve before touching the DJ session. Out-of-range / expired cache throw a
                // visible TEMPORARY error; queueStarted never runs with an empty queue.
                let tracks: [Track]
                do {
                    tracks = try music.searchResults.resolve(results: results, startIndex: startIndex)
                } catch {
                    P0TapDiagnostics.shared.recordPlayError("tapResolve.threw", error) // TEMPORARY P0 diagnostics -Atlas
                    throw error
                }
                // Consent / approved-handoff check runs here, before personal cues reach the session.
                let handoff = briefing()
                let djTracks = tracks.map { DJTrack(id: $0.id, title: $0.title, artist: $0.artistName) }
                let briefingForQueue = handoff.forQueue()
                let sources = handoff.connectionItems
                // Play first (P0 build 8). TapPlaySequence is the live order: play, then
                // schedule cancellable break prep. Consent already ran via `briefing()` /
                // `forQueue()` above.
                _ = try await TapPlaySequence.run(
                    play: { try await music.play(tracks, station: station) },
                    scheduleBreakPrep: {
                        djSession.beginQueueInBackground(
                            djTracks, briefing: briefingForQueue, sources: sources)
                    })
            })
    }

    #if DEBUG
    /// Fixture search and play: they count, and they never reach `MusicKitService`.
    /// Search returns the shared fixture songs so compact and Studio can assert results.
    static let counting = MusicSearch(
        search: { _ in
            PlaybackCallLog.shared.recordSearch()
            return PlaybackFixtures.songs
        },
        play: { _, _ in
            PlaybackCallLog.shared.recordPlay()
        }
    )
    #endif
}

/// One search session for Listen and Studio. Results live here so a fold, the compact
/// sheet, or a view rebuild cannot wipe them, and both layouts share the same path.
@MainActor
final class StudioSearchModel: ObservableObject {
    enum Phase: Equatable {
        case idle, searching, failed(String), empty
    }

    @Published var query: String
    @Published var results: [TrackInfo] = []
    @Published var phase: Phase = .idle

    init(query: String = SearchText.stored) {
        self.query = query
    }

    func updateQuery(_ newValue: String) {
        query = newValue
        SearchText.stored = newValue
    }

    func run(using search: MusicSearch) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        phase = .searching
        Task {
            do {
                let found = try await search.search(term)
                results = found
                phase = found.isEmpty ? .empty : .idle
            } catch {
                results = []
                phase = .failed(Self.searchFailureMessage(error))
            }
        }
    }

    /// TEMPORARY diagnostic (Atlas #104): type, code, localizedDescription only.
    static func searchFailureMessage(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        let code = (error as NSError).code
        let text = error.localizedDescription
        searchLog.error("Apple Music search failed: \(typeName, privacy: .public) code \(code, privacy: .public): \(text, privacy: .public)")
        return "Apple Music search failed: \(typeName) code \(code). \(text)"
    }

    private static let searchLog = Logger(subsystem: "com.aerodj.app", category: "search")
}
