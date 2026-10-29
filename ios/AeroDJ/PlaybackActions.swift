import Foundation
import MusicKit
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
    /// Build 9 P0 (-Atlas; Sentinel): Stop on a start past its 8 s deadline. A user pause that also
    /// cancels the attempt, so a late `.playing` cannot start audio the user turned down.
    var cancelStart: () -> Void = {}
    /// Song scrubbing (-Atlas): the committed seek. Nil-safe default: previews never seek.
    var seekAction: (TimeInterval, String?) async -> Bool = { _, _ in false }

    /// Song scrubbing (-Atlas; API agreed with Nova): call once when the scrubber is released,
    /// never while dragging (the drag position is view state). Returns false and changes
    /// nothing unless `PlaybackSnapshot.canSeek`: a DJ break, a load or an unknown duration
    /// blocks it, and the view snaps back to the live position. The target is clamped to
    /// [0, duration - 1 s]. Pass the `trackID` the scrubber was showing: if the song changed
    /// before release, the seek is a no-op and returns false (stale scrub).
    func seek(to seconds: TimeInterval, trackID: String? = nil) async -> Bool {
        await seekAction(seconds, trackID)
    }

    /// Bound to the one app-wide `MusicKitService`.
    static func live(_ music: MusicKitService) -> PlaybackActions {
        PlaybackActions(
            pause: { music.pause() },
            // resume raises a snapshot error before throwing; try? only drops the throw.
            resume: { _ = try? await music.resume() },
            skip: { _ = try? await music.skip() },
            dismissError: { music.dismissError() },
            authorize: { await music.authorize() },
            cancelStart: { music.cancelTimedOutStart() },
            seekAction: { music.seek(to: $0, trackID: $1) }
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
                // Resolve before touching the DJ session. Out-of-range / expired cache throw a
                // visible TEMPORARY error; queueStarted never runs with an empty queue.
                let tracks = try music.searchResults.resolve(results: results, startIndex: startIndex)
                // Consent / approved-handoff check runs here, before personal cues reach the session.
                let handoff = briefing()
                let djTracks = tracks.map { DJTrack(id: $0.id, title: $0.title, artist: $0.artistName) }
                let briefingForQueue = handoff.forQueue()
                let sources = handoff.connectionItems
                // Play first (P0 build 8). TapPlaySequence is the live order: play, then
                // schedule cancellable break prep. Consent already ran via `briefing()` /
                // `forQueue()` above.
                // #116: the new queue is reserved before play, so a song start MusicKit reports
                // during play is held for it instead of reading the old queue's breaks.
                _ = try await TapPlaySequence.run(
                    reserve: { djSession.reserveQueueSetup() },
                    play: { try await music.play(tracks, station: station) },
                    scheduleBreakPrep: { reservation in
                        djSession.beginQueueInBackground(
                            reservation, djTracks, briefing: briefingForQueue, sources: sources)
                    },
                    release: { djSession.releaseQueueSetup($0) })
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
                if let message = Self.searchFailureMessage(error) {
                    phase = .failed(message)
                } else {
                    phase = .idle
                }
            }
        }
    }

    /// The search banner (#104). Fixed, plain-language copy from `SearchFailureCopy` (#124):
    /// never localizedDescription, debugDescription, userInfo, the query, titles or IDs. The
    /// log keeps type, domain and code only (`PlaybackErrorCode`). Returns nil when a newer
    /// start replaced this one and there is nothing to show.
    static func searchFailureMessage(_ error: Error) -> String? {
        let code = PlaybackErrorCode(error)
        let kind = searchFailureKind(error)
        searchLog.error("Apple Music search failed: \(code.typeName, privacy: .public) \(code.domain, privacy: .public) code \(code.code, privacy: .public) kind \(String(describing: kind), privacy: .public)")
        return SearchFailureCopy.message(for: kind)
    }

    /// MusicKit's own error types first, then the platform-neutral mapping in AeroDJCore.
    static func searchFailureKind(_ error: Error) -> SearchFailureKind {
        switch error {
        case MusicKitError.notAuthorized:
            return .notAuthorized
        case MusicKitError.superseded:
            return .superseded
        case let token as MusicTokenRequestError:
            switch token {
            case .permissionDenied: return .notAuthorized
            case .userNotSignedIn: return .notSignedIn
            case .privacyAcknowledgementRequired: return .privacyAcknowledgementRequired
            case .userTokenRevoked, .userTokenRequestFailed: return .notAuthorized
            case .developerTokenRequestFailed: return .serviceUnavailable
            @unknown default: return .unknown
            }
        case let request as MusicDataRequest.Error:
            return SearchFailureCopy.kind(httpStatus: request.status)
        default:
            return SearchFailureCopy.kind(for: error)
        }
    }

    private static let searchLog = Logger(subsystem: "com.aerodj.app", category: "search")
}
