import Foundation

// Sample values for SwiftUI previews and tests. Synthetic: no real user data.
public extension StationConfiguration {
    static let sampleMorningMix = StationConfiguration(
        genres: ["indie pop", "neo soul", "electronic"],
        moods: ["bright", "focused"],
        energy: 0.6,
        discovery: 0.4,
        personality: .warm,
        commentary: .occasional,
        briefing: .init(enabled: true, window: .init(startMinute: 6 * 60 + 30, durationMinutes: 90),
                        targetSeconds: 300, sections: [.calendar, .sharedItems]),
        requestedIntegrations: [.calendar, .shareInbox]
    )

    static let sampleLateNight = StationConfiguration(
        genres: ["ambient", "jazz"],
        moods: ["calm"],
        energy: 0.2,
        discovery: 0.1,
        personality: .minimal,
        commentary: .rare,
        briefing: .init(enabled: false),
        requestedIntegrations: []
    )
}

public extension StationConfigurationState {
    /// Energy and genres edited mid-song: pending until the next song boundary.
    static let samplePendingEdit = StationConfigurationState(
        active: .sampleMorningMix,
        pending: {
            var c = StationConfiguration.sampleMorningMix
            c.energy = 0.85
            c.genres.append("house")
            c.personality = .upbeat
            return c
        }()
    )
}

@MainActor
public extension StationConfigurationModel {
    /// A loaded model for previews: calendar granted, share inbox awaiting consent review,
    /// Obsidian denied, with a pending energy/genre/personality edit.
    static func preview(state: StationConfigurationState = .samplePendingEdit,
                        consent: [StationIntegration: ConsentState] = [
                            .calendar: .granted, .shareInbox: .notRequested, .obsidian: .denied,
                        ]) async -> StationConfigurationModel {
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: state)),
            consent: StaticIntegrationConsent(consent))
        await model.load()
        return model
    }
}
