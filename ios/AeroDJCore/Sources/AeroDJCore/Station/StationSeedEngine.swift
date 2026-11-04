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
    /// Love steers discovery (-Nova): `affinity` artists add related songs for this build only.
    /// The default ignores them.
    func resolve(seeds: [StationSeed], reach: StationReach, affinity: [StationAffinityArtist]) async -> StationCandidatePool
}

public extension StationSeedResolver {
    func resolve(seeds: [StationSeed], reach: StationReach, affinity: [StationAffinityArtist]) async -> StationCandidatePool {
        await resolve(seeds: seeds, reach: reach)
    }
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
        // The same rule as the reach picker and `validated()`: any library seed means `.only`.
        let effective = reach.effective(for: valid)
        if effective != reach { pool.libraryReachLimited = valid.filter { $0.source == .library }.count }
        for tier in effective.tiers {
            var perSeed: [[StationCandidate]] = []
            for seed in valid {
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

    /// Love steers discovery without touching seeds: up to `maxAffinityArtists` loved catalog artists
    /// that are not seeds each get one `relatedSongs` lookup (at most `affinitySongsPerArtist`) through
    /// a transient catalog seed that is never saved. Their songs join the related tier only when the
    /// effective reach is `.related` or `.broad` (so never for a library seed), at most
    /// `affinityTierShare` of that tier, one after every few regular songs. A failed lookup adds nothing.
    public func resolve(seeds: [StationSeed], reach: StationReach,
                        affinity: [StationAffinityArtist]) async -> StationCandidatePool {
        var pool = await resolve(seeds: seeds, reach: reach)
        let valid = StationConfiguration.normalizedSeeds(seeds)
        guard reach.effective(for: valid).tiers.contains(.related), !affinity.isEmpty else { return pool }
        let seedArtistIDs = Set(valid.filter { $0.kind == .artist }.map(\.catalogID))
        var seenIDs = Set<String>()
        let artists = affinity.filter { !$0.artistID.isEmpty && !seedArtistIDs.contains($0.artistID) && seenIDs.insert($0.artistID).inserted }
            .prefix(StationRatingTuning.maxAffinityArtists)
        var perArtist: [[StationCandidate]] = []
        for artist in artists {
            guard let songs = try? await catalog.relatedSongs(for: artist.transientSeed,
                                                             limit: StationRatingTuning.affinitySongsPerArtist) else { continue }
            perArtist.append(songs.prefix(StationRatingTuning.affinitySongsPerArtist).enumerated().map { index, song in
                var s = song
                s.tier = .related
                s.isFamiliar = index < limits.familiarHead
                return s
            })
        }
        let related = pool.songs(.related)
        let have = Set(related.map(\.id))
        let extra = Self.roundRobin(perArtist).filter { !have.contains($0.id) }
        // extra <= share × (related + extra)  <=>  extra <= related × share / (1 - share)
        let share = StationRatingTuning.affinityTierShare
        let cap = Int((Double(related.count) * share / (1 - share) + 1e-9).rounded(.down))
        let added = Array(extra.prefix(cap))
        guard !added.isEmpty else { return pool }
        let every = max(1, Int((1 / share).rounded()) - 1)
        var merged: [StationCandidate] = []
        var queue = added[...]
        for (i, song) in related.enumerated() {
            merged.append(song)
            if (i + 1) % every == 0, let next = queue.popFirst() { merged.append(next) }
        }
        merged.append(contentsOf: queue)
        pool.byTier[.related] = merged
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
        /// Song ratings for this station (-Nova): exclusions, the re-rank and the artist drop.
        /// `.none` builds exactly as before.
        public var ratings: StationRatingBias
        /// #418 (-Fry): where `StationQueueFeed` takes each build's `shuffleSeed` from. The builder
        /// itself never reads it. Default `.systemRandom`: every build (a switch, a refill, a rating
        /// rebuild) gets a fresh order.
        public var seedSource: StationShuffleSeedSource

        public init(limit: Int = 50, artistGap: Int = 2, excludedSongIDs: Set<String> = [], shuffleSeed: UInt64? = nil,
                    ratings: StationRatingBias = .none, seedSource: StationShuffleSeedSource = .systemRandom) {
            self.limit = limit
            self.artistGap = artistGap
            self.excludedSongIDs = excludedSongIDs
            self.shuffleSeed = shuffleSeed
            self.ratings = ratings
            self.seedSource = seedSource
        }
    }

    /// #418 (-Fry): each slot's deficit gets a nudge in `[0, weaveJitter)` slots when the build has a
    /// shuffle seed, so the familiar/new and tier pattern is not a fixed cadence. Bounded: a list
    /// is never more than `1 + weaveJitter` songs off its share while every list has songs left, and
    /// never runs more than `ceil(share / (1 - share)) + 3` in a row (`StationWeaveJitterTests`).
    static let weaveJitter: Double = 1.0

    /// `discovery` is `StationConfiguration.discovery`: 0 = familiar only (new songs are used
    /// only once familiar ones run out), 1 = mostly new.
    public static func build(_ pool: StationCandidatePool, reach: StationReach, discovery: Double,
                             options: Options = .init()) -> [StationCandidate] {
        guard options.limit > 0 else { return [] }
        let newShare = StationConfiguration.clampUnit(discovery, fallback: StationConfiguration.default.discovery)
        var rng = options.shuffleSeed.map(SplitMix64.init(seed:))
        // #418: the weave's jitter has its own stream, so a seed's in-bucket shuffle is unchanged.
        var jitter = options.shuffleSeed.map { SplitMix64(seed: $0 ^ 0x5DEE_CE66_D1CE_4E5B) }

        let ratings = options.ratings
        // 1. Dedupe across tiers, closest tier first, by ID and by title plus artist. Never-rated
        //    songs and tired songs in their hold are left out like recently played ones.
        var seenIDs = options.excludedSongIDs.union(ratings.excludedSongIDs)
        var seenTitles = Set<String>()
        var tierLists: [[StationCandidate]] = []
        var weights: [Double] = []
        for tier in reach.tiers {
            var familiar: [StationCandidate] = []
            var fresh: [StationCandidate] = []
            for c in pool.songs(tier) {
                // Three never-rated songs drop a non-seed artist from related and broad (the seed
                // tier is the station itself; a seed artist is only down-weighted).
                if tier != .seed, ratings.droppedArtists.contains(StationRatingEntry.artistKey(c.track.artistName)) { continue }
                guard seenIDs.insert(c.id).inserted, seenTitles.insert(c.titleKey).inserted else { continue }
                var c = c
                c.tier = tier
                if c.isFamiliar { familiar.append(c) } else { fresh.append(c) }
            }
            if rng != nil {
                familiar = shuffled(familiar, &rng!)
                fresh = shuffled(fresh, &rng!)
            }
            // Ratings: after the day shuffle, before the weave. `artistGap` spacing still runs last.
            if !ratings.isNeutral {
                familiar = reranked(familiar, ratings)
                fresh = reranked(fresh, ratings)
            }
            // 2. Discovery: familiar vs new within the tier.
            tierLists.append(weave([familiar, fresh], weights: [1 - newShare, newShare], jitter: &jitter))
            weights.append(reach.tierWeights[tier] ?? 0)
        }
        // 3. Reach: tiers by their share.
        let merged = weave(tierLists, weights: weights, jitter: &jitter)
        // 4. Artist spacing, then the limit.
        return spaced(merged, gap: options.artistGap, limit: options.limit)
    }

    /// Each song moves up (positive score) or down by `round(score × maxMoveShare × length)` places:
    /// a sort on its target position. On a tie the song that moved up goes first and the one that
    /// moved down last, so a move lands where it aims; unrated songs keep their relative order.
    static func reranked(_ list: [StationCandidate], _ ratings: StationRatingBias) -> [StationCandidate] {
        guard list.count > 1 else { return list }
        let length = Double(list.count)
        let targets = list.enumerated().map { index, c -> (target: Int, move: Int, index: Int) in
            let move = Int((ratings.score(c) * StationRatingTuning.maxMoveShare * length).rounded())
            return (index - move, move, index)
        }
        return targets.sorted {
            if $0.target != $1.target { return $0.target < $1.target }
            if $0.move != $1.move { return $0.move > $1.move }
            return $0.index < $1.index
        }.map { list[$0.index] }
    }

    /// Deterministic weighted interleave. Each slot goes to the list furthest behind its
    /// share; ties go to the earlier list. Zero-weight lists play only after the others run out.
    static func weave(_ lists: [[StationCandidate]], weights: [Double]) -> [StationCandidate] {
        var none: SplitMix64?
        return weave(lists, weights: weights, jitter: &none)
    }

    /// The same interleave; with a generator (#418) each open list's deficit gets a nudge in
    /// `[0, weaveJitter)` before the pick, so the cadence varies but stays near the shares.
    static func weave(_ lists: [[StationCandidate]], weights: [Double], jitter: inout SplitMix64?) -> [StationCandidate] {
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
                var deficit = share * slot - Double(taken[i])
                if jitter != nil { deficit += unitInterval(jitter!.next()) * weaveJitter }
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

    /// `[0, 1)` from the top 53 bits.
    static func unitInterval(_ bits: UInt64) -> Double { Double(bits >> 11) / Double(UInt64(1) << 53) }

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

/// #418 (-Fry): where a station build's shuffle seed comes from. Privacy (Sentinel): the default
/// seed is drawn from `SystemRandomNumberGenerator` only, never from user, device, account or
/// listening data, and it is never logged or stored (`StationQueueEvent` has no seed).
public enum StationShuffleSeedSource: Equatable, Sendable {
    /// A fresh seed per build from the system generator (the app's default).
    case systemRandom
    /// The pre-#418 seed: the station key and the day, so a rebuild that day repeats the order.
    /// Tests that predict a feed's order use it.
    case perDay
    /// One fixed seed for every build (tests).
    case fixed(UInt64)

    /// The seed for one build. `perDay` is evaluated only for `.perDay`.
    public func seed(perDay: @autoclosure () -> UInt64) -> UInt64 {
        var system = SystemRandomNumberGenerator()
        return seed(perDay: perDay(), using: &system)
    }

    func seed<G: RandomNumberGenerator>(perDay: @autoclosure () -> UInt64, using generator: inout G) -> UInt64 {
        switch self {
        case .systemRandom: generator.next()
        case .perDay: perDay()
        case let .fixed(value): value
        }
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
            // Library seeds play only themselves (Fry, #157): clamp through the shared rule.
            config.reach = reach.effective(for: seeds)
            config.requestedIntegrations = []
            config = config.validated()
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
