import Foundation

// Station seeds: what a station is built from (one artist, a few artists, a genre, a
// playlist or a song), and how far it may reach from them. Pure values, stored inside
// `StationConfiguration` so recipes carry them with no extra field.
//
// Privacy (Fry's seeds rule, -Atlas): a `.library` seed's ID and name stay on the device.
// They never go into diagnostics, logs, cloud requests or paid voice requests. Seed names
// may reach the on-device DJ script only. `description`, `debugDescription` and the mirror
// below are redacted so string interpolation or `dump` cannot leak a name or an ID by
// accident; use `StationSeedDiagnostics` for anything that leaves the screen.

/// What a seed points at.
public enum StationSeedKind: String, Codable, Sendable, CaseIterable, Hashable {
    case artist, genre, playlist, song
}

/// Where a seed's ID comes from. `.library` IDs are the listener's own library and are private.
public enum StationSeedSource: String, Codable, Sendable, CaseIterable, Hashable {
    case catalog, library
}

/// One thing a station is built from.
public struct StationSeed: Codable, Hashable, Sendable {
    public var kind: StationSeedKind
    /// Apple Music catalog ID, or the library ID when `source == .library`.
    public var catalogID: String
    /// Display name (artist, genre, playlist or song title). Shown in the app only.
    public var name: String
    public var source: StationSeedSource

    public init(kind: StationSeedKind, catalogID: String, name: String, source: StationSeedSource = .catalog) {
        self.kind = kind
        self.catalogID = catalogID
        self.name = name
        self.source = source
    }

    public static let maxNameLength = 64

    /// De-duplication key: kind plus `catalogID` (Fry's rule (a)).
    public struct Key: Hashable, Sendable {
        public let kind: StationSeedKind
        public let catalogID: String
    }

    public var key: Key { Key(kind: kind, catalogID: catalogID) }

    /// Trimmed ID, trimmed name capped at `maxNameLength`, or `nil` when either is empty.
    public func normalized() -> StationSeed? {
        let id = catalogID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(Self.maxNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !capped.isEmpty else { return nil }
        return StationSeed(kind: kind, catalogID: id, name: capped, source: source)
    }

    private enum CodingKeys: String, CodingKey { case kind, catalogID, name, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decode(String.self, forKey: .kind)
        guard let kind = StationSeedKind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown seed kind")
        }
        self.kind = kind
        self.catalogID = try c.decode(String.self, forKey: .catalogID)
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        // An unknown or missing source is treated as private library data, never as catalog.
        self.source = (try? c.decodeIfPresent(String.self, forKey: .source))
            .flatMap(StationSeedSource.init(rawValue:)) ?? .library
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(catalogID, forKey: .catalogID)
        try c.encode(name, forKey: .name)
        try c.encode(source.rawValue, forKey: .source)
    }
}

extension StationSeed: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Redacted: kind and source only.
    public var description: String { "StationSeed(\(kind.rawValue), \(source.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["kind": kind, "source": source], displayStyle: .struct) }
}

/// How far a station may go from its seeds.
public enum StationReach: String, Codable, Sendable, CaseIterable, Hashable {
    /// Only the seeds: the artist's own songs, the playlist, the genre chart, the song.
    case only
    /// The seeds plus similar artists.
    case related
    /// Related plus the wider genre and chart neighbourhood.
    case broad

    public static let `default` = StationReach.related
}

/// What a seed list is allowed to say outside the app: enums, booleans and counts only.
/// Never a seed name or ID (catalog or library).
public struct StationSeedDiagnostics: Equatable, Sendable, CustomStringConvertible {
    public let reach: StationReach
    public let seedCount: Int
    public let librarySeedCount: Int
    public let countsByKind: [StationSeedKind: Int]

    public init(seeds: [StationSeed], reach: StationReach) {
        self.reach = reach
        self.seedCount = seeds.count
        self.librarySeedCount = seeds.filter { $0.source == .library }.count
        self.countsByKind = seeds.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    public init(_ configuration: StationConfiguration) {
        self.init(seeds: configuration.seeds, reach: configuration.reach)
    }

    public var hasLibrarySeeds: Bool { librarySeedCount > 0 }

    public var description: String {
        let kinds = StationSeedKind.allCases.map { "\($0.rawValue)=\(countsByKind[$0, default: 0])" }.joined(separator: " ")
        return "seeds=\(seedCount) library=\(librarySeedCount) reach=\(reach.rawValue) \(kinds)"
    }
}
