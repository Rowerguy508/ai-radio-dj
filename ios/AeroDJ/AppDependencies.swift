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
    let dj: DJPresentationStore
    /// The one Studio model (#56). Created here, never in a view.
    let studio: StudioPresentationModel

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
        let consent = StaticIntegrationConsent(
            Dictionary(uniqueKeysWithValues: StationIntegration.allCases.map { ($0, ConsentState.notRequested) }))
        let station = StationConfigurationModel(store: FileStationConfigurationStore(fileURL: stationFileURL()),
                                                consent: consent)
        let voice = VoiceRenderer.onDeviceDefault()
        let dj = DJPresentationStore()
        // Live connection sources: the App Group inbox when it exists. Calendar and Notes
        // readers are not built yet, so they report "not determined" and cannot be authorized.
        let inbox = SharedInboxReview.appGroupInbox().map { [SharedInboxConnectionProvider(review: $0)] } ?? []
        // One preparer per launch: revoking a source purges prepared breaks as well as cached audio.
        let preparer = DJBreakPreparer(renderer: voice, userID: "listener", stationID: "default", cadence: DJCadence())
        let connections = ConnectionsModel(
            station: station,
            sourceReader: StaticConnectionSourceReader(),
            providers: inbox,
            purger: NarrationPurger(cache: voice.cache, preparer: preparer))
        let recipes = StationRecipeLibrary(store: FileStationRecipeStore(fileURL: supportURL("StationRecipes/recipes.json")))
        return AppDependencies(
            mode: .live,
            // Calendar policy is the default: no calendar is included until the user chooses one.
            contextSources: [CalendarContextSource(reader: EventKitCalendarReader())],
            voice: voice,
            cadence: DJCadence(),
            station: station,
            playback: MusicKitService.shared,
            dj: dj,
            studio: StudioPresentationModel(station: station, recipes: recipes, connections: connections, dj: dj))
    }

    #if DEBUG
    /// Synthetic only: fixture context, fixture station, $0 in-memory voice, no shared
    /// inbox and no calendar reader. Playback is Apple Music, the same session as live.
    private static func testStation() -> AppDependencies {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(
                snapshot: StationConfigurationSnapshot(state: StationConfigurationState(active: TestStation.configuration))),
            consent: TestStation.fixtureConsent)
        let voice = TestStation.makeRenderer(routes: [VoiceRoute.onDevice()],
                                             cache: InMemoryAudioCache(maxAge: TestStation.cacheRetention))
        let dj = DJPresentationStore()
        let preparer = DJBreakPreparer(renderer: voice, userID: TestStation.userID, stationID: TestStation.stationID,
                                       cadence: TestStation.cadence)
        let connections = ConnectionsModel(
            station: station,
            sourceReader: StaticConnectionSourceReader(),
            providers: [InMemoryConnectionItemProvider(integration: .shareInbox, items: [])],
            purger: NarrationPurger(cache: voice.cache, preparer: preparer))
        let recipes = StationRecipeLibrary(store: InMemoryStationRecipeStore())
        return AppDependencies(
            mode: .testStation,
            contextSources: TestStation.fixtureSources(),
            voice: voice,
            cadence: TestStation.cadence,
            station: station,
            playback: MusicKitService.shared,
            dj: dj,
            studio: StudioPresentationModel(station: station, recipes: recipes, connections: connections, dj: dj))
    }
    #endif

    private static func supportURL(_ path: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(path)
    }

    private static func stationFileURL() -> URL {
        supportURL("StationConfiguration/station.json")
    }
}
