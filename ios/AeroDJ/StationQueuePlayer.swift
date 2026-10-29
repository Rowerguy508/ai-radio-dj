import AeroDJCore
import Foundation
import OSLog

/// Station queue (-Atlas): makes the station the listener created or saved what plays.
///
/// `StationQueueFeed` (AeroDJCore, tested on Linux) builds the committed station's queue ahead of
/// time with `CatalogStationSeedResolver` + `StationPoolBuilder.build(_:configuration:)` over
/// `MusicCatalogSeedSource`, and decides when to hand it out. This type only connects it:
/// - `MusicKitService.stationQueueAtBoundary`: at a natural boundary, after the break, a station
///   whose music settings changed since the playing queue began replaces the queue; at the
///   boundary before the queue's last song, `[last song] + station songs` refills it (Echo's
///   conditions: before the last song starts, today's stop path on any failure, and the DJ only
///   ever names queued songs because its list is the player's list).
/// - `MusicKitService.stationQueueForIdlePlay`: Play with nothing queued starts the station.
/// - `MusicKitService.onQueueReplaced`: every new queue belongs to the station committed then.
/// A hand-off starts like a song tap (`TapPlaySequence`: reserve, play, then break prep), so the
/// DJ session plans breaks for the new songs. Station queues carry no briefing handoff.
///
/// Fallbacks: no seeds, an empty pool, a failed fetch, no playable song, a queue not ready yet, or a
/// held start all keep the current queue (or Play's existing message). Never an empty queue.
/// Logs are enums and counts only (`StationQueueEvent.diagnostics`): no seed, song or artist.
@MainActor
final class StationQueuePlayer {
    let feed: StationQueueFeed<Track>
    /// Created-station row taps (core, tested on Linux): idle with nothing queued starts the station.
    private let createdStart: CreatedStationStarter<Track>
    private let music: MusicKitService
    private let station: StationConfigurationModel
    private let djSession: DJBreakSession
    /// Set only between this type's `music.play` call and its synchronous queue assignment, so the
    /// hand-off's own queue keeps the key the feed gave it (a change saved meanwhile still applies).
    private var ownQueueStarting = false

    init(music: MusicKitService, station: StationConfigurationModel, djSession: DJBreakSession,
         source: MusicCatalogSeedSource = MusicCatalogSeedSource()) {
        self.music = music
        self.station = station
        self.djSession = djSession
        let log = Logger(subsystem: "com.aerodj.app", category: "stationQueue")
        feed = StationQueueFeed<Track>(
            resolver: CatalogStationSeedResolver(catalog: source),
            materialize: { picks in await source.tracks(for: picks) },
            recentlyPlayed: { [weak music] in
                guard let music else { return [] }
                let queue = music.queue
                let current = queue.firstIndex { $0.id == music.currentTrack?.id } ?? -1
                return Set(queue.prefix(current + 1).map(\.id))
            },
            log: { event in log.notice("\(event.diagnostics, privacy: .public)") })
        createdStart = CreatedStationStarter(feed: feed)
    }

    /// Installs the three hooks and starts following the station. Call once, at launch.
    func start() {
        music.onQueueReplaced = { [weak self] in
            guard let self else { return }
            if self.ownQueueStarting { self.ownQueueStarting = false; return }
            self.feed.queueStarted(for: self.station.committedDisplayed, songCount: self.music.queue.count)
        }
        music.stationQueueAtBoundary = { [weak self] finishedIndex in
            guard let self,
                  let tracks = self.feed.queueForNextSong(after: finishedIndex, in: self.music.queue,
                                                          active: self.station.active,
                                                          playbackMayStart: self.music.mayAutoResume,
                                                          sameSong: { $0.id == $1.id }) else { return nil }
            return { await self.play(tracks) }
        }
        music.stationQueueForIdlePlay = { [weak self] in
            guard let self, let tracks = self.feed.takeForIdleStart(active: self.station.active) else { return nil }
            return { await self.play(tracks) }
        }
        feed.follow(station)
    }

    /// A created-station row was opened (Orion, #213). User tap: authorize, apply the recipe, and when
    /// the player is idle with nothing queued start the station on the idle-Play path, waiting a
    /// bounded time for its queue; while something plays it switches at the song boundary.
    /// Restore: nothing. Logs the outcome as an enum only.
    func openCreatedStation(_ trigger: StationOpenTrigger, recipeID: UUID, studio: StudioPresentationModel) async {
        let outcome = await createdStart.open(
            trigger,
            recipeID: recipeID,
            liveRecipeID: { studio.lastAppliedRecipeID },
            authorize: { await music.authorize() },
            apply: { if case .success = await studio.applyRecipe(recipeID) { true } else { false } },
            active: { station.active },
            nothingQueued: { music.queue.isEmpty && !music.isPlaying },
            start: { tracks in await play(tracks) })
        Logger(subsystem: "com.aerodj.app", category: "stationQueue")
            .notice("createdStationOpen \(String(describing: outcome), privacy: .public)")
    }

    /// A built-in station row was tapped (Fry #213 nit 2): a created-station tap still waiting for
    /// its queue does not start.
    func cancelCreatedStationStart() {
        createdStart.cancelPending()
    }

    /// Same order as a song tap (#116): the DJ session reserves the new queue before play, so a
    /// song start reported during play belongs to it. `play` raises its own snapshot error.
    private func play(_ tracks: [Track]) async {
        let djTracks = tracks.map { DJTrack(id: $0.id, title: $0.title, artist: $0.artistName) }
        let stationRef = music.snapshot.station
        _ = try? await TapPlaySequence.run(
            reserve: { djSession.reserveQueueSetup() },
            play: {
                ownQueueStarting = true
                defer { ownQueueStarting = false }
                try await music.play(tracks, station: stationRef)
            },
            scheduleBreakPrep: { reservation in
                djSession.beginQueueInBackground(reservation, djTracks)
            },
            release: { djSession.releaseQueueSetup($0) })
    }
}
