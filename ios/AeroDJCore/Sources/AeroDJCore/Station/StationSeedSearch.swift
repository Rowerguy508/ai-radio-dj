import Foundation

// Wizard helpers for station seeds (-Atlas): which reach a seed set allows, the search result
// the picker shows, and the blank-term and cancellation rules every seed search follows.

// MARK: Reach allowed by a seed set

/// Why the reach picker limits the choices. On-screen only; carries no seed data.
public enum StationReachRestriction: String, Sendable, Hashable, CaseIterable {
    /// At least one seed is from the library. Library seeds stay on the device and are never
    /// expanded through the catalog, so the station plays only what was picked (Fry's rule (d)).
    case librarySeeds

    /// Short copy for the picker.
    public var message: String {
        switch self {
        case .librarySeeds:
            "Picks from your library stay on your device, so this station plays only what you picked."
        }
    }
}

public extension StationReach {
    /// The reach a single seed may use: `.only` for a `.library` seed, all three for a catalog seed.
    static func allowed(for seed: StationSeed) -> Set<StationReach> {
        seed.source == .library ? [.only] : Set(allCases)
    }

    /// The reach choices for a seed set. One rule everywhere (the picker, `validated()`, the
    /// suggester and the resolver): any library seed limits the whole station to `.only`; an empty
    /// set or an all-catalog set allows all three. Invalid seeds are ignored, as `validated()` drops them.
    static func allowed(for seeds: [StationSeed]) -> Set<StationReach> {
        StationConfiguration.normalizedSeeds(seeds)
            .reduce(into: Set(allCases)) { $0.formIntersection(allowed(for: $1)) }
    }

    /// Why the choices for `seeds` are limited, or `nil` when every reach is allowed.
    static func restriction(for seeds: [StationSeed]) -> StationReachRestriction? {
        StationConfiguration.normalizedSeeds(seeds).contains { $0.source == .library } ? .librarySeeds : nil
    }

    /// The reach actually used for a seed set: `self` when allowed, otherwise `.only`.
    func effective(for seeds: [StationSeed]) -> StationReach {
        StationReach.allowed(for: seeds).contains(self) ? self : .only
    }
}

// MARK: Search results

/// One row in the wizard's seed search. Display-only and never persisted: only `seed` is saved
/// (into a draft `StationConfiguration`). `subtitle` is the artist for a song and the curator for a
/// playlist; `artworkURL` comes from MusicKit artwork. Neither may be logged or put in diagnostics,
/// so `description` and `dump` are redacted.
public struct StationSeedSearchResult: Identifiable, Hashable, Sendable {
    public var seed: StationSeed
    public var subtitle: String?
    public var artworkURL: URL?

    public init(seed: StationSeed, subtitle: String? = nil, artworkURL: URL? = nil) {
        self.seed = seed
        self.subtitle = subtitle
        self.artworkURL = artworkURL
    }

    /// Unique within one result list: the seed's kind plus catalog ID.
    public var id: StationSeed.Key { seed.key }
}

extension StationSeedSearchResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "StationSeedSearchResult(\(seed.kind.rawValue), \(seed.source.rawValue), subtitle=\(subtitle != nil), artwork=\(artworkURL != nil))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description]) }
}

// MARK: Search rules

/// The rules every seed search follows, kept here so they're tested on Linux.
public enum StationSeedSearch {
    /// MusicKit's catalog search accepts at most 25 results per type.
    public static let maxLimit = 25
    /// Longer terms are cut; nobody types 100 characters into a seed search.
    public static let maxTermLength = 100

    /// The term to send, or `nil` for a blank or whitespace-only term (search nothing).
    /// Trims, collapses inner whitespace to single spaces and caps the length.
    public static func normalizedTerm(_ term: String) -> String? {
        let words = term.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        let capped = String(joined.prefix(maxTermLength)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }

    /// `limit` clamped to 1...`maxLimit`.
    public static func normalizedLimit(_ limit: Int) -> Int { min(max(limit, 1), maxLimit) }

    /// Runs a search under the rules: a blank term returns `[]` without calling `perform` (so
    /// nothing touches the network); cancellation is checked before and after `perform`, and a
    /// cancelled search throws `CancellationError` and never returns partial results, even when
    /// the request itself reports the cancellation as some other error (a URL or MusicKit error).
    /// Runs on the caller's actor (`#isolation`), so an actor's own search closure can be passed.
    public static func run<Result: Sendable>(
        term: String,
        limit: Int,
        isolation: isolated (any Actor)? = #isolation,
        perform: (_ term: String, _ limit: Int) async throws -> [Result]
    ) async throws -> [Result] {
        guard let query = normalizedTerm(term) else { return [] }
        try Task.checkCancellation()
        let results: [Result]
        do {
            results = try await perform(query, normalizedLimit(limit))
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        return results
    }
}
