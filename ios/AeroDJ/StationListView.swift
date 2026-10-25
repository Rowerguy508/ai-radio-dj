import SwiftUI

/// Station selection screen. Adaptive container sizing (no hardcoded device dims).
struct StationListView: View {
    @State private var stations: [Station] = Station.mockStations

    var body: some View {
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
            .navigationDestination(for: Station.self) { station in
                PlayerView(station: station)
            }
        }
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
    StationListView()
}
