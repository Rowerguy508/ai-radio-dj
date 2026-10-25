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
        return AppDependencies(
            mode: .live,
            // Calendar policy is the default: no calendar is included until the user chooses one.
            contextSources: [CalendarContextSource(reader: EventKitCalendarReader())],
            voice: VoiceRenderer.onDeviceDefault(),
            cadence: DJCadence(),
            station: StationConfigurationModel(store: FileStationConfigurationStore(fileURL: stationFileURL()),
                                               consent: consent))
    }

    #if DEBUG
    private static func testStation() -> AppDependencies {
        AppDependencies(
            mode: .testStation,
            contextSources: TestStation.fixtureSources(),
            voice: TestStation.makeRenderer(routes: [VoiceRoute.onDevice()],
                                            cache: InMemoryAudioCache(maxAge: TestStation.cacheRetention)),
            cadence: TestStation.cadence,
            station: StationConfigurationModel(
                store: InMemoryStationConfigurationStore(
                    snapshot: StationConfigurationSnapshot(state: StationConfigurationState(active: TestStation.configuration))),
                consent: TestStation.fixtureConsent))
    }
    #endif

    private static func stationFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("StationConfiguration/station.json")
    }
}
