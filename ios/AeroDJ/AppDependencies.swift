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

    /// Starts the Studio and the DJ session once per launch.
    func start() async {
        await studio.start()
        await djSession.start()
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
        let preparer = DJBreakPreparer(renderer: voice, userID: "listener", stationID: "default", cadence: DJCadence())
        let djSession = DJBreakSession(preparer: preparer, station: station, dj: dj)
        let interlude = makeInterlude(session: djSession, playback: MusicKitService.shared, dj: dj)
        wireSongSeek(session: djSession, playback: MusicKitService.shared)
        let purger = NarrationPurger(cache: voice.cache, preparer: preparer, session: djSession)
        // The same purger handles sources that expire mid-show (checked at each song boundary).
        djSession.purger = purger
        precondition(djSession.isWiredForPurge, "purger and stop hook are set before playback")
        let connections = ConnectionsModel(
            station: station,
            sourceReader: composition.sourceReader,
            providers: composition.providers,
            purger: purger)
        let recipes = StationRecipeLibrary(store: FileStationRecipeStore(fileURL: supportURL("StationRecipes/recipes.json")))
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
            studio: StudioPresentationModel(station: station, recipes: recipes, connections: connections, dj: dj),
            djSession: djSession,
            pickedNotes: composition.notes)
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
        let preparer = DJBreakPreparer(renderer: voice, userID: TestStation.userID, stationID: TestStation.stationID,
                                       cadence: TestStation.cadence)
        let djSession = DJBreakSession(preparer: preparer, station: station, dj: dj, base: TestStation.cadence)
        let interlude = makeInterlude(session: djSession, playback: MusicKitService.shared, dj: dj)
        wireSongSeek(session: djSession, playback: MusicKitService.shared)
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
        return AppDependencies(
            mode: .testStation,
            contextSources: composition.contextSources,
            voice: voice,
            cadence: TestStation.cadence,
            station: station,
            playback: MusicKitService.shared,
            interlude: interlude,
            dj: dj,
            studio: StudioPresentationModel(station: station, recipes: recipes, connections: connections, dj: dj),
            djSession: djSession,
            pickedNotes: nil)
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

    /// Song scrubbing (-Atlas): the one production assignment of `onSongSeeked`. A committed
    /// seek tells the DJ session the playing song's new time left, so its break is kept,
    /// re-armed or started (`DJBreakSession.songSeeked`). The boundary still comes only from
    /// the player.
    private static func wireSongSeek(session: DJBreakSession, playback: MusicKitService) {
        playback.onSongSeeked = { [session] index, remaining in
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
