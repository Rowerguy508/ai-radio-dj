import AeroDJCore
import SwiftUI

/// Station selection screen. Adaptive container sizing (no hardcoded device dims).
struct StationListView: View {
    /// Composed once at launch by `AppDependencies`; views receive it, never build it.
    let dependencies: AppDependencies
    @State private var stations: [Station] = Station.mockStations
    @State private var showSharedInbox = false

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSharedInbox = true
                    } label: {
                        Label("Shared Items", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationDestination(for: Station.self) { station in
                PlayerView(station: station)
            }
            .sheet(isPresented: $showSharedInbox) {
                if let review = SharedInboxReview.appGroupInbox() {
                    SharedInboxReviewView(review: review)
                }
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
    StationListView(dependencies: AppDependencies.make())
}
