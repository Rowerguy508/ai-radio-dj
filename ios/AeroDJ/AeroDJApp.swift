import AeroDJCore
import OSLog
import SwiftUI

@main
struct AeroDJApp: App {
    private let dependencies: AppDependencies
    #if DEBUG
    /// UI-test screenshots only (`-AERODJ_UITEST_DISABLE_ANIMATIONS YES`); see CaptureMotionFreeze.
    private let freezesMotion: Bool
    #endif

    init() {
        #if AERODJ_P0_DIAG
        P0EventTraceHost.shared.start()
        #endif
        let dependencies = AppDependencies.make()
        self.dependencies = dependencies
        #if DEBUG
        freezesMotion = CaptureMotionFreeze.installIfRequested(mode: dependencies.mode)
        #endif
        // Runtime evidence of the dependency set this launch actually uses. `notice`, not
        // `info`: info-level messages are not persisted, so `log show` could not read them.
        Logger(subsystem: "com.aerodj.app", category: "runtime")
            .notice("runtime mode: \(dependencies.mode.rawValue, privacy: .public), context sources: \(dependencies.contextSources.count)")
    }

    var body: some Scene {
        WindowGroup {
            StationListView(dependencies: dependencies)
                // Starts the one studio and the one DJ session. Station selection and the
                // MusicKit player stay on the split root below this window.
                .task { await dependencies.start() }
                #if AERODJ_P0_DIAG
                .modifier(P0ScenePhaseTrace())
                #endif
                #if DEBUG
                .modifier(CaptureMotionFreezeRoot(active: freezesMotion))
                #endif
        }
    }
}
