import Foundation

// Station creation (-Atlas): "make a station from these artists / this genre / this playlist,
// at this discovery level". Pure values over the existing model: the result is an ordinary
// `StationConfiguration` (seeds + reach + discovery), saved as an ordinary `StationRecipe`
// through `StudioPresentationModel.saveRecipe(named:from:applying:)`. No new persisted fields.
//
// Privacy: seeds keep their existing redaction (`StationSeed.description`). Nothing here logs.
// Errors carry no seed data, so they are safe for diagnostics as well as on-screen copy.

/// What a new station is built from.
public enum StationCreationSource: Equatable, Sendable {
    /// One to `StationCreationRequest.maxArtists` artists (catalog or library).
    case artists([StationSeed])
    /// One Apple Music catalog genre. Its ID must be numeric (`StationSeed.isValidCatalogGenreID`).
    case genre(StationSeed)
    /// One playlist, from the catalog or the listener's library (a library playlist plays only itself).
    case playlist(StationSeed)

    /// The kind every seed in this source must have.
    public var kind: StationCreationKind {
        switch self {
        case .artists: .artists
        case .genre: .genre
        case .playlist: .playlist
        }
    }

    public var seeds: [StationSeed] {
        switch self {
        case .artists(let seeds): seeds
        case .genre(let seed), .playlist(let seed): [seed]
        }
    }
}

/// The three ways to start a station, for a picker. Raw values are stable; never rename one.
public enum StationCreationKind: String, Sendable, CaseIterable, Hashable, Codable {
    case artists, genre, playlist

    /// The seed kind this way of starting a station picks.
    public var seedKind: StationSeedKind {
        switch self {
        case .artists: .artist
        case .genre: .genre
        case .playlist: .playlist
        }
    }

    /// How many seeds may be picked.
    public var maxSeeds: Int {
        switch self {
        case .artists: StationCreationRequest.maxArtists
        case .genre, .playlist: 1
        }
    }

    public var title: String {
        switch self {
        case .artists: "Artists"
        case .genre: "Genre"
        case .playlist: "Playlist"
        }
    }
}

/// Why a station can't be created. Carries no names or IDs.
public enum StationCreationError: Error, Equatable, Sendable, CaseIterable {
    /// Nothing picked, or every pick was blank.
    case noSeeds
    /// More artists than `StationCreationRequest.maxArtists`, or more than one genre or playlist.
    case tooManySeeds
    /// A seed of another kind (for example a song in an artists station).
    case wrongSeedKind
    /// A genre ID that is not a plain run of ASCII digits (never reaches a catalog URL).
    case invalidGenreID
    /// A library genre: genres come from the Apple Music catalog only, so it would play nothing.
    case libraryGenre

    public var userMessage: String {
        switch self {
        case .noSeeds: "Pick something to build the station from."
        case .tooManySeeds: "Pick up to \(StationCreationRequest.maxArtists) artists, or one genre or playlist."
        case .wrongSeedKind: "That pick doesn't fit this kind of station."
        case .invalidGenreID, .libraryGenre: "That genre isn't available. Pick another one."
        }
    }
}

/// One "create a station" request: what it is built from and how adventurous it is.
public struct StationCreationRequest: Equatable, Sendable {
    /// Five keeps a multi-artist station recognisably about each of them (round-robin opening).
    /// Never more than `StationConfiguration.Limits.maxSeeds`.
    public static let maxArtists = min(5, StationConfiguration.Limits.maxSeeds)

    public var source: StationCreationSource
    public var level: StationDiscoveryLevel

    public init(source: StationCreationSource, level: StationDiscoveryLevel = .default) {
        self.source = source
        self.level = level
    }

    /// The seeds this request would save, normalized (trimmed, de-duplicated, order kept), or why not.
    /// Over-long lists fail rather than being cut, so the listener never loses a pick silently.
    public func validatedSeeds() -> Result<[StationSeed], StationCreationError> {
        let kind = source.kind
        let raw = source.seeds
        guard raw.allSatisfy({ $0.kind == kind.seedKind }) else { return .failure(.wrongSeedKind) }
        let seeds = StationConfiguration.normalizedSeeds(raw)
        guard !seeds.isEmpty else { return .failure(.noSeeds) }
        guard seeds.count <= kind.maxSeeds else { return .failure(.tooManySeeds) }
        if kind == .genre, let genre = seeds.first {
            guard genre.source == .catalog else { return .failure(.libraryGenre) }
            guard StationSeed.isValidCatalogGenreID(genre.catalogID) else { return .failure(.invalidGenreID) }
        }
        return .success(seeds)
    }

    /// A station configuration for this request. Keeps `base`'s tuning (energy, tags, DJ
    /// personality, talk, briefing), replaces seeds, reach and discovery with the request's, and
    /// never carries connections (`requestedIntegrations` is emptied, as in a recipe).
    public func configuration(base: StationConfiguration = .default) -> Result<StationConfiguration, StationCreationError> {
        validatedSeeds().map { seeds in
            var config = base
            config.seeds = seeds
            config.requestedIntegrations = []
            return level.applied(to: config)
        }
    }

    /// Set when the level's reach can't be used: a library pick plays only itself.
    public var reachRestriction: StationReachRestriction? {
        StationReach.restriction(for: source.seeds)
    }

    /// A name to prefill: "<Artist> Radio", "<A> & <B> Radio", "<Genre> Radio" or the playlist's
    /// name, fitted to `StationRecipe.maxNameLength`. `nil` when the request is invalid. On-screen only.
    public var suggestedName: String? {
        guard case .success(let seeds) = validatedSeeds(), let first = seeds.first else { return nil }
        let name: String
        switch source.kind {
        case .artists:
            switch seeds.count {
            case 1: name = first.name + " Radio"
            case 2: name = first.name + " & " + seeds[1].name + " Radio"
            default: name = first.name + " & Friends Radio"
            }
        case .genre: name = first.name + " Radio"
        case .playlist: name = first.name
        }
        return StarterStationSuggester.fitName(name)
    }
}
