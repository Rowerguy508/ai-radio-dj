import Foundation

// Built-in stations (#442). Morning Calm and Late Night are real stations: each has
// catalog song seeds, so the existing seed engine (`CatalogStationSeedResolver`,
// `StationPoolBuilder`) can build a queue. No second catalog. The ids match the
// rows the phone and CarPlay already list.

/// One station that ships with the app.
public struct BuiltInStation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    /// Shown on the station row. Fixed copy, not a listener's words.
    public let summary: String
    public let configuration: StationConfiguration

    public init(id: UUID, name: String, summary: String, configuration: StationConfiguration) {
        self.id = id
        self.name = name
        self.summary = summary
        self.configuration = configuration
    }
}

public enum BuiltInStations {
    public static let morningCalm = BuiltInStation(
        id: UUID(uuidString: "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D")!,
        name: "Morning Calm",
        summary: "Warm, unhurried host",
        configuration: StationConfiguration(
            genres: ["indie folk", "soul"],
            moods: ["calm", "warm"],
            energy: 0.35,
            discovery: 0.25,
            personality: .warm,
            commentary: .occasional,
            briefing: .init(enabled: false),
            seeds: morningCalmSeeds,
            reach: .related))

    public static let lateNight = BuiltInStation(
        id: UUID(uuidString: "8D3B2C21-5F60-4B7C-9D0E-1F2A3B4C5D6E")!,
        name: "Late Night",
        summary: "Smooth vinyl-bar vibes",
        configuration: StationConfiguration(
            genres: ["jazz", "downtempo"],
            moods: ["calm"],
            energy: 0.2,
            discovery: 0.15,
            personality: .minimal,
            commentary: .rare,
            briefing: .init(enabled: false),
            seeds: lateNightSeeds,
            reach: .related))

    public static let all: [BuiltInStation] = [morningCalm, lateNight]

    public static func station(id: UUID) -> BuiltInStation? {
        all.first { $0.id == id }
    }

    /// Mellow morning songs. Catalog ids from the Apple Music catalog (US storefront).
    private static let morningCalmSeeds: [StationSeed] = [
        song("1625058461", "Don't Know Why"),
        song("1440857786", "Better Together"),
        song("724884380", "Put Your Records On"),
        song("828118037", "Heartbeats"),
        song("391725492", "Lovely Day"),
        song("1440857795", "Banana Pancakes"),
        song("5644874", "Naked As We Came"),
        song("281086428", "White Winter Hymnal"),
    ]

    /// Late-night songs. Catalog ids from the Apple Music catalog (US storefront).
    private static let lateNightSeeds: [StationSeed] = [
        song("604770244", "Smooth Operator"),
        song("268443097", "So What"),
        song("1440865800", "My Funny Valentine"),
        song("1625058484", "Come Away With Me"),
        song("1794866252", "Tadow"),
        song("1266067536", "Nothing's Gonna Hurt You Baby"),
        song("1440653206", "Glory Box"),
        song("693063876", "La Femme d'argent"),
    ]

    private static func song(_ id: String, _ name: String) -> StationSeed {
        StationSeed(kind: .song, catalogID: id, name: name, source: .catalog)
    }
}
