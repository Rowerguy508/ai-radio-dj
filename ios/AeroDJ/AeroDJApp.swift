import AeroDJCore
import OSLog
import SwiftUI

@main
struct AeroDJApp: App {
    private let dependencies: AppDependencies

    init() {
        #if AERODJ_P0_DIAG
        P0EventTraceHost.shared.start()
        #endif
        // The phone window and the CarPlay scene share this root.
        let dependencies = AppRuntime.dependencies
        self.dependencies = dependencies
        // Runtime evidence of the dependency set this launch actually uses. `notice`, not
        // `info`: info-level messages are not persisted, so `log show` could not read them.
        Logger(subsystem: "com.aerodj.app", category: "runtime")
            .notice("runtime mode: \(dependencies.mode.rawValue, privacy: .public), context sources: \(dependencies.contextSources.count)")
    }

    var body: some Scene {
        WindowGroup {
            StationListView(dependencies: dependencies)
                // Station ratings (-Nova, PR B): the rating button, its toast and the recipe delete.
                .environment(\.songRating, dependencies.songRating)
                // #401 (-Fry): Tune's "Local weather & news" card; nil in the test station.
                .environment(\.localFacts, dependencies.localFacts)
                // Starts the one studio, DJ session, and playback binder. The CarPlay
                // scene calls the same start. Station selection and the MusicKit player
                // stay on the split root below this window.
                .task { await AppRuntime.startIfNeeded() }
                #if AERODJ_P0_DIAG
                .modifier(P0ScenePhaseTrace())
                #endif
        }
    }
}
