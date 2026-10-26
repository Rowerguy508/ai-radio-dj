import AeroDJCore
import SwiftUI

/// Station selection screen. Adaptive container sizing (no hardcoded device dims).
struct StationListView: View {
    /// Composed once at launch by `AppDependencies`; views receive it, never build it.
    let dependencies: AppDependencies
    @State private var stations: [Station] = Station.mockStations
    @State private var showSharedInbox = false

    var body: some View {
        #if DEBUG
        if StudioCapture.isRequested(mode: dependencies.mode) {
            StudioCaptureView(dependencies: dependencies)
        } else {
            stationList
        }
        #else
        stationList
        #endif
    }

    private var stationList: some View {
        NavigationStack {
            List(stations) { station in
                NavigationLink(value: station) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(station.name).font(.headline)
                        Text(station.description ?? "").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("AeroDJ")
            .task { await dependencies.start() }
            .toolbar {
                // The real App Group inbox is never opened in the test station: its
                // data must not appear next to fixtures.
                if dependencies.mode == .live {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSharedInbox = true
                        } label: {
                            Label("Shared Items", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationDestination(for: Station.self) { station in
                PlayerView(station: station, music: dependencies.playback, djSession: dependencies.djSession,
                           studio: dependencies.studio, isTestStation: dependencies.mode == .testStation)
            }
            .sheet(isPresented: $showSharedInbox) {
                if dependencies.mode == .live, let review = SharedInboxReview.appGroupInbox() {
                    SharedInboxReviewView(review: review)
                }
            }
        }
        // Live only: lets Connections offer the .md file picker (nil in the test station).
        .environment(\.pickedNotes, dependencies.pickedNotes)
    }
}

/// Lightweight station model for the app shell. Domain types live in AeroDJCore.
struct Station: Identifiable, Hashable {
    let id: UUID
    let name: String
    let description: String?

    static let mockStations: [Station] = [
        Station(id: UUID(), name: "Morning Calm", description: "Warm, unhurried host"),
        Station(id: UUID(), name: "Late Night", description: "Smooth vinyl-bar vibes"),
    ]
}

#Preview {
    StationListView(dependencies: AppDependencies.make())
}
