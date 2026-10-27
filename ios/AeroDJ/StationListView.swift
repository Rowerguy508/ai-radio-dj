import AeroDJCore
import SwiftUI

/// Station selection screen. Adaptive container sizing (no hardcoded device dims).
struct StationListView: View {
    /// Composed once at launch by `AppDependencies`; views receive it, never build it.
    let dependencies: AppDependencies
    @State private var stations: [Station] = Station.mockStations
    @State private var showSharedInbox = false
    /// Only a station-row tap writes this. A song tap reads it and must not change it.
    @State private var opened = OpenedStation()
    @State private var path = NavigationPath()

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
        NavigationStack(path: $path) {
            List(stations) { station in
                Button {
                    opened.open(StationRef(id: station.id.uuidString, name: station.name))
                    path.append(station)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(station.name).font(.headline)
                        Text(station.description ?? "").font(.subheadline).foregroundStyle(AeroDJPalette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("AeroDJ")
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
            .navigationDestination(for: Station.self) { linked in
                // Song taps must not move the selection. Ignore a destination value that
                // is not the station the row tap opened.
                PlayerView(station: stationForPlayback(fallback: linked), music: dependencies.playback,
                           interlude: dependencies.interlude, djSession: dependencies.djSession,
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

    /// The opened station, when it is still in the list. Otherwise the linked row.
    private func stationForPlayback(fallback: Station) -> Station {
        guard let id = opened.stationForSongTap()?.id,
              let match = stations.first(where: { $0.id.uuidString == id }) else { return fallback }
        return match
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
