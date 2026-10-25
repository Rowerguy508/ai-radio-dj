import AeroDJCore
import OSLog
import SwiftUI

@main
struct AeroDJApp: App {
    private let dependencies: AppDependencies

    init() {
        let dependencies = AppDependencies.make()
        self.dependencies = dependencies
        // Runtime evidence of the dependency set this launch actually uses. `notice`, not
        // `info`: info-level messages are not persisted, so `log show` could not read them.
        Logger(subsystem: "com.aerodj.app", category: "runtime")
            .notice("runtime mode: \(dependencies.mode.rawValue, privacy: .public), context sources: \(dependencies.contextSources.count)")
    }

    var body: some Scene {
        WindowGroup {
            StationListView(dependencies: dependencies)
        }
    }
}
