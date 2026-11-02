import Foundation

// Song ratings per station (-Nova, ratings scope v1, PR A: core only).
//
//   StationRatingBook  (all stations, Codable)  --bias(for:configuration:today:)-->  StationRatingBias
//   StationRatingBias  --StationPoolBuilder.Options.ratings-->  exclusions, re-rank, artist drop
//                      --affinityArtists-->  CatalogStationSeedResolver (love steers discovery)
//
// Rules:
// - One current rating per song per station. Rating a song again at the same level clears it.
// - A station is its `StationRecipe.id` when there is one, else an FNV hash of its seed IDs (the
//   seed part #362 compares). A tags-only station has no seeds and can't be rated in v1.
// - Ratings never touch `StationQueueKey` (seeds, reach, discovery), so a rating is never a station
//   change and never re-opens the show (`greetAgain()`). The feed rebuilds on a new `revision`.
// - Artists match by lowercased name (`Track` and `TrackInfo` carry no artist ID).
// - Privacy (Sentinel): ratings are personal context. They stay on the device, never reach the
//   DJ script or any voice (DJ/ and Voice/ never reference these types), and never go into logs.
//   Love's discovery steering sends Apple Music only catalog artist IDs, as discovery does today;
//   library and unknown-origin songs never trigger a lookup. Loved artists are never saved as seeds.
// - File I/O (`FileStationRatingStore`, file protection, backup exclusion, clearing) is PR B. This
//   file defines the store protocol and an in-memory store only.

/// The four levels. UI names and symbols live in the app (PR B).
public enum SongRating: String, Codable, Sendable, CaseIterable, Hashable {
    /// Plays too much: left out for a while, then eased back in.
    case tired
    /// Never on this station again.
    case never
    /// A small boost.
    case like
    /// A strong boost, and steers discovery toward the artist.
    case love
}

/// The approved numbers (Orion, Nov 2). One place so tests and tuning agree.
public enum StationRatingTuning {
    // Tired
    /// Days a tired song is left out of builds.
    public static let tiredHoldDays = 14
    /// Day the tired entry ends (the ease-back runs from `tiredHoldDays` to here).
    public static let tiredEndDay = 28
    /// Score when a tired song comes back, easing linearly to 0 by `tiredEndDay`.
    public static let tiredReturnScore = -0.30

    // Never
    /// Artist penalty for each never-rated song after the first.
    public static let neverArtistStep = -0.25
    /// Lowest artist penalty from never ratings.
    public static let neverArtistFloor = -0.75
    /// A seed artist is only down-weighted, never below this.
    public static let neverSeedArtistFloor = -0.50
    /// Never-rated songs at which a non-seed artist leaves the related and broad tiers.
    public static let neverArtistDropCount = 3

    // Like
    public static let likeSongBoost = 0.15
    public static let likeArtistStep = 0.05
    public static let likeArtistCap = 0.25
    public static let likeHalfLifeDays = 60.0

    // Love
    public static let loveSongBoost = 0.50
    public static let loveArtistStep = 0.25
    /// Shared with like: the artist's whole positive score.
    public static let positiveArtistCap = 0.75
    public static let loveHalfLifeDays = 120.0

    // Re-rank
    /// Combined score range.
    public static let scoreRange: ClosedRange<Double> = -1...1
    /// A song moves at most this share of its list (`round(score × share × length)` places).
    public static let maxMoveShare = 0.30

    // Love steers discovery
    public static let maxAffinityArtists = 2
    public static let affinitySongsPerArtist = 10
    /// Affinity songs are at most this share of the related tier.
    public static let affinityTierShare = 0.20

    // Limits
    public static let maxEntriesPerStation = 500

    // Day numbers (Sentinel B1): a saved `ratedDay` is days since the reference date (2001-01-01).
    /// Days a rating may plausibly carry: 1901 through about 3001. Anything outside (a corrupt or
    /// hand-edited file: `Int.min`, `Int.max`) is read as `implausibleDay`, i.e. long ago, so it has
    /// already done its work: tired is expired, like and love have decayed to nothing, and never stays
    /// permanent (its effect never depended on the day, so a corrupt day never brings a song back).
    public static let plausibleDays: ClosedRange<Int> = -36_525...365_250
    /// Where an implausible day lands: the start of `plausibleDays`.
    public static var implausibleDay: Int { plausibleDays.lowerBound }

    /// `day` if plausible, else `implausibleDay`.
    public static func sanitizedDay(_ day: Int) -> Int { plausibleDays.contains(day) ? day : implausibleDay }

    /// Whole days from `ratedDay` to `today`, never trapping: 0 for the same day or a future day;
    /// `Int.max` when the difference overflows (an absurd `today`), which reads as long expired.
    static func ageDays(today: Int, ratedDay: Int) -> Int {
        let (age, overflow) = today.subtractingReportingOverflow(ratedDay)
        if overflow { return today > ratedDay ? Int.max : 0 }
        return max(0, age)
    }

    /// `0.5^(ageDays / halfLife)`; 1 for a future or same-day rating, never NaN.
    static func decay(ageDays: Int, halfLife: Double) -> Double {
        guard ageDays > 0, halfLife.isFinite, halfLife > 0 else { return 1 }
        let d = pow(0.5, Double(ageDays) / halfLife)
        return d.isFinite ? d : 0
    }
}

/// Which station a rating belongs to. Never logged.
public enum StationRatingScope: Hashable, Codable, Sendable {
    /// A saved station (`StationRecipe.id`).
    case recipe(UUID)
    /// An unsaved seeded station: `StationQueueKey.seedsFingerprint`.
    case seeds(UInt64)

    /// `nil` for a tags-only station (no seeds): it can't be rated in v1, even when saved.
    public init?(recipeID: UUID?, configuration: StationConfiguration) {
        guard let key = StationQueueKey(configuration) else { return nil }
        if let recipeID { self = .recipe(recipeID) } else { self = .seeds(key.seedsFingerprint) }
    }

    /// Dictionary key in the on-device file.
    public var storageKey: String {
        switch self {
        case .recipe(let id): "recipe:" + id.uuidString.lowercased()
        case .seeds(let hash): "seeds:" + String(hash, radix: 16)
        }
    }
}

/// One song's current rating on one station.
public struct StationRatingEntry: Codable, Equatable, Sendable {
    public let songID: String
    /// Lowercased, trimmed. Matching is by name.
    public let artistName: String
    /// Catalog artist ID when known (from the feed's last build); used only for love's discovery steering.
    public let artistID: String?
    public let rating: SongRating
    /// Day number the rating was set (the feed's day: days since the reference date). Always within
    /// `StationRatingTuning.plausibleDays`: `init` (and so decoding) maps anything else to `implausibleDay`.
    public let ratedDay: Int
    /// Where the song entered the queue. Only `.catalog` songs steer discovery.
    public let origin: TrackOrigin

    public init(songID: String, artistName: String, artistID: String? = nil, rating: SongRating,
                ratedDay: Int, origin: TrackOrigin) {
        self.songID = songID
        self.artistName = StationRatingEntry.artistKey(artistName)
        let id = artistID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artistID = (id?.isEmpty ?? true) ? nil : id
        self.rating = rating
        self.ratedDay = StationRatingTuning.sanitizedDay(ratedDay)
        self.origin = origin
    }

    /// The name artists are matched by.
    public static func artistKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Days since the rating (0 on the day, never negative).
    func age(today: Int) -> Int { StationRatingTuning.ageDays(today: today, ratedDay: ratedDay) }

    private enum CodingKeys: String, CodingKey { case songID, artistName, artistID, rating, ratedDay, origin }

    /// Through `init` so a hand-edited or older file is normalized the same way.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(songID: try c.decode(String.self, forKey: .songID),
                  artistName: try c.decode(String.self, forKey: .artistName),
                  artistID: try c.decodeIfPresent(String.self, forKey: .artistID),
                  rating: try c.decode(SongRating.self, forKey: .rating),
                  // A missing, fractional or out-of-Int day reads as implausible (long ago) rather than
                  // failing the whole file: a never with a bad day must still load and stay a never.
                  ratedDay: (try? c.decode(Int.self, forKey: .ratedDay)) ?? StationRatingTuning.implausibleDay,
                  // Fail closed: an unknown origin is personal and never steers discovery.
                  origin: (try? c.decodeIfPresent(TrackOrigin.self, forKey: .origin)) ?? .unknown)
    }

    /// A tired entry past `tiredEndDay`: it has no effect and goes first when the station is full.
    func isExpired(today: Int) -> Bool { rating == .tired && age(today: today) >= StationRatingTuning.tiredEndDay }
}

/// One station's ratings: at most one per song, at most `maxEntriesPerStation`.
public struct StationRatings: Codable, Equatable, Sendable {
    public private(set) var entries: [String: StationRatingEntry]

    public init(entries: [StationRatingEntry] = []) {
        self.entries = [:]
        for entry in entries { self.entries[entry.songID] = entry }
    }

    private enum CodingKeys: String, CodingKey { case entries }

    /// Saved as a list sorted by song ID (a stable file); loaded through `init`, one entry per song.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries.values.sorted { $0.songID < $1.songID }, forKey: .entries)
    }

    /// Sentinel B2: a loaded station is trimmed to `maxEntriesPerStation` in the same eviction order,
    /// except that every never is kept (dropping one would bring back a song the listener banned), so a
    /// file with more than the limit of nevers loads them all and nothing else. `today` is the decoder's
    /// `StationRatingBook.todayKey` when given (PR B's file store passes it), else the station's newest
    /// rating day, so a load never reads the clock.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try c.decode([StationRatingEntry].self, forKey: .entries))
        let today = (decoder.userInfo[StationRatingBook.todayKey] as? Int)
            ?? entries.values.map(\.ratedDay).max() ?? 0
        enforceLimit(today: today, evictingNevers: false)
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    public func rating(for songID: String) -> SongRating? { entries[songID]?.rating }

    /// Sets `entry`. The same level again clears the song (the menu's toggle). Returns the song's
    /// rating afterwards. Over the limit, evicts in `evictionOrder`.
    @discardableResult
    public mutating func rate(_ entry: StationRatingEntry, today: Int) -> SongRating? {
        if entries[entry.songID]?.rating == entry.rating {
            entries[entry.songID] = nil
            return nil
        }
        entries[entry.songID] = entry
        enforceLimit(today: today, keeping: entry.songID)
        return entries[entry.songID]?.rating
    }

    public mutating func clear(songID: String) { entries[songID] = nil }

    /// Drops expired tired entries (they no longer do anything).
    public mutating func prune(today: Int) {
        entries = entries.filter { !$0.value.isExpired(today: today) }
    }

    /// Who goes first when the station is full: expired tired, then the oldest like, then the
    /// oldest love, then active tired (oldest first), then never last. Ties: the lower song ID.
    static func evictionRank(_ e: StationRatingEntry, today: Int) -> Int {
        if e.isExpired(today: today) { return 0 }
        switch e.rating {
        case .like: return 1
        case .love: return 2
        case .tired: return 3
        case .never: return 4
        }
    }

    /// Evicts down to `maxEntriesPerStation`. `evictingNevers` false (a load) never evicts a never, so
    /// the station may stay over the limit when nevers alone exceed it.
    mutating func enforceLimit(today: Int, keeping newest: String? = nil, evictingNevers: Bool = true) {
        let limit = StationRatingTuning.maxEntriesPerStation
        guard entries.count > limit else { return }
        let order = entries.values
            .filter { $0.songID != newest && (evictingNevers || $0.rating != .never) }
            .sorted {
                let (ra, rb) = (Self.evictionRank($0, today: today), Self.evictionRank($1, today: today))
                if ra != rb { return ra < rb }
                if $0.ratedDay != $1.ratedDay { return $0.ratedDay < $1.ratedDay }
                return $0.songID < $1.songID
            }
        for victim in order.prefix(entries.count - limit) { entries[victim.songID] = nil }
    }
}

/// A loved catalog artist that steers discovery for one build. Transient: never saved as a seed.
public struct StationAffinityArtist: Equatable, Hashable, Sendable {
    public let artistID: String
    public let name: String

    public init(artistID: String, name: String) {
        self.artistID = artistID
        self.name = name
    }

    /// The seed passed to `relatedSongs` for this build only.
    var transientSeed: StationSeed { StationSeed(kind: .artist, catalogID: artistID, name: name, source: .catalog) }
}

/// Identifies one state of a station's ratings on one day. The feed compares it to decide a rebuild.
public struct StationRatingRevision: Hashable, Sendable {
    /// `StationRatingBook.changes` when the bias was made.
    public let changes: Int
    /// The day the bias was made for: decay and the tired ease-back move daily.
    public let day: Int
    public let scope: StationRatingScope?

    public init(changes: Int, day: Int, scope: StationRatingScope?) {
        self.changes = changes
        self.day = day
        self.scope = scope
    }

    public static let none = StationRatingRevision(changes: 0, day: 0, scope: nil)
}

/// What the ratings do to one station's next build. Pure values; never logged.
public struct StationRatingBias: Equatable, Sendable {
    public var revision: StationRatingRevision
    /// The seeds the bias was made for (`StationQueueKey.seedsFingerprint`). The feed applies it only
    /// to a build with the same seeds, so a bias never lands on another station. `nil`: no ratings.
    public var seedsFingerprint: UInt64?
    /// Never-rated songs, and tired songs still in their hold.
    public var excludedSongIDs: Set<String>
    /// Each rated song's own score (tired ease-back, like, love), before the artist's.
    public var songScores: [String: Double]
    /// Artist scores by lowercased name (likes, loves, nevers).
    public var artistScores: [String: Double]
    /// Non-seed artists (lowercased) with `neverArtistDropCount` never ratings: out of related and broad.
    public var droppedArtists: Set<String>
    /// At most `maxAffinityArtists`, best first.
    public var affinityArtists: [StationAffinityArtist]

    public init(revision: StationRatingRevision = .none, seedsFingerprint: UInt64? = nil,
                excludedSongIDs: Set<String> = [], songScores: [String: Double] = [:],
                artistScores: [String: Double] = [:], droppedArtists: Set<String> = [],
                affinityArtists: [StationAffinityArtist] = []) {
        self.revision = revision
        self.seedsFingerprint = seedsFingerprint
        self.excludedSongIDs = excludedSongIDs
        self.songScores = songScores
        self.artistScores = artistScores
        self.droppedArtists = droppedArtists
        self.affinityArtists = affinityArtists
    }

    public static let none = StationRatingBias()

    /// True when the bias changes nothing in a build.
    public var isNeutral: Bool {
        excludedSongIDs.isEmpty && songScores.isEmpty && artistScores.isEmpty && droppedArtists.isEmpty
            && affinityArtists.isEmpty
    }

    /// The same revision with no effect: what the feed uses when the bias belongs to other seeds.
    var neutralized: StationRatingBias { StationRatingBias(revision: revision) }

    /// Song plus artist, clamped to `scoreRange`.
    public func score(songID: String, artistName: String) -> Double {
        let raw = (songScores[songID] ?? 0) + (artistScores[StationRatingEntry.artistKey(artistName)] ?? 0)
        guard raw.isFinite else { return 0 }   // never NaN into the re-rank's Int conversion
        return min(max(raw, StationRatingTuning.scoreRange.lowerBound), StationRatingTuning.scoreRange.upperBound)
    }

    func score(_ c: StationCandidate) -> Double { score(songID: c.id, artistName: c.track.artistName) }

    /// Ratings are personal context (Sentinel): if anything derived from them were ever spoken, it
    /// must carry this attribution (listener-entered, so `.userShared`), which
    /// `VoiceRenderer.mayLeaveDevice` keeps on-device. Nothing in DJ/ or Voice/ reads ratings
    /// today; a test pins both.
    public static func narrationAttribution(itemID: UUID) -> SpokenAttribution {
        .personalContext(itemID: itemID, source: .userShared, provenance: "station ratings")
    }

    /// Builds the bias for one station from its entries on `today`.
    /// - Parameter seeds: the station's seeds; artist seeds (by catalog ID or lowercased name) are
    ///   never dropped (floor `neverSeedArtistFloor`) and never used as affinity artists.
    public static func make(_ ratings: StationRatings, seeds: [StationSeed], today: Int,
                            revision: StationRatingRevision = .none, seedsFingerprint: UInt64?) -> StationRatingBias {
        typealias T = StationRatingTuning
        var bias = StationRatingBias(revision: revision, seedsFingerprint: seedsFingerprint)
        let artistSeeds = seeds.filter { $0.kind == .artist }
        let seedIDs = Set(artistSeeds.map(\.catalogID))
        let seedNames = Set(artistSeeds.map { StationRatingEntry.artistKey($0.name) })
        func isSeedArtist(_ name: String, _ id: String?) -> Bool {
            seedNames.contains(name) || (id.map(seedIDs.contains) ?? false)
        }

        var nevers: [String: Int] = [:]
        var likeSum: [String: Double] = [:]
        var loveSum: [String: Double] = [:]
        var seedArtist: [String: Bool] = [:]
        // Affinity candidates: catalog-origin loves with an artist ID, by artist ID.
        var loved: [String: (name: String, weight: Double, lastDay: Int)] = [:]

        for e in ratings.entries.values {
            let age = e.age(today: today)
            if isSeedArtist(e.artistName, e.artistID) { seedArtist[e.artistName] = true }
            switch e.rating {
            case .tired:
                if age < T.tiredHoldDays {
                    bias.excludedSongIDs.insert(e.songID)
                } else if age < T.tiredEndDay {
                    let span = Double(T.tiredEndDay - T.tiredHoldDays)
                    bias.songScores[e.songID] = T.tiredReturnScore * (1 - Double(age - T.tiredHoldDays) / span)
                }
            case .never:
                bias.excludedSongIDs.insert(e.songID)
                nevers[e.artistName, default: 0] += 1
            case .like:
                let d = T.decay(ageDays: age, halfLife: T.likeHalfLifeDays)
                bias.songScores[e.songID] = T.likeSongBoost * d
                likeSum[e.artistName, default: 0] += T.likeArtistStep * d
            case .love:
                let d = T.decay(ageDays: age, halfLife: T.loveHalfLifeDays)
                bias.songScores[e.songID] = T.loveSongBoost * d
                loveSum[e.artistName, default: 0] += T.loveArtistStep * d
                if e.origin == .catalog, let id = e.artistID, !isSeedArtist(e.artistName, id) {
                    var current = loved[id] ?? (name: e.artistName, weight: 0, lastDay: e.ratedDay)
                    current.weight += d
                    current.lastDay = max(current.lastDay, e.ratedDay)
                    loved[id] = current
                }
            }
        }

        for artist in Set(nevers.keys).union(likeSum.keys).union(loveSum.keys) {
            let positive = min(T.positiveArtistCap, min(T.likeArtistCap, likeSum[artist] ?? 0) + (loveSum[artist] ?? 0))
            let n = nevers[artist] ?? 0
            let isSeed = seedArtist[artist] ?? false
            var negative = n <= 1 ? 0 : max(T.neverArtistFloor, T.neverArtistStep * Double(n - 1))
            if isSeed { negative = max(T.neverSeedArtistFloor, negative) }
            if n >= T.neverArtistDropCount, !isSeed { bias.droppedArtists.insert(artist) }
            let score = positive + negative
            if score != 0 { bias.artistScores[artist] = score }
        }

        bias.affinityArtists = loved
            .filter { !bias.droppedArtists.contains($0.value.name) && (bias.artistScores[$0.value.name] ?? 0) > 0 }
            .sorted {
                if $0.value.weight != $1.value.weight { return $0.value.weight > $1.value.weight }
                if $0.value.lastDay != $1.value.lastDay { return $0.value.lastDay > $1.value.lastDay }
                return $0.key < $1.key
            }
            .prefix(T.maxAffinityArtists)
            .map { StationAffinityArtist(artistID: $0.key, name: $0.value.name) }
        return bias
    }
}

/// Every station's ratings: the on-device file's contents. `changes` counts edits in this process
/// (not saved); the feed rebuilds when it moves.
public struct StationRatingBook: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public private(set) var version: Int
    public private(set) var stations: [String: StationRatings]
    public private(set) var changes: Int = 0

    private enum CodingKeys: String, CodingKey { case version, stations }

    /// Decoder `userInfo` key for today's day number, used to trim an over-full station on load.
    public static let todayKey = CodingUserInfoKey(rawValue: "aerodj.stationRatings.today")!

    public init(stations: [String: StationRatings] = [:]) {
        version = Self.formatVersion
        self.stations = stations
    }

    public func ratings(for scope: StationRatingScope) -> StationRatings {
        stations[scope.storageKey] ?? StationRatings()
    }

    public func rating(for songID: String, in scope: StationRatingScope) -> SongRating? {
        stations[scope.storageKey]?.rating(for: songID)
    }

    /// Rates (or, at the same level, clears) one song. Returns its rating afterwards.
    @discardableResult
    public mutating func rate(_ entry: StationRatingEntry, in scope: StationRatingScope, today: Int) -> SongRating? {
        var station = ratings(for: scope)
        let result = station.rate(entry, today: today)
        stations[scope.storageKey] = station.isEmpty ? nil : station
        changes &+= 1
        return result
    }

    public mutating func clear(songID: String, in scope: StationRatingScope) {
        guard stations[scope.storageKey]?.rating(for: songID) != nil else { return }
        var station = ratings(for: scope)
        station.clear(songID: songID)
        stations[scope.storageKey] = station.isEmpty ? nil : station
        changes &+= 1
    }

    /// The per-station "Clear ratings", and deleting a station.
    public mutating func clearStation(_ scope: StationRatingScope) {
        stations[scope.storageKey] = nil
        changes &+= 1
    }

    /// Settings "Clear all ratings", a data reset, or a consent withdrawal (wired in PR B).
    public mutating func clearAll() {
        stations = [:]
        changes &+= 1
    }

    /// Drops expired tired entries everywhere.
    public mutating func prune(today: Int) {
        var next: [String: StationRatings] = [:]
        for (key, var station) in stations {
            station.prune(today: today)
            if !station.isEmpty { next[key] = station }
        }
        if next != stations { stations = next; changes &+= 1 }
    }

    /// The bias for the station `configuration` is (saved as `recipeID`, if any) on `today`.
    /// A tags-only station gets `.none`.
    public func bias(recipeID: UUID?, configuration: StationConfiguration, today: Int) -> StationRatingBias {
        guard let key = StationQueueKey(configuration),
              let scope = StationRatingScope(recipeID: recipeID, configuration: configuration) else { return .none }
        let revision = StationRatingRevision(changes: changes, day: today, scope: scope)
        guard let station = stations[scope.storageKey], !station.isEmpty else {
            return StationRatingBias(revision: revision, seedsFingerprint: key.seedsFingerprint)
        }
        return StationRatingBias.make(station, seeds: configuration.validated().seeds, today: today,
                                      revision: revision, seedsFingerprint: key.seedsFingerprint)
    }

    public static func == (a: Self, b: Self) -> Bool { a.version == b.version && a.stations == b.stations }
}

/// Where the book is kept. The app's file store (`Ratings/ratings.json`, file protection,
/// backup exclusion) is PR B.
public protocol StationRatingStore: Sendable {
    /// An empty book when nothing is saved yet.
    func load() async throws -> StationRatingBook
    func save(_ book: StationRatingBook) async throws
    /// Removes everything saved (Settings "Clear all ratings", data reset).
    func deleteAll() async throws
}

/// In memory, for tests and previews.
public actor InMemoryStationRatingStore: StationRatingStore {
    public private(set) var book: StationRatingBook

    public init(book: StationRatingBook = StationRatingBook()) { self.book = book }

    public func load() async throws -> StationRatingBook { book }
    public func save(_ book: StationRatingBook) async throws { self.book = book }
    public func deleteAll() async throws { book = StationRatingBook() }
}
