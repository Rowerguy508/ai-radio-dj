import SwiftUI

@main
struct AeroDJApp: App {
    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    /// Screenshot harness: `AERODJ_LAUNCH=player` boots straight into the
    /// player/studio so CI can capture layouts; default is station discovery.
    @ViewBuilder
    private var rootView: some View {
        if ProcessInfo.processInfo.environment["AERODJ_LAUNCH"] == "player" {
            PlayerView(station: Station(id: UUID(), name: "Morning Calm", description: nil, djName: "Maya"))
        } else {
            StationListView()
        }
    }
}