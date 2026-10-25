import SwiftUI

/// Station Discovery. Editorial "AeroDJ" heading, one featured station, and
/// tactile selection cards with clearly differentiated states. Uses a zoom
/// navigation transition (with matchedTransitionSource) so browsing -> Now
/// Playing feels continuous.
struct StationListView: View {
    @State private var stations: [Station] = Station.mockStations
    @State private var isLoading = false
    @State private var selectedID: UUID?
    @Namespace private var namespace

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if isLoading {
                        loadingView
                    } else if stations.isEmpty {
                        emptyView
                    } else {
                        featuredStation
                        stationGrid
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(.systemBackground))
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
                    .navigationTransition(.zoom(sourceID: station.id, in: namespace))
            }
        }
        .task { await loadStations() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AeroDJ")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text("Live radio, tuned to you")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Featured station

    private var featuredStation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Featured")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            if let featured = stations.first {
                NavigationLink(value: featured) {
                    FeaturedStationCard(station: featured)
                        .matchedTransitionSource(id: featured.id, in: namespace)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Station grid

    private var stationGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All Stations")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(stations) { station in
                    NavigationLink(value: station) {
                        StationCard(
                            station: station,
                            isSelected: station.id == selectedID,
                            isPlaying: station.id == selectedID
                        )
                        .matchedTransitionSource(id: station.id, in: namespace)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading stations…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading stations")
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No stations",
            systemImage: "dot.radiowaves.left.and.right",
            description: Text("Add a station to get started.")
        )
        .padding(.vertical, 40)
    }

    private func loadStations() async {
        isLoading = true
        // Mock load; real source replaces this.
        try? await Task.sleep(nanoseconds: 500_000_000)
        stations = Station.mockStations
        isLoading = false
    }
}

/// Featured station — large artwork, DJ name, personality description.
struct FeaturedStationCard: View {
    let station: Station

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stationArtwork
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.title2.weight(.bold))
                Text(station.djName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(station.description ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(station.accessibilityLabel)
    }

    private var stationArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo, .purple],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.white)
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }
}

/// Tactile station card with differentiated selected/playing states.
struct StationCard: View {
    let station: Station
    let isSelected: Bool
    let isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [.indigo, .purple],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.3), in: Circle())
                        .padding(6)
                        .accessibilityLabel("Playing")
                }
            }
            Text(station.name)
                .font(.headline)
                .lineLimit(1)
            Text(station.djName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(station.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lightweight station model for the app shell. Domain types live in AeroDJCore.
struct Station: Identifiable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    let djName: String

    var accessibilityLabel: String {
        "\(name), DJ \(djName), \(description ?? "")"
    }

    static let mockStations: [Station] = [
        Station(id: UUID(), name: "Morning Calm", description: "Warm, unhurried host", djName: "Maya"),
        Station(id: UUID(), name: "Late Night", description: "Smooth vinyl-bar vibes", djName: "Rico"),
        Station(id: UUID(), name: "Focus Flow", description: "Deep work, no chatter", djName: "Nia"),
    ]
}

#Preview {
    StationListView()
}