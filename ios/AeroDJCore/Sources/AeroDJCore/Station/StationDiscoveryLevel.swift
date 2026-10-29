import Foundation

// Discovery levels (-Atlas): three named presets over the two knobs a station already has,
// `StationConfiguration.discovery` (familiar vs new songs within a tier) and
// `StationConfiguration.reach` (which tiers: the seeds, similar artists, the wider genre).
//
// Nothing new is persisted. A level is written into those two existing fields and read back
// from them, so every station and recipe saved before levels existed decodes unchanged, and the
// default configuration (discovery 0.3, reach `.related`) reads as `.balanced`.
//
// The queue mix is `StationPoolBuilder.build(_:reach:discovery:options:)`, which is pure and
// deterministic: the same pool and level always give the same list.

/// How far a station strays from what it was built from.
public enum StationDiscoveryLevel: String, Codable, Sendable, CaseIterable, Hashable {
    /// The seeds' own songs only (reach `.only`), hits first: new songs only once hits run out.
    case familiar
    /// The seeds plus similar artists (reach `.related`), about 3 in 10 songs new. The default.
    case balanced
    /// The seeds, similar artists and the wider genre (reach `.broad`), about 7 in 10 songs new.
    case adventurous

    public static let `default` = StationDiscoveryLevel.balanced

    /// The `StationConfiguration.discovery` value this level writes.
    public var discovery: Double {
        switch self {
        case .familiar: 0.1
        case .balanced: 0.3
        case .adventurous: 0.7
        }
    }

    /// The `StationConfiguration.reach` this level asks for. Library seeds still clamp it to
    /// `.only` (`StationReach.effective(for:)`), so a library playlist stays on the device.
    public var reach: StationReach {
        switch self {
        case .familiar: .only
        case .balanced: .related
        case .adventurous: .broad
        }
    }

    /// Short picker title. Fixed copy; carries no station data.
    public var title: String {
        switch self {
        case .familiar: "Familiar"
        case .balanced: "Balanced"
        case .adventurous: "Adventurous"
        }
    }

    /// One-line picker description. Fixed copy; carries no station data.
    public var summary: String {
        switch self {
        case .familiar: "Just what you picked, favourites first."
        case .balanced: "What you picked plus similar artists, with some new songs."
        case .adventurous: "Goes further into the genre. Mostly new songs."
        }
    }

    /// `configuration` with this level's discovery and reach, validated (library seeds keep `.only`).
    /// Every other field is unchanged.
    public func applied(to configuration: StationConfiguration) -> StationConfiguration {
        var copy = configuration
        copy.discovery = discovery
        copy.reach = reach
        return copy.validated()
    }

    /// The level `configuration` was set to, or `nil` when its discovery or reach was tuned by
    /// hand to something no level writes (the UI can show "Custom"). A library station, whose
    /// reach is always `.only`, matches on discovery alone.
    public static func matching(_ configuration: StationConfiguration) -> StationDiscoveryLevel? {
        let config = configuration.validated()
        return allCases.first { level in
            level.discovery == config.discovery && level.reach.effective(for: config.seeds) == config.reach
        }
    }

    /// The nearest level, for preselecting a picker on a hand-tuned station. Reach decides first
    /// (it changes which songs can play at all); discovery breaks the tie; equal distances pick
    /// the more familiar level. A library station is judged on discovery alone.
    public static func closest(to configuration: StationConfiguration) -> StationDiscoveryLevel {
        if let exact = matching(configuration) { return exact }
        let config = configuration.validated()
        let reachLocked = StationReach.allowed(for: config.seeds) == [.only]
        func cost(_ level: StationDiscoveryLevel) -> (Int, Double) {
            let reachMiss = reachLocked || level.reach == config.reach ? 0 : 1
            // Rounded so 0.2 sits exactly between 0.1 and 0.3 despite binary floating point.
            return (reachMiss, (abs(level.discovery - config.discovery) * 1_000_000).rounded())
        }
        return allCases.min { cost($0) < cost($1) } ?? .default
    }
}

public extension StationPoolBuilder {
    /// Builds a queue for `configuration`'s reach and discovery (and so its level). The reach is
    /// clamped by the configuration's seeds, as `validated()` does.
    static func build(_ pool: StationCandidatePool, configuration: StationConfiguration,
                      options: Options = .init()) -> [StationCandidate] {
        let config = configuration.validated()
        return build(pool, reach: config.reach, discovery: config.discovery, options: options)
    }
}
