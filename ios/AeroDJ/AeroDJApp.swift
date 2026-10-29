import AeroDJCore
import OSLog
import SwiftUI

@main
struct AeroDJApp: App {
    /// nil only in a P0 diagnostic build launched in Direct Mode: then nothing of the normal app
    /// (MusicKitService, DJ session, interlude, studio) is created at all.
    private let dependencies: AppDependencies?

    init() {
        #if AERODJ_P0_DIAG
        // TEMPORARY P0 Experiment A (remove with #121 / #133) -Atlas
        if DirectModeLaunch.takeLaunchChoice() {
            dependencies = nil
            Logger(subsystem: "com.aerodj.app", category: "runtime").notice("runtime mode: p0DirectMode")
            return
        }
        #endif
        #if AERODJ_P0_DIAG
        P0EventTraceHost.shared.start()
        #endif
        let dependencies = AppDependencies.make()
        self.dependencies = dependencies
        // Runtime evidence of the dependency set this launch actually uses. `notice`, not
        // `info`: info-level messages are not persisted, so `log show` could not read them.
        Logger(subsystem: "com.aerodj.app", category: "runtime")
            .notice("runtime mode: \(dependencies.mode.rawValue, privacy: .public), context sources: \(dependencies.contextSources.count)")
    }

    var body: some Scene {
        WindowGroup {
            if let dependencies {
                StationListView(dependencies: dependencies)
                    // Starts the one studio and the one DJ session. Station selection and the
                    // MusicKit player stay on the split root below this window.
                    .task { await dependencies.start() }
                    #if AERODJ_P0_DIAG
                    .modifier(P0ScenePhaseTrace())
                    #endif
            } else {
                directModeRoot
            }
        }
    }

    @ViewBuilder
    private var directModeRoot: some View {
        #if AERODJ_P0_DIAG
        DirectModeView()
        #else
        EmptyView()
        #endif
    }
}
