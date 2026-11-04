import AeroDJCore
import Foundation

/// The composition root: the one place that decides which services the app runs with.
///
/// `live` uses the real EventKit calendar, on-device voice and a live station
/// configuration that grants no integration. The test station (Debug builds only,
/// enabled by the `-AeroDJTestStation YES` launch argument) swaps in synthetic
/// fixtures, an in-memory $0 on-device voice renderer and fixture station
/// configuration. Nothing else differs between the two.
@MainActor
struct AppDependencies {
    let mode: AppRuntimeMode
    let contextSources: [any ContextSource]
    let voice: VoiceRenderer
    let cadence: DJCadence
    let station: StationConfigurationModel
    /// The one app-scoped playback session. Layouts receive it; none creates another.
    let playback: MusicKitService
    /// The one interlude player. Created with the DJ session, not inside PlayerView,
    /// so a clip can be stopped after that screen is gone.
    let interlude: InterludePlaybackAdapter
    let dj: DJPresentationStore
    /// The one Studio model (#56). Created here, never in a view.
    let studio: StudioPresentationModel
    /// The one DJ session: plans breaks, prepares narration while a song plays, hands prepared breaks out at natural boundaries.
    let djSession: DJBreakSession
    /// Live only: the store for notes the listener picked (`.fileImporter`). `nil` in the
    /// test station, so the file picker is not offered there.
    let pickedNotes: LiveConnectionSources?
    /// Station queue (-Atlas; flagged for Claude): live only. Feeds the built station into the
    /// player at natural boundaries and on an idle Play. `nil` in the test station.
    let stationQueue: StationQueuePlayer?
    /// DJ talk-over (-Fry, flagged; docs/dj-talkover.md). App-scoped like the interlude, so a
    /// fold or a view change never touches a voice in flight.
    let talkover: TalkoverCoordinator
    /// Station ratings (-Nova, PR B): the one book, loaded at launch.
    let ratings: StationRatingsModel
    /// The rating button's controller, injected at the app root as `\.songRating`.
    let songRating: SongRatingController
    /// #401 (-Fry): local weather and news, live only (consent-gated; `\.localFacts`). `nil` in
    /// the test station, so its breaks and screens are unchanged.
    let localFacts: LocalFactsHost?

    /// Starts the Studio and the DJ session once per launch.
    func start() async {
        await studio.start()
        // Before the station queue's first build, so it is screened from the start.
        await ratings.load()
        // #401: the take-time fact gate and the purge listeners before any break plays.
        await localFacts?.start(isPlaying: { MusicKitService.shared.isPlaying })
        await djSession.start()
        // #332: station starts read the same briefing provider as a song tap.
        stationQueue?.start(briefing: djSession.briefingProvider(studio: studio))
    }

    static func make(defaults: UserDefaults = .standard) -> AppDependencies {
        #if DEBUG
        // Release builds do not compile this branch, so the flag is never read there.
        if AppRuntimeMode.resolve(testStationFlag: TestStation.isEnabled(defaults: defaults),
                                  allowsTestStation: true) == .testStation {
            return testStation()
        }
        #endif
        return live()
    }

    private static func live() -> AppDependencies {
        // Live connection sources (Fry, #61): EventKit for calendars the listener chooses, a
        // security-scoped reader for .md files they pick, the App Group inbox when it exists.
        // Consent is derived from those sources, never assumed.
        let composition = ConnectionsComposition.make(
            mode: .live,
            live: .init(calendar: { EventKitCalendarReader() },
                        files: { SecurityScopedNoteReader() },
                        store: { FileConnectionChoicesStore(fileURL: supportURL("Connections/choices.json")) },
                        shareInbox: { SharedInboxReview.appGroupInbox().map { [SharedInboxConnectionProvider(review: $0)] } ?? [] })
        )
        let station = StationConfigurationModel(store: FileStationConfigurationStore(fileURL: stationFileURL()),
                                                consent: composition.consent)
        let voice = VoiceRenderer.liveDefault()
        if voice.routes.contains(where: { $0.providerID == PhononModelPin.providerID }) {
            Task { await PhononModelCoordinator.shared.start() }
        }
        let dj = DJPresentationStore()
        // One preparer per launch: revoking a source purges prepared breaks as well as cached audio.
        // Bundled presenter clips (Fry): build 27 ships an empty manifest, so nothing resolves and
        // every cue takes today's path. A missing or malformed resource is also empty.
        let bundledClips = BundledClipResolver(
            manifest: .load(contentsOf: Bundle.main.url(forResource: BundledClipManifest.resourceName,
                                                        withExtension: BundledClipManifest.resourceExtension)),
            directory: Bundle.main.resourceURL ?? Bundle.main.bundleURL,
            access: .buildDefault)
        // The 4 s closing cap applies only while talk-over is on: the same flag the coordinator
        // reads (the Settings toggle, else ON on a live station). P0 build 26, -Fry.
        let preparer = DJBreakPreparer(renderer: voice, userID: "listener", stationID: "default", cadence: DJCadence(),
                                       talkOverEnabled: { DJTalkoverFlag.isEnabled() },
                                       cloudVoiceConsent: TesterCloudVoiceConsentHooks.preparerConsent,
                                       bundledClips: bundledClips)
        // Tester build only (Echo's N2 on #395): a decline drops prepared cloud breaks and cached cloud clips.
        TesterCloudVoiceConsentHooks.attach(preparer: preparer, renderer: voice)
        // #401 (-Fry): local weather (WeatherKit) and, in the tester build only, local news
        // (GDELT), each fact one on-device line. Nothing is gathered and no location is read
        // before the listener opts in (Tune → DJ → Local weather & news).
        let localFacts = makeLocalFacts(preparer: preparer)
        // #332: one once-a-day ledger for song taps and station starts, kept across relaunches.
        let djSession = DJBreakSession(preparer: preparer, station: station, dj: dj,
                                       personalUpdates: PersonalUpdateLedger(store: UserDefaultsPersonalUpdatePlayStore()),
                                       extraLineSource: localFacts.wiring.source)
        let interlude = makeInterlude(session: djSession, playback: MusicKitService.shared, dj: dj)
        interlude.acknowledgementClip = interruptionAcknowledgement(voice: voice, userID: "listener", stationID: "default")
        let talkover = TalkoverCoordinator(music: MusicKitService.shared, interlude: interlude, djSession: djSession)
        wireSongSeek(session: djSession, playback: MusicKitService.shared, talkover: talkover)
        let purger = NarrationPurger(cache: voice.cache, preparer: preparer, session: djSession)
        // The same purger handles sources that expire mid-show (checked at each song boundary).
        djSession.purger = purger
        // #199: artist and song facts from the Apple Music catalog (MusicKit) only.
        djSession.catalogFactsSource = MusicKitCatalogFactsSource()
        precondition(djSession.isWiredForPurge, "purger and stop hook are set before playback")
        let connections = ConnectionsModel(
            station: station,
            sourceReader: composition.sourceReader,
            providers: composition.providers,
            purger: purger)
        let recipes = StationRecipeLibrary(store: FileStationRecipeStore(fileURL: supportURL("StationRecipes/recipes.json")))
        let catalogSource = MusicCatalogSeedSource()   // one actor: seed search and genres (-Atlas)
        let studio = StudioPresentationModel(station: station, recipes: recipes, connections: connections, dj: dj,
                                             // Add-station search (Atlas): catalog + on-device library playlists.
                                             seedSearch: catalogSource,
                                             // Genres from Apple Music: the same actor and cache as seedSearch (-Atlas).
                                             // Feeds Tune > Genres chips and the add-station genre step.
                                             genreProvider: catalogSource,
                                             seedSearchFailureKind: StudioSearchModel.searchFailureKind)
        // Station ratings (-Nova, PR B): on this device only, not backed up; "purge all" deletes them.
        let ratings = StationRatingsModel(store: FileStationRatingStore(fileURL: FileStationRatingStore.defaultURL(
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])))
        ratings.listen(to: .shared)
        let stationQueue = StationQueuePlayer(
            music: MusicKitService.shared, station: station, djSession: djSession, talkover: talkover,
            ratings: { [weak studio, weak station] in
                guard let station else { return .none }
                return ratings.bias(recipeID: SongRatingController.liveRecipeID(studio: studio, station: station),
                                    configuration: station.committedDisplayed)
            })
        // Sentinel's #396 N1: a purge-all (consent withdrawal) also drops the DJ session's excluded
        // songs and rebuilds the staged queue without the old ratings. Set before `load()` (start).
        ratings.resetOnPurge(session: djSession, rebuildQueue: { [weak stationQueue] in stationQueue?.ratingsPurged() })
        #if AERODJ_P0_DIAG
        // Echo's #396 room N1: a break narrowed for an excluded song leaves a counts-only row.
        djSession.onExcludedCuesDropped = { k, counts in
            P0EventTraceHost.shared.talkover { trace, t in _ = trace.breakNarrowed(counts, afterTrack: k, at: t) }
        }
        // Echo's N2 on #398: a break dropped for cloud-voice consent (tester build only; the
        // preparer reports nothing without a consent check) leaves a counts-only row.
        Task {
            await preparer.observeCloudVoiceDrops { k, counts in
                Task { @MainActor in
                    P0EventTraceHost.shared.talkover { trace, t in _ = trace.cloudVoiceDropped(counts, afterTrack: k, at: t) }
                }
            }
        }
        #endif
        return AppDependencies(
            mode: .live,
            // Calendar: only calendars the listener chose. Notes: only approved picked notes.
            contextSources: composition.contextSources,
            voice: voice,
            cadence: DJCadence(),
            station: station,
            playback: MusicKitService.shared,
            interlude: interlude,
            dj: dj,
            studio: studio,
            djSession: djSession,
            pickedNotes: composition.notes,
            stationQueue: stationQueue,
            talkover: talkover,
            ratings: ratings,
            songRating: .live(ratings: ratings, station: station, studio: studio, music: MusicKitService.shared,
                              queue: stationQueue),
            localFacts: localFacts)
    }

    /// #401: Echo's #200 plumbing (`FactRefresh`, `LocalAreaStore`) behind `LocalFactsWiring`.
    private static func makeLocalFacts(preparer: DJBreakPreparer) -> LocalFactsHost {
        let location = LazyCoarseDeviceLocation()
        // Each refresh runs `FactRefresh` over the switched-on providers (Sentinel's N3).
        let wiring = LocalFactsWiring(
            store: LocalAreaStore(), toggles: LocalFactsToggles(),
            providers: [WeatherKitWeatherProvider(), TesterLocalNews.makeProvider()],
            summarizer: HeadlineSummarizer(paraphraser: HeadlineParaphrasers.best()),
            device: LazyDeviceCoarseLocationSource(location: location), manual: GeocodedManualPlace(),
            unit: { Locale.current.measurementSystem == .us ? .fahrenheit : .celsius })
        return LocalFactsHost(wiring: wiring, location: location, preparer: preparer)
    }

    #if DEBUG
    /// Synthetic only: fixture context, fixture station, $0 in-memory voice, no shared
    /// inbox and no calendar reader. Playback is Apple Music, the same session as live.
    private static func testStation() -> AppDependencies {
        // `make(.testStation)` never calls a live factory (LiveConnectionsTests).
        let composition = ConnectionsComposition.make(mode: .testStation, live: .unavailable,
                                                      testStation: .testStationFixtures(TestStationFixtures()))
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(
                snapshot: StationConfigurationSnapshot(state: StationConfigurationState(active: TestStation.configuration))),
            consent: composition.consent)
        let voice = TestStation.makeRenderer(routes: VoiceRoute.onDeviceRoutes(),
                                             cache: InMemoryAudioCache(maxAge: TestStation.cacheRetention))
        let dj = DJPresentationStore()
        // Fixture mode: the same flag and unset default as the coordinator below (OFF unless the
        // Settings toggle was explicitly set ON). #225 removed `buildDefault:`; this call
        // from fe63f91 was missed in that merge and broke the app build on integration. -Fry
        let preparer = DJBreakPreparer(renderer: voice, userID: TestStation.userID, stationID: TestStation.stationID,
                                       cadence: TestStation.cadence,
                                       talkOverEnabled: {
                                           DJTalkoverFlag.isEnabled(unsetDefault: DJTalkoverFlag.unsetDefault(isTestStation: true))
                                       })
        let djSession = DJBreakSession(preparer: preparer, station: station, dj: dj, base: TestStation.cadence)
        let interlude = makeInterlude(session: djSession, playback: MusicKitService.shared, dj: dj)
        interlude.acknowledgementClip = interruptionAcknowledgement(voice: voice, userID: TestStation.userID,
                                                                    stationID: TestStation.stationID)
        // Fixture mode: talk-over is OFF unless the Settings toggle was explicitly set ON. The
        // saved value is honoured in every build (DJTalkoverFlag).
        let talkover = TalkoverCoordinator(music: MusicKitService.shared, interlude: interlude, djSession: djSession,
                                           unsetDefault: DJTalkoverFlag.unsetDefault(isTestStation: true))
        wireSongSeek(session: djSession, playback: MusicKitService.shared, talkover: talkover)
        let purger = NarrationPurger(cache: voice.cache, preparer: preparer, session: djSession)
        // The same purger handles sources that expire mid-show (checked at each song boundary).
        djSession.purger = purger
        precondition(djSession.isWiredForPurge, "purger and stop hook are set before playback")
        let connections = ConnectionsModel(
            station: station,
            sourceReader: composition.sourceReader,
            providers: composition.providers,
            purger: purger)
        let recipes = StationRecipeLibrary(store: InMemoryStationRecipeStore())
        // Test Station: fixed genre fixture (no network, stable screenshots).
        let studio = StudioPresentationModel(station: station, recipes: recipes, connections: connections, dj: dj,
                                             genreProvider: StaticGenreProvider.fixture)
        // In memory: a test-station session never touches the live ratings file (-Nova, PR B).
        // Its own defaults suite too (Fry's #387 Debug nit, #388): a delete here can neither set
        // nor clear the live AeroDJRatingsPurgePending flag. Each launch starts unlocked.
        // Sentinel's #396 N3: never .standard (the live flag). Debug only, so a hard stop is safe.
        guard let ratingsDefaults = UserDefaults(suiteName: "AeroDJRatingsTestStation") else {
            fatalError("Test Station ratings suite unavailable")
        }
        ratingsDefaults.removeObject(forKey: StationRatingsModel.purgePendingKey)
        let ratings = StationRatingsModel(store: InMemoryStationRatingStore(), defaults: ratingsDefaults)
        return AppDependencies(
            mode: .testStation,
            contextSources: composition.contextSources,
            voice: voice,
            cadence: TestStation.cadence,
            station: station,
            playback: MusicKitService.shared,
            interlude: interlude,
            dj: dj,
            studio: studio,
            djSession: djSession,
            pickedNotes: nil,
            stationQueue: nil,
            talkover: talkover,
            ratings: ratings,
            songRating: .live(ratings: ratings, station: station, studio: studio, music: MusicKitService.shared,
                              queue: nil),
            localFacts: nil)   // #401: no weather or news in the test station
    }
    #endif

    /// The one production assignment of `djSession.onBreakMustStop`.
    ///
    /// Armed here, while the session and the interlude player are created, so the
    /// hook is already non-nil when a clip can play. PlayerView must not assign it again.
    /// Fry #73 owns the stored property and the `purge` call.
    private static func makeInterlude(session: DJBreakSession, playback: MusicKitService,
                                      dj: DJPresentationStore) -> InterludePlaybackAdapter {
        let interlude = InterludePlaybackAdapter(music: playback)
        // The on-air orb's voice level (-Fry). The store gates it to `.speaking`.
        interlude.speechLevel = dj
        let speechStop = SpeechStopGate()
        speechStop.arm { [interlude] reason, afterTrack in
            interlude.stopCurrentInterlude(reason: reason, afterTrack: afterTrack)
        }
        guard speechStop.canPlay, let hook = speechStop.onBreakMustStop else {
            preconditionFailure("speech stop hook is installed before a clip can play")
        }
        session.onBreakMustStop = hook
        return interlude
    }

    /// The "sorry, little interruption" line after a system interruption (-Fry). The existing
    /// voice path and its fallback, with NO attribution: `VoiceRenderer` then uses on-device,
    /// free routes only (`mayLeaveDevice` is false), so no paid or cloud voice is asked for it.
    /// Nil when nothing renders; the break then resumes without it.
    private static func interruptionAcknowledgement(voice: VoiceRenderer, userID: String,
                                                    stationID: String) -> @MainActor () async -> Data? {
        // On-device only, pinned in Core (Sentinel's #404 note): see `renderClip(with:)`.
        { await BreakInterruptionAcknowledgement.renderClip(with: voice, userID: userID, stationID: stationID) }
    }

    /// Song scrubbing (-Atlas): the one production assignment of `onSongSeeked`. A committed
    /// seek tells the DJ session the playing song's new time left, so its break is kept,
    /// re-armed or started (`DJBreakSession.songSeeked`). The boundary still comes only from
    /// the player.
    private static func wireSongSeek(session: DJBreakSession, playback: MusicKitService, talkover: TalkoverCoordinator) {
        playback.onSongSeeked = { [session, talkover] index, remaining in
            talkover.songSeeked(index: index)  // DJ talk-over (-Fry): a seek cancels or re-plans it
            Task { await session.songSeeked(index: index, remaining: .seconds(remaining)) }
        }
    }

    private static func supportURL(_ path: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(path)
    }

    private static func stationFileURL() -> URL {
        supportURL("StationConfiguration/station.json")
    }
}
