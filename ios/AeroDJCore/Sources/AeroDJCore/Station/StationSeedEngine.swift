import Foundation

// Station seed engine (-Atlas): seeds plus reach -> a candidate pool -> an ordered song list.
//
//   StationSeedCatalog       (protocol, app: MusicCatalogSeedSource) fetches songs per seed and tier.
//   CatalogStationSeedResolver  asks the catalog for exactly the tiers `reach` allows.
//   StationPoolBuilder       pure and deterministic: dedupe, tier mix, discovery mix, artist spacing, limit.
//   StarterStationSuggester  suggested station drafts from the library, recents and recommendations.
//
// Nothing here plays, queues, saves or logs. Wiring the built list into the live queue is a
// MusicKitService hook (Claude); see the PR. Privacy: `.library` seeds are only ever asked of
// the catalog for their own songs (`coreSongs`), which the app reads on-device. The resolver
// never expands a library seed through related or broad catalog lookups.

/// How close a candidate is to the seeds. Lower tiers are closer.
public enum StationCandidateTier: Int, Codable, Sendable, CaseIterable, Comparable {
    /// The seed itself: artist top songs, playlist tracks, genre chart, the song.
    case seed
    /// Similar artists' songs.
    case related
    /// The wider genre and chart neighbourhood.
    case broad

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public extension StationReach {
    /// Tiers this reach may draw from, closest first.
    var tiers: [StationCandidateTier] {
        switch self {
        case .only: [.seed]
        case .related: [.seed, .related]
        case .broad: [.seed, .related, .broad]
        }
    }

    /// Share of the station each tier aims for. A tier that runs out leaves its share to the others.
    var tierWeights: [StationCandidateTier: Double] {
        switch self {
        case .only: [.seed: 1]
        case .related: [.seed: 0.6, .related: 0.4]
        case .broad: [.seed: 0.4, .related: 0.3, .broad: 0.3]
        }
    }
}

/// One playable song the engine may pick. Reuses `TrackInfo`; adds what mixing needs.
public struct StationCandidate: Equatable, Hashable, Sendable {
    public let track: TrackInfo
    /// Catalog artist ID when known. Spacing falls back to the lowercased artist name.
    public let artistID: String?
    public var tier: StationCandidateTier
    /// Familiar (a hit, or near the top of its list) vs new. `discovery` mixes the two.
    public var isFamiliar: Bool

    public init(track: TrackInfo, artistID: String? = nil, tier: StationCandidateTier = .seed, isFamiliar: Bool = true) {
        self.track = track
        self.artistID = artistID
        self.tier = tier
        self.isFamiliar = isFamiliar
    }

    public var id: String { track.id }

    /// Spacing key: the same artist must not play back to back.
    var artistKey: String {
        if let artistID, !artistID.isEmpty { return "id:" + artistID }
        return "name:" + track.artistName.lowercased()
    }

    /// Catches the same recording listed under two IDs (single vs album version).
    var titleKey: String { track.title.lowercased() + "\u{1F}" + track.artistName.lowercased() }

    public static func == (a: Self, b: Self) -> Bool {
        a.track.id == b.track.id && a.track.title == b.track.title && a.track.artistName == b.track.artistName
            && a.track.artworkURL == b.track.artworkURL && a.artistID == b.artistID && a.tier == b.tier
            && a.isFamiliar == b.isFamiliar
    }

    public func hash(into h: inout Hasher) { h.combine(track.id); h.combine(tier) }
}

/// The app's catalog adapter. Each call returns songs in the catalog's own order (top first).
/// Throwing skips that seed and tier only; the rest of the station still builds.
public protocol StationSeedCatalog: Sendable {
    /// Reach `.only`: artist top songs, playlist tracks, genre chart songs, the song itself.
    /// For `.library` seeds this must read the on-device library only.
    func coreSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate]
    /// Added at `.related`: similar artists' top songs. Called for `.catalog` seeds only.
    func relatedSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate]
    /// Added at `.broad`: genre charts and the wider neighbourhood. Called for `.catalog` seeds only.
    func broadSongs(for seed: StationSeed, limit: Int) async throws -> [StationCandidate]
}

/// Seeds plus reach -> candidates. The resolver decides which tiers to fetch.
public protocol StationSeedResolver: Sendable {
    func resolve(seeds: [StationSeed], reach: StationReach) async -> StationCandidatePool
}

/// Candidates per tier, each list interleaved across seeds so several artists mix evenly.
public struct StationCandidatePool: Equatable, Sendable {
    public var byTier: [StationCandidateTier: [StationCandidate]]
    /// Seed-tier fetches that threw (counts only; never which seed).
    public var failedLookups: Int
    /// Library seeds asked for related or broad reach: kept to their own songs (privacy rule).
    public var libraryReachLimited: Int

    public init(byTier: [StationCandidateTier: [StationCandidate]] = [:], failedLookups: Int = 0, libraryReachLimited: Int = 0) {
        self.byTier = byTier
        self.failedLookups = failedLookups
        self.libraryReachLimited = libraryReachLimited
    }

    public func songs(_ tier: StationCandidateTier) -> [StationCandidate] { byTier[tier] ?? [] }
    public var isEmpty: Bool { byTier.values.allSatisfy(\.isEmpty) }
    public var count: Int { byTier.values.reduce(0) { $0 + $1.count } }

    /// Counts only, safe for logs.
    public var diagnostics: String {
        let tiers = StationCandidateTier.allCases.map { "\($0)=\(songs($0).count)" }.joined(separator: " ")
        return "\(tiers) failed=\(failedLookups) libraryLimited=\(libraryReachLimited)"
    }
}

/// Default resolver over a `StationSeedCatalog`. Sequential awaits keep results in seed order.
public struct CatalogStationSeedResolver: StationSeedResolver {
    public struct Limits: Equatable, Sendable {
        public var corePerSeed: Int
        public var relatedPerSeed: Int
        public var broadPerSeed: Int
        /// The first N songs of each fetched list count as familiar; the rest as new.
        public var familiarHead: Int

        public init(corePerSeed: Int = 25, relatedPerSeed: Int = 40, broadPerSeed: Int = 40, familiarHead: Int = 5) {
            self.corePerSeed = corePerSeed
            self.relatedPerSeed = relatedPerSeed
            self.broadPerSeed = broadPerSeed
            self.familiarHead = familiarHead
        }
    }

    let catalog: any StationSeedCatalog
    let limits: Limits

    public init(catalog: any StationSeedCatalog, limits: Limits = .init()) {
        self.catalog = catalog
        self.limits = limits
    }

    public func resolve(seeds: [StationSeed], reach: StationReach) async -> StationCandidatePool {
        var pool = StationCandidatePool()
        let valid = StationConfiguration.normalizedSeeds(seeds)
        for tier in reach.tiers {
            var perSeed: [[StationCandidate]] = []
            for seed in valid {
                if seed.source == .library, tier != .seed {
                    if tier == reach.tiers.last { pool.libraryReachLimited += 1 }
                    continue
                }
                do {
                    let songs = try await fetch(tier, seed)
                    perSeed.append(songs.enumerated().map { index, song in
                        var s = song
                        s.tier = tier
                        s.isFamiliar = index < limits.familiarHead
                        return s
                    })
                } catch {
                    pool.failedLookups += 1
                }
            }
            pool.byTier[tier] = Self.roundRobin(perSeed)
        }
        return pool
    }

    private func fetch(_ tier: StationCandidateTier, _ seed: StationSeed) async throws -> [StationCandidate] {
        switch tier {
        case .seed: try await catalog.coreSongs(for: seed, limit: limits.corePerSeed)
        case .related: try await catalog.relatedSongs(for: seed, limit: limits.relatedPerSeed)
        case .broad: try await catalog.broadSongs(for: seed, limit: limits.broadPerSeed)
        }
    }

    /// a1 b1 c1 a2 b2 ... so a few-artists station opens with each of them.
    static func roundRobin(_ lists: [[StationCandidate]]) -> [StationCandidate] {
        var result: [StationCandidate] = []
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest {
            for list in lists where i < list.count { result.append(list[i]) }
        }
        return result
    }
}

/// Pure, deterministic: the same pool and options always give the same list.
public enum StationPoolBuilder {
    public struct Options: Equatable, Sendable {
        /// Songs to return (one queue's worth).
        public var limit: Int
        /// At least this many other songs between two songs by the same artist, when the
        /// pool allows it. A one-artist `.only` station relaxes it rather than run dry.
        public var artistGap: Int
        /// Songs to leave out (for example the ones that just played).
        public var excludedSongIDs: Set<String>
        /// `nil` keeps catalog order. A value shuffles within each tier and familiarity
        /// bucket with a fixed generator, so a seed (for example the day) varies the
        /// station and tests stay deterministic.
        public var shuffleSeed: UInt64?

        public init(limit: Int = 50, artistGap: Int = 2, excludedSongIDs: Set<String> = [], shuffleSeed: UInt64? = nil) {
            self.limit = limit
            self.artistGap = artistGap
            self.excludedSongIDs = excludedSongIDs
            self.shuffleSeed = shuffleSeed
        }
    }

    /// `discovery` is `StationConfiguration.discovery`: 0 = familiar only (new songs are used
    /// only once familiar ones run out), 1 = mostly new.
    public static func build(_ pool: StationCandidatePool, reach: StationReach, discovery: Double,
                             options: Options = .init()) -> [StationCandidate] {
        guard options.limit > 0 else { return [] }
        let newShare = StationConfiguration.clampUnit(discovery, fallback: StationConfiguration.default.discovery)
        var rng = options.shuffleSeed.map(SplitMix64.init(seed:))

        // 1. Dedupe across tiers, closest tier first, by ID and by title plus artist.
        var seenIDs = options.excludedSongIDs
        var seenTitles = Set<String>()
        var tierLists: [[StationCandidate]] = []
        var weights: [Double] = []
        for tier in reach.tiers {
            var familiar: [StationCandidate] = []
            var fresh: [StationCandidate] = []
            for c in pool.songs(tier) {
                guard seenIDs.insert(c.id).inserted, seenTitles.insert(c.titleKey).inserted else { continue }
                var c = c
                c.tier = tier
                if c.isFamiliar { familiar.append(c) } else { fresh.append(c) }
            }
            if rng != nil {
                familiar = shuffled(familiar, &rng!)
                fresh = shuffled(fresh, &rng!)
            }
            // 2. Discovery: familiar vs new within the tier.
            tierLists.append(weave([familiar, fresh], weights: [1 - newShare, newShare]))
            weights.append(reach.tierWeights[tier] ?? 0)
        }
        // 3. Reach: tiers by their share.
        let merged = weave(tierLists, weights: weights)
        // 4. Artist spacing, then the limit.
        return spaced(merged, gap: options.artistGap, limit: options.limit)
    }

    /// Deterministic weighted interleave. Each slot goes to the list furthest behind its
    /// share; ties go to the earlier list. Zero-weight lists play only after the others run out.
    static func weave(_ lists: [[StationCandidate]], weights: [Double]) -> [StationCandidate] {
        var index = Array(repeating: 0, count: lists.count)
        var taken = Array(repeating: 0, count: lists.count)
        var result: [StationCandidate] = []
        let total = lists.reduce(0) { $0 + $1.count }
        result.reserveCapacity(total)
        while result.count < total {
            let open = lists.indices.filter { index[$0] < lists[$0].count }
            let weighted = open.filter { weights[$0] > 0 }
            let candidates = weighted.isEmpty ? open : weighted
            let sum = candidates.reduce(0.0) { $0 + weights[$1] }
            let slot = Double(candidates.reduce(0) { $0 + taken[$1] } + 1)
            var best = candidates[0]
            var bestDeficit = -Double.infinity
            for i in candidates {
                let share = sum > 0 ? weights[i] / sum : 1 / Double(candidates.count)
                let deficit = share * slot - Double(taken[i])
                if deficit > bestDeficit + 1e-9 { best = i; bestDeficit = deficit }
            }
            result.append(lists[best][index[best]])
            index[best] += 1
            taken[best] += 1
        }
        return result
    }

    /// Greedy: take the earliest song whose artist is not among the last `gap` picks; if
    /// every remaining song breaks the gap, take the earliest one (never run dry).
    static func spaced(_ list: [StationCandidate], gap: Int, limit: Int) -> [StationCandidate] {
        var remaining = list
        var result: [StationCandidate] = []
        while result.count < limit, !remaining.isEmpty {
            let recent = Set(result.suffix(max(gap, 0)).map(\.artistKey))
            let pick = remaining.firstIndex { !recent.contains($0.artistKey) } ?? 0
            result.append(remaining.remove(at: pick))
        }
        return result
    }

    static func shuffled(_ list: [StationCandidate], _ rng: inout SplitMix64) -> [StationCandidate] {
        var copy = list
        guard copy.count > 1 else { return copy }
        for i in stride(from: copy.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            copy.swapAt(i, j)
        }
        return copy
    }
}

/// Small fixed generator so a shuffle seed gives the same order on every platform.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Starter stations

/// Where suggested stations come from. The app reads these on-device (library) or from
/// Apple Music (recently played, recommendations). Throwing skips that source only.
public protocol StarterStationSource: Sendable {
    /// Most-played library artists, most first.
    func libraryTopArtists(limit: Int) async throws -> [StationSeed]
    /// Recently played artists, playlists or songs, most recent first.
    func recentlyPlayed(limit: Int) async throws -> [StationSeed]
    /// Apple Music recommendations (playlists, artists, genres).
    func recommendations(limit: Int) async throws -> [StationSeed]
}

/// One suggested station. Shown only: never saved or played by the suggester. Saving goes
/// through `StationRecipeLibrary.save(name:configuration:)` with `draft.name` and `draft.configuration`.
public struct StarterStationSuggestion: Equatable, Sendable, Identifiable {
    public enum Origin: String, Equatable, Sendable, CaseIterable {
        case libraryMix, libraryArtist, recentlyPlayed, recommended
    }

    public let origin: Origin
    public let draft: StationRecipe
    public var id: UUID { draft.id }
}

public struct StarterStationSuggester: Sendable {
    let source: any StarterStationSource
    let maxSuggestions: Int
    let makeID: @Sendable () -> UUID
    let now: @Sendable () -> Date

    public init(source: any StarterStationSource, maxSuggestions: Int = 6,
                makeID: @escaping @Sendable () -> UUID = { UUID() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.maxSuggestions = maxSuggestions
        self.makeID = makeID
        self.now = now
    }

    /// Suggestions in order: a mix of the top library artists, then each top artist, then
    /// recently played, then recommendations. Each draft copies `base` tuning (personality,
    /// talk, briefing), replaces seeds and reach, and never carries connections.
    /// Names already used by `existingNames` (case-insensitive) and seeds already suggested are skipped.
    public func suggestions(base: StationConfiguration = .default, existingNames: [String] = []) async -> [StarterStationSuggestion] {
        let top = ((try? await source.libraryTopArtists(limit: 8)) ?? []).compactMap { $0.normalized() }
        let recent = ((try? await source.recentlyPlayed(limit: 8)) ?? []).compactMap { $0.normalized() }
        let recommended = ((try? await source.recommendations(limit: 8)) ?? []).compactMap { $0.normalized() }

        var names = Set(existingNames.map { $0.lowercased() })
        var seenSingles = Set<StationSeed.Key>()
        var result: [StarterStationSuggestion] = []

        func add(_ origin: StarterStationSuggestion.Origin, _ name: String, _ seeds: [StationSeed], reach: StationReach) {
            guard result.count < maxSuggestions, !seeds.isEmpty else { return }
            guard case .success(let clean) = StationRecipe.normalizedName(Self.fitName(name)),
                  names.insert(clean.lowercased()).inserted else { return }
            var config = base
            config.seeds = seeds
            config.reach = reach
            config.requestedIntegrations = []
            let draft = StationRecipe(id: makeID(), name: clean, configuration: config, createdAt: now())
            result.append(StarterStationSuggestion(origin: origin, draft: draft))
        }

        if top.count >= 2 {
            add(.libraryMix, "Your Mix", Array(top.prefix(3)), reach: .related)
        }
        for seed in top + recent + recommended where seenSingles.insert(seed.key).inserted {
            let origin: StarterStationSuggestion.Origin =
                top.contains(seed) ? .libraryArtist : recent.contains(seed) ? .recentlyPlayed : .recommended
            add(origin, Self.stationName(for: seed), [seed], reach: origin == .recommended ? .broad : .related)
        }
        return result
    }

    static func stationName(for seed: StationSeed) -> String {
        switch seed.kind {
        case .artist, .genre: seed.name + " Radio"
        case .playlist: seed.name
        case .song: seed.name + " Radio"
        }
    }

    /// Fits `StationRecipe.maxNameLength`, keeping a " Radio" suffix when there is one.
    static func fitName(_ name: String) -> String {
        let max = StationRecipe.maxNameLength
        guard name.count > max else { return name }
        let suffix = " Radio"
        if name.hasSuffix(suffix) {
            let head = String(name.dropLast(suffix.count).prefix(max - suffix.count))
            return head.trimmingCharacters(in: .whitespaces) + suffix
        }
        return String(name.prefix(max))
    }
}
