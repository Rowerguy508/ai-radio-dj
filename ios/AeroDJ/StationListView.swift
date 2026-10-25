import SwiftUI

/// Station selection screen. Adaptive container sizing (no hardcoded device dims).
/// Handles loading / empty states and links to the player + settings.
struct StationListView: View {
    @State private var stations: [Station] = Station.mockStations
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading stations…")
                } else if stations.isEmpty {
                    ContentUnavailableView(
                        "No stations",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Add a station to get started.")
                    )
                } else {
                    List(stations) { station in
                        NavigationLink(value: station) {
                            StationRow(station: station)
                        }
                    }
                }
            }
            .navigationTitle("AeroDJ")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: Station.self) { station in
                PlayerView(station: station)
            }
        }
        .task { await loadStations() }
    }

    private func loadStations() async {
        isLoading = true
        // Mock load; real source replaces this.
        try? await Task.sleep(nanoseconds: 500_000_000)
        stations = Station.mockStations
        isLoading = false
    }
}

/// A single station row with adaptive sizing and accessibility.
struct StationRow: View {
    let station: Station

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.headline)
                Text(station.description ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(station.accessibilityLabel)
    }
}

/// Lightweight station model for the app shell. Domain types live in AeroDJCore.
struct Station: Identifiable, Hashable {
    let id: UUID
    let name: String
    let description: String?

    var accessibilityLabel: String {
        description.map { "\(name), \($0)" } ?? name
    }

    static let mockStations: [Station] = [
        Station(id: UUID(), name: "Morning Calm", description: "Warm, unhurried host"),
        Station(id: UUID(), name: "Late Night", description: "Smooth vinyl-bar vibes"),
        Station(id: UUID(), name: "Focus Flow", description: "Deep work, no chatter"),
    ]
}

#Preview {
    StationListView()
}