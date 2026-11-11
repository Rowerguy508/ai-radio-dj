import AeroDJCore
import Foundation
import OSLog
import UIKit

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
/// DJ session plans breaks for the new songs. A station START (idle Play, a station row tap, or a
/// different station taking over at a song boundary) may carry one
/// personal update (#332, `StationStartBriefing`); a same-station refill carries none.
///
/// Fallbacks: no seeds, an empty pool, a failed fetch, no playable song, a queue not ready yet, or a
/// held start all keep the current queue (or Play's existing message). Never an empty queue.
/// Logs are enums and counts only (`StationQueueEvent.diagnostics`): no seed, song or artist.
@MainActor
final class StationQueuePlayer {
    let feed: StationQueueFeed<Track>
    /// Every station row tap (core, tested on Linux, #454): starts the station on its first song.
    private let createdStart: CreatedStationStarter<Track>
    private let music: MusicKitService
    private let station: StationConfigurationModel
    private let djSession: DJBreakSession
    /// DJ talk-over: a rating that drops a break also drops a talk-over held or running for it (PR B).
    private let talkover: TalkoverCoordinator?
    /// Set only between this type's `music.play` call and its synchronous queue assignment, so the
    /// hand-off's own queue keeps the key the feed gave it (a change saved meanwhile still applies).
    private var ownQueueStarting = false
    /// The song tap's briefing provider (`LiveQueueBriefing.provider`), read when a station starts.
    /// Nil until `start(briefing:)`: no personal update (fails closed).
    private var briefing: (@MainActor () -> ApprovedShowHandoff)?
    /// #445: the foreground observer token (kept for the app's lifetime, like the type itself).
    private var foregroundObserver: NSObjectProtocol?
    /// #454: bumps every time the player's queue is replaced (`onQueueReplaced`), so a station tap
    /// can tell that the listener started something else while it waited.
    private var queueEpoch = 0
    /// #454: true while the playing queue was started by this type (a station start, hand-off or
    /// refill), so its station is `feed.playingKey`; false after a search or song tap.
    private var stationOwnsQueue = false
    /// #454 seam for Fry (#442, `DJBreakSession` owner): songs appended behind a station's first
    /// song. Nil until wired: the DJ then plans breaks only for the songs its queue started with
    /// (it never names a song it was not given), and the next refill re-plans as today.
    var onStationSongsAppended: (@MainActor ([DJTrack]) -> Void)?
    /// #454/#442 seam: airs a ready station intro at the first song boundary through the break path
    /// (never over a song). Nil until the DJ session can air a prepared intro (Fry): the starter then
    /// begins no intro at all, so no voice is rendered (or paid for) that nobody hears. When set, the
    /// boundary must also call `createdStart.songBoundary(queueEpoch:)` (not wired yet).
    var airStationIntro: (@MainActor (PreparedDJBreak) -> Void)? {
        get { createdStart.airIntro }
        set { createdStart.airIntro = newValue }
    }

    /// `ratings`: the committed station's song ratings (`StationRatingsModel.bias`, PR B). Read on
    /// every build and hand-off; never logged, never passed to the DJ or a voice.
    init(music: MusicKitService, station: StationConfigurationModel, djSession: DJBreakSession,
         talkover: TalkoverCoordinator? = nil,
         ratings: @escaping @MainActor () -> StationRatingBias = { .none },
         source: MusicCatalogSeedSource = MusicCatalogSeedSource()) {
        self.music = music
        self.station = station
        self.djSession = djSession
        self.talkover = talkover
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
            ratings: ratings,
            log: { event in log.notice("\(event.diagnostics, privacy: .public)") })
        createdStart = CreatedStationStarter(feed: feed)
        // #442: the station intro renders only in the DJ session (its preparer, voice quota and
        // reserve gate). Begun only once `airStationIntro` is set.
        createdStart.intro = djSession
    }

    /// Installs the three hooks and starts following the station. Call once, at launch.
    /// `briefing` is the same provider a song tap uses; only station starts read it (#332).
    func start(briefing: (@MainActor () -> ApprovedShowHandoff)? = nil) {
        self.briefing = briefing
        music.onQueueReplaced = { [weak self] in
            guard let self else { return }
            self.queueEpoch += 1
            if self.ownQueueStarting { self.ownQueueStarting = false; self.stationOwnsQueue = true; return }
            self.stationOwnsQueue = false
            self.feed.queueStarted(for: self.station.committedDisplayed, songCount: self.music.queue.count)
        }
        music.stationQueueAtBoundary = { [weak self] finishedIndex in
            guard let self,
                  let tracks = self.feed.queueForNextSong(after: finishedIndex, in: self.music.queue,
                                                          active: self.station.active,
                                                          playbackMayStart: self.music.mayAutoResume,
                                                          sameSong: { $0.id == $1.id }) else { return nil }
            // #332: a station switch at the boundary is a start; a same-station refill is not.
            let kind = StationHandOffKind(boundaryHandOff: self.feed.pendingHandOffTrigger)
            return { await self.play(tracks, kind) }
        }
        music.stationQueueForIdlePlay = { [weak self] in
            guard let self, let tracks = self.feed.takeForIdleStart(active: self.station.active) else { return nil }
            return { await self.play(tracks, .idlePlayStart) }
        }
        feed.follow(station)
        // #445 (-Atlas): the time of day is re-read from the clock when the listener presses Play
        // and when the app comes back to the foreground. A new day part re-plans the DJ's breaks
        // (same day part: nothing changes). Never captured at launch or station start.
        music.onUserResumed = { [weak self] in self?.djSession.timeOfDayMayHaveChanged() }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.djSession.timeOfDayMayHaveChanged() }
        }
    }

    /// A created-station row was opened (Orion, #213; #454). Same start path as every station.
    @discardableResult
    func openCreatedStation(_ trigger: StationOpenTrigger, recipeID: UUID,
                            studio: StudioPresentationModel) async -> CreatedStationOpenOutcome {
        await openStation(trigger, .created(recipeID), studio: studio)
    }

    /// A built-in row was opened (#454). Same start path, with the station's own configuration
    /// from `BuiltInStations` (#442). An id that is not a built-in ends `.notAvailableYet`.
    @discardableResult
    func openBuiltInStation(_ trigger: StationOpenTrigger, stationID: UUID,
                            studio: StudioPresentationModel) async -> CreatedStationOpenOutcome {
        await openStation(trigger, .builtIn(stationID), studio: studio)
    }

    /// Which station a row tap opens. Library stations are created stations whose seeds are
    /// `.library` (`MusicCatalogSeedSource` reads them on the device); they take the same path.
    enum StationStartSource {
        case created(UUID)
        case builtIn(UUID)
    }

    /// #454 (-Atlas): every station row tap. User tap: authorize, apply the station, and start it at
    /// once: the first playable song plays as soon as it is known, the rest of the queue is
    /// appended in the background. While something else plays, it switches now; the station
    /// already playing is a no-op, and the paused active station resumes (Fry N4). Restore: nothing. Logs the outcome as an enum only.
    @discardableResult
    func openStation(_ trigger: StationOpenTrigger, _ source: StationStartSource,
                     studio: StudioPresentationModel) async -> CreatedStationOpenOutcome {
        let station = self.station
        let music = self.music
        let recipeID: UUID
        let available: Bool
        let introFacts: StationIntroFacts?
        let apply: @MainActor () async -> Bool
        let liveRecipeID: @MainActor () -> UUID?
        switch source {
        case .created(let id):
            recipeID = id
            available = true
            introFacts = studio.recipes.recipe(id).map(StationStartFacts.created)
            apply = { if case .success = await studio.applyRecipe(id) { true } else { false } }
            liveRecipeID = { studio.lastAppliedRecipeID }
        case .builtIn(let id):
            // #442: built-ins carry their own seeds (`BuiltInStations`); same path as created.
            let recipe = trigger == .userTap ? StationStartFacts.builtInRecipe(for: id) : nil
            recipeID = id
            available = recipe != nil
            introFacts = StationStartFacts.builtIn(id)
            // Fry N3 (#456): recorded as the last applied recipe, so a re-tap on the active
            // built-in is not applied again and unsaved Tune edits stay (as for created stations).
            apply = {
                guard let recipe else { return false }
                await studio.applyBuiltInRecipe(recipe)
                return true
            }
            liveRecipeID = { studio.lastAppliedRecipeID }
        }
        let outcome = await createdStart.open(
            trigger,
            recipeID: recipeID,
            available: available,
            introFacts: introFacts,
            liveRecipeID: liveRecipeID,
            authorize: { await music.authorize() },
            apply: apply,
            active: { station.active },
            nothingQueued: { music.queue.isEmpty && !music.isPlaying },
            playingStation: { [weak self] in
                guard let self, self.stationOwnsQueue else { return nil }
                return self.feed.playingKey
            },
            switchNow: { await station.applyPendingForStationSwitch() },
            queueEpoch: { [weak self] in self?.queueEpoch ?? 0 },
            // Fry N2: the intro waits for a confirmed `.playing`; Fry N4: a paused active station resumes.
            transport: { music.snapshot.transport },
            resume: { _ = try? await music.resume() },
            start: { [weak self] tracks in _ = await self?.play(tracks, .createdStationStart) },
            append: { [weak self] first, tracks in self?.appendStationSongs(tracks, after: first) ?? false })
        Logger(subsystem: "com.aerodj.app", category: "stationQueue")
            .notice("stationOpen \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// #454: the background fill. Appends behind the station's first song only while that song's
    /// queue is still the player's; never replaces the queue or touches the playing song.
    private func appendStationSongs(_ tracks: [Track], after first: Track) -> Bool {
        guard stationOwnsQueue, music.appendStationSongs(tracks, after: first) else { return false }
        onStationSongsAppended?(tracks.map { DJTrack(id: $0.id, title: $0.title, artist: $0.artistName, origin: $0.origin) })
        return true
    }

    /// A song was rated, a rating undone, or ratings cleared (PR B, #388, -Nova). Never logged.
    /// 1. The staged queue is rebuilt in the background with the new ratings (`ratingsChanged`).
    /// 2. Songs still queued after the playing one that the station now excludes (never, held tired)
    ///    are handed to the DJ session as song IDs (`songsExcluded`, replacing the last set so an
    ///    Undo restores): every break it hands out drops exactly the cues attributed to them
    ///    (`SpokenAttribution.trackMetadata`), and keeps briefing items, time checks and every other
    ///    line (Echo's #387 N2; before, the whole break on both sides of the song was cut).
    /// 3. The talk-over coordinator acts on what is already taken (`TalkoverCoordinator.ratingChanged`):
    ///    a talk-over line on air that names the song fades and its break is dropped; a held break is
    ///    narrowed; a paused gap break that names it is withdrawn.
    ///    The songs themselves are not skipped ahead of time (that waits on #373): a queued never
    ///    still plays once, with no line naming it. The playing song is the caller's (a never on it
    ///    skips through `MusicKitService.skip()`, which stops its break).
    func ratingChanged() async {
        feed.ratingsChanged(station.committedDisplayed)
        let queue = music.queue
        let playing = queue.firstIndex { $0.id == music.currentTrack?.id } ?? -1
        let upcoming = feed.excludedUpcoming(in: queue, after: playing, active: station.active)
        let excluded = Set(upcoming.map { queue[$0].id })
        djSession.songsExcluded(excluded)
        talkover?.ratingChanged(excluded: excluded,
                                boundaries: StationRatingBreakDrop.boundaries(forUpcoming: upcoming, playing: playing))
    }

    /// A purge-all emptied the ratings (Sentinel's #396 N1, via `StationRatingsModel.resetOnPurge`,
    /// which also clears the DJ session's excluded songs): the staged queue is rebuilt in the
    /// background without them. Songs already queued keep playing. Never logged.
    func ratingsPurged() {
        feed.ratingsChanged(station.committedDisplayed)
    }

    /// The catalog artist ID the last build saw for `songID` (love's discovery steering only).
    func artistID(forSong songID: String) -> String? { feed.artistID(forSong: songID) }

    /// Another tap path took over (Fry #213 nit 2): a station tap still waiting does not start, its
    /// background fill stops.
    func cancelCreatedStationStart() {
        createdStart.cancelPending()
    }

    /// Same order as a song tap (#116): the DJ session reserves the new queue before play, so a
    /// song start reported during play belongs to it. `play` raises its own snapshot error.
    /// #204 (-Atlas): the start's outcome is no longer discarded. The feed puts a failed hand-off
    /// back (the playing queue keeps its station, the songs are staged again for a retry), and the
    /// caller gets the typed result: a failed boundary hand-off falls back to the old queue's next
    /// song. A held start (`.onHold`: the queue is loaded and waits for the hold) counts as started.
    private func play(_ tracks: [Track], _ kind: StationHandOffKind) async -> StationHandOffResult {
        let result = await start(tracks, kind)
        feed.handOffFinished(result)
        return result
    }

    private func start(_ tracks: [Track], _ kind: StationHandOffKind) async -> StationHandOffResult {
        let djTracks = tracks.map { DJTrack(id: $0.id, title: $0.title, artist: $0.artistName, origin: $0.origin) }
        // #332: read at start time, like a song tap; consent runs inside (`forQueue()`).
        let offer = StationStartBriefing.offer(for: kind, briefing: briefing)
        let stationRef = music.snapshot.station
        do {
            try await TapPlaySequence.run(
            reserve: { djSession.reserveQueueSetup() },
            play: {
                ownQueueStarting = true
                defer { ownQueueStarting = false }
                try await music.play(tracks, station: stationRef)
            },
            scheduleBreakPrep: { reservation in
                djSession.beginQueueInBackground(reservation, djTracks,
                                                 briefing: offer.briefing, sources: offer.sources)
            },
            release: { djSession.releaseQueueSetup($0) })
            return .started
        } catch MusicKitError.superseded {
            return .superseded
        } catch let MusicKitError.playbackFailed(message) where message == PlaybackFailureCopy.message(for: .onHold) {
            return .started
        } catch {
            return .failed
        }
    }
}
