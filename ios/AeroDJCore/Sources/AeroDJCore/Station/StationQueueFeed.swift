import Foundation
import Observation

// Station queue feed (-Atlas): the built station pool becomes what plays.
//
//   committed station (pending ?? active)  --prepare-->  resolver -> StationPoolBuilder -> playable items (staged)
//   natural song boundary (after pending changes applied)  --takeForBoundary-->  staged queue replaces the queue
//   Play with nothing queued  --takeForIdleStart-->  staged queue starts
//   the boundary before the queue's last song  --refill-->  [last song] + station songs
//
// Rules:
// - Never mid-song. A station change applies only where the existing boundary rules apply it
//   (`StationConfigurationModel`: next song boundary, or now when idle). The feed only hands a
//   queue out at a natural boundary or an idle Play, never interrupting a song or a DJ break.
// - Fallback keeps the current behavior: no seeds, an empty pool, a failed catalog fetch, no
//   playable songs, or a queue not ready in time all hand out nothing, so the current queue
//   keeps playing (or Play shows its existing "nothing to resume" message). Never an empty queue.
// - A queue the listener started (a search tap) belongs to the station committed at that moment,
//   so it is never replaced unless the station's music settings change after it started.
// - Refill (Echo's conditions): the station refills a queue at the boundary *before* its last
//   song starts, as a new queue `[last song] + station songs` started like a tap, so the DJ session
//   plans the last song's break through the normal `queueStarted` replan; every break then names
//   only songs that are really queued (the DJ's list is the player's list). Any failure hands out
//   nothing and today's path runs unchanged: the last song plays and the station stops after it.
// - Library seeds play only themselves: `StationPoolBuilder.build(_:configuration:)` validates the
//   configuration (reach clamped to `.only`) and the resolver never expands a library seed.
// - Logs are `StationQueueEvent`s: enums, bools and counts only. No seed, song, artist or ID.
// - Song ratings (-Nova) are an input, not part of the key: a new `StationRatingBias.revision`
//   rebuilds the staged queue in `prepare`, `prefetch` and the refill, but the boundary hand-off and
//   `playingKey` compare the key only, so a rating is never a station change (and never re-greets).

/// What a station queue is built from. Two configurations with the same key build the same queue.
/// Names do not count (a renamed pick plays the same songs). Never logged.
public struct StationQueueKey: Hashable, Sendable {
    struct SeedID: Hashable, Sendable {
        let kind: StationSeedKind
        let source: StationSeedSource
        let catalogID: String
    }

    let seeds: [SeedID]
    public let reach: StationReach
    /// `discovery` in thousandths, so float noise never reads as a change.
    let discoveryMillis: Int

    /// `nil` when the configuration has no seeds: it is not a station the engine can build.
    public init?(_ configuration: StationConfiguration) {
        let config = configuration.validated()
        guard !config.seeds.isEmpty else { return nil }
        seeds = config.seeds.map { SeedID(kind: $0.kind, source: $0.source, catalogID: $0.catalogID) }
        reach = config.reach
        discoveryMillis = Int((config.discovery * 1000).rounded())
    }

    /// Stable across launches and platforms (FNV-1a, not `Hasher`): the same station on the same
    /// day plays the same order; another day reshuffles within each tier and familiarity bucket.
    public func shuffleSeed(day: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
            hash ^= 0x1F
            hash &*= 0x0000_0100_0000_01B3
        }
        for seed in seeds { mix(seed.kind.rawValue); mix(seed.source.rawValue); mix(seed.catalogID) }
        mix(reach.rawValue)
        mix(String(discoveryMillis))
        mix(String(day))
        return hash
    }

    /// The seed part only (what #362 compares), FNV-1a: an unsaved station's ratings scope, and the
    /// guard that keeps a ratings bias on the seeds it was made for. Stable across launches.
    public var seedsFingerprint: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
            hash ^= 0x1F
            hash &*= 0x0000_0100_0000_01B3
        }
        for seed in seeds { mix(seed.kind.rawValue); mix(seed.source.rawValue); mix(seed.catalogID) }
        return hash
    }
}

/// Why no station queue was staged. Safe for logs.
public enum StationQueueSkip: String, Equatable, Sendable, CaseIterable {
    /// The station has no seeds (tags only): the engine has nothing to build from.
    case noSeeds
    /// Every lookup came back empty or failed (offline, catalog error).
    case emptyPool
    /// Songs were picked but none could be made playable.
    case unplayable
    /// A newer station replaced this build before it finished.
    case superseded
}

/// Why the current queue keeps playing at a boundary or an idle Play. Safe for logs.
public enum StationQueueKeepReason: String, Equatable, Sendable, CaseIterable {
    /// The station has no seeds.
    case noStation
    /// The playing queue already belongs to this station.
    case sameStation
    /// The station changed but its queue is not built (yet, or the build failed).
    case notReady
    /// Playback is held (user pause during the break, interruption): the boundary's own rules run.
    case playbackHeld
}

public enum StationQueueTrigger: String, Equatable, Sendable, CaseIterable {
    case songBoundary, idleStart
    /// The boundary before the queue's last song: the station continues after it.
    case refill
}

/// Diagnostics. Enums and counts only.
public enum StationQueueEvent: Equatable, Sendable {
    case built(songs: Int, poolSongs: Int, failedLookups: Int, libraryLimited: Int)
    case notBuilt(StationQueueSkip, failedLookups: Int)
    case handedOff(StationQueueTrigger, songs: Int)
    case keptCurrentQueue(StationQueueTrigger, StationQueueKeepReason)
    /// #204: the hand-off's start failed; the queue is staged again and the old queue's station kept.
    case handOffFailed(StationQueueTrigger)

    /// One log line, no content.
    public var diagnostics: String {
        switch self {
        case let .built(songs, pool, failed, limited):
            "stationQueue built songs=\(songs) pool=\(pool) failed=\(failed) libraryLimited=\(limited)"
        case let .notBuilt(skip, failed):
            "stationQueue notBuilt reason=\(skip.rawValue) failed=\(failed)"
        case let .handedOff(trigger, songs):
            "stationQueue handedOff trigger=\(trigger.rawValue) songs=\(songs)"
        case let .keptCurrentQueue(trigger, reason):
            "stationQueue keptCurrent trigger=\(trigger.rawValue) reason=\(reason.rawValue)"
        case let .handOffFailed(trigger):
            "stationQueue handOffFailed trigger=\(trigger.rawValue)"
        }
    }
}

/// #204 (-Atlas): how a handed-out station queue's start ended. The app maps its start: success,
/// or a held start that loaded the queue and waits for the hold, is `.started`; a newer tap, skip or
/// resume that replaced it is `.superseded`; any other throw is `.failed`.
public enum StationHandOffResult: String, Equatable, Sendable, CaseIterable {
    case started
    case failed
    case superseded
}

/// #204 (-Atlas): at a natural boundary, after the station's start returned. A failed start
/// (nothing newer since) loads the old queue's next song, exactly what the boundary would have
/// loaded without a station, so music does not strand. The station start itself bumps the queue
/// generation once (`MusicKitService.play`); any further bump is a newer tap or skip, which owns
/// the player, so nothing old is resurrected.
public enum StationHandOffFallback {
    public static func loadsOldQueueNext(result: StationHandOffResult, generationBefore: Int,
                                         generationNow: Int, next: Int, oldQueueCount: Int) -> Bool {
        guard result == .failed else { return false }
        guard generationNow == generationBefore + 1 else { return false }
        return next >= 0 && next < oldQueueCount
    }
}

public enum StationQueuePrepareOutcome: Equatable, Sendable {
    case ready(songs: Int)
    /// This station's queue was already staged or is being built.
    case unchanged
    case skipped(StationQueueSkip)
}

/// Builds the station's queue ahead of the boundary and hands it to the player when the station
/// changed. Generic over the playable item so Linux tests use plain values; the app uses `Track`.
@MainActor
public final class StationQueueFeed<Item: Sendable> {
    public typealias Materialize = @Sendable ([StationCandidate]) async -> [Item]

    private let resolver: any StationSeedResolver
    private let materialize: Materialize
    private let options: StationPoolBuilder.Options
    private let day: @MainActor () -> Int
    private let recentlyPlayed: @MainActor () -> Set<String>
    private let ratings: @MainActor () -> StationRatingBias
    private let songID: @MainActor (Item) -> String?
    private let log: @MainActor (StationQueueEvent) -> Void
    private let refillLead: Int

    private var staged: (key: StationQueueKey, revision: StationRatingRevision, items: [Item])?
    private var building: (key: StationQueueKey, revision: StationRatingRevision)?
    /// Song ID -> catalog artist ID from the last build, for love's discovery steering (the app's
    /// `Track` has no artist ID). Never logged.
    private var lastBuildArtistIDs: [String: String] = [:]
    private var generation = 0
    /// The station the playing queue belongs to. `nil` before the first queue start, and for a
    /// queue started on a station with no seeds (see `queueStartReported`).
    public private(set) var playingKey: StationQueueKey?
    /// True once any queue start was reported. A reported start on a station with no seeds
    /// leaves `playingKey` nil but is still a known, older queue (P0 build 25: the first
    /// created station never replaced the tapped songs). Before any report, nil means unknown.
    public private(set) var queueStartReported = false
    private var observedKey: StationQueueKey?
    private var observing = false
    /// #204: the last hand-off, until its start reports. A failed start puts it back.
    private var pendingHandOff: PendingHandOff?
    /// The trigger of the hand-off just returned and not yet finished (#332, -Fry): lets the player
    /// tell a station switch at a boundary (`.songBoundary`) from a same-station `.refill`.
    public var pendingHandOffTrigger: StationQueueTrigger? { pendingHandOff?.trigger }

    private struct PendingHandOff {
        let trigger: StationQueueTrigger
        let key: StationQueueKey
        let revision: StationRatingRevision
        let items: [Item]
        let previousKey: StationQueueKey?
        let previousReported: Bool
    }

    /// - Parameters:
    ///   - materialize: candidates -> playable items, in order; drops what it cannot play.
    ///   - options: `limit` and `artistGap` for one queue; `shuffleSeed` and `excludedSongIDs` are set per build.
    ///   - day: a day number for the shuffle seed (the app passes days since the reference date).
    ///   - recentlyPlayed: song IDs to leave out (the current queue's played songs).
    ///   - ratings: the committed station's song ratings (`StationRatingBook.bias`). Applied only to a
    ///     build with the seeds it was made for; its `revision` changing rebuilds, never a station change.
    ///   - songID: an item's catalog or library song ID, for screening a hand-off against the current
    ///     never and tired exclusions. `nil` reads a `String` item, or an `Identifiable` item's `String` ID
    ///     (the app's `Track`).
    ///   - refillLead: start building the refill when this many songs or fewer are left to load.
    public init(resolver: any StationSeedResolver,
                materialize: @escaping Materialize,
                options: StationPoolBuilder.Options = .init(),
                day: @escaping @MainActor () -> Int = { Int(Date().timeIntervalSinceReferenceDate / 86_400) },
                recentlyPlayed: @escaping @MainActor () -> Set<String> = { [] },
                ratings: @escaping @MainActor () -> StationRatingBias = { .none },
                songID: (@MainActor (Item) -> String?)? = nil,
                refillLead: Int = 3,
                log: @escaping @MainActor (StationQueueEvent) -> Void = { _ in }) {
        self.refillLead = max(1, refillLead)
        self.resolver = resolver
        self.materialize = materialize
        self.options = options
        self.day = day
        self.recentlyPlayed = recentlyPlayed
        self.ratings = ratings
        self.songID = songID ?? { StationQueueSongID.of($0) }
        self.log = log
    }

    /// Songs staged for the next hand-off (count only), `nil` when nothing is staged.
    public var stagedCount: Int? { staged?.items.count }
    public var stagedKey: StationQueueKey? { staged?.key }
    /// The station whose queue is being built, `nil` when no build is running.
    public var buildingKey: StationQueueKey? { building?.key }
    /// The ratings revision the staged queue was built with.
    public var stagedRatingRevision: StationRatingRevision? { staged?.revision }

    /// The catalog artist ID of `songID` in the last build, if the catalog gave one. The app stores
    /// it with a love rating so love can steer discovery; matching itself is by artist name.
    public func artistID(forSong songID: String) -> String? { lastBuildArtistIDs[songID] }

    /// A song was rated: rebuild the committed station's staged queue with the new ratings (in the
    /// background). Never touches playback or `playingKey`; songs already queued keep playing.
    public func ratingsChanged(_ committed: StationConfiguration) { prefetch(committed) }

    /// The bias for a build of `key`: a bias made for other seeds keeps its revision but does nothing.
    private func currentRatings(for key: StationQueueKey) -> StationRatingBias {
        let bias = ratings()
        return bias.seedsFingerprint == key.seedsFingerprint ? bias : bias.neutralized
    }

    /// Fry/Orion ruling (PR A follow-up): a hand-off is screened against the station's current never
    /// and held-tired songs as it is handed over, so a queue built before a rating (the refill while
    /// its rebuild is still running) never plays a just-excluded song. Order is kept.
    private func screened(_ items: [Item], for key: StationQueueKey) -> [Item] {
        let excluded = currentRatings(for: key).excludedSongIDs
        guard !excluded.isEmpty else { return items }
        return items.filter { item in songID(item).map { !excluded.contains($0) } ?? true }
    }

    /// Indices after `playingIndex` in the playing `queue` whose songs the active station's current
    /// ratings exclude (never, or tired and still held). The feed never edits the playing queue; the
    /// player uses this when a song is rated to drop those songs and the prepared breaks that name
    /// them through its existing skip path (`onSongSkipped`: `songSkipped(index:)`, `songCut(afterTrack:)`).
    public func excludedUpcoming(in queue: [Item], after playingIndex: Int, active: StationConfiguration) -> [Int] {
        guard let key = StationQueueKey(active) else { return [] }
        let excluded = currentRatings(for: key).excludedSongIDs
        guard !excluded.isEmpty else { return [] }
        return queue.indices.filter { $0 > playingIndex && songID(queue[$0]).map(excluded.contains) == true }
    }

    private func isCurrent(_ key: StationQueueKey, _ revision: StationRatingRevision,
                           against target: StationQueueKey, _ current: StationRatingRevision) -> Bool {
        key == target && revision == current
    }

    // MARK: Building

    /// Builds and stages the queue for `configuration`. A newer call wins; an older result is
    /// dropped (`.superseded`). Never touches playback.
    @discardableResult
    public func prepare(_ configuration: StationConfiguration) async -> StationQueuePrepareOutcome {
        guard let key = StationQueueKey(configuration) else {
            generation += 1
            building = nil
            staged = nil
            log(.notBuilt(.noSeeds, failedLookups: 0))
            return .skipped(.noSeeds)
        }
        let bias = currentRatings(for: key)
        if let s = staged, isCurrent(s.key, s.revision, against: key, bias.revision) { return .unchanged }
        if let b = building, isCurrent(b.key, b.revision, against: key, bias.revision) { return .unchanged }
        generation += 1
        let mine = generation
        building = (key, bias.revision)
        let config = configuration.validated()
        let pool = await resolver.resolve(seeds: config.seeds, reach: config.reach, affinity: bias.affinityArtists)
        guard mine == generation else { return superseded() }
        var opts = options
        opts.shuffleSeed = key.shuffleSeed(day: day())
        opts.excludedSongIDs = options.excludedSongIDs.union(recentlyPlayed())
        opts.ratings = bias
        let picks = StationPoolBuilder.build(pool, configuration: config, options: opts)
        guard !picks.isEmpty else { return finish(mine, .emptyPool, failed: pool.failedLookups) }
        let items = await materialize(picks)
        guard mine == generation else { return superseded() }
        guard !items.isEmpty else { return finish(mine, .unplayable, failed: pool.failedLookups) }
        building = nil
        staged = (key, bias.revision, items)
        lastBuildArtistIDs = Dictionary(picks.compactMap { c in c.artistID.map { (c.id, $0) } },
                                        uniquingKeysWith: { first, _ in first })
        log(.built(songs: items.count, poolSongs: pool.count, failedLookups: pool.failedLookups,
                   libraryLimited: pool.libraryReachLimited))
        return .ready(songs: items.count)
    }

    private func superseded() -> StationQueuePrepareOutcome {
        log(.notBuilt(.superseded, failedLookups: 0))
        return .skipped(.superseded)
    }

    private func finish(_ mine: Int, _ skip: StationQueueSkip, failed: Int) -> StationQueuePrepareOutcome {
        if mine == generation { building = nil }
        log(.notBuilt(skip, failedLookups: failed))
        return .skipped(skip)
    }

    // MARK: Playback hooks

    /// A queue started (any queue: a search tap or a hand-off). It belongs to `committed`, the
    /// station committed at that moment (`StationConfigurationModel.committedDisplayed`), so a
    /// station change saved before the tap does not replace the tapped songs at the next boundary.
    /// `songCount` is the new queue's length: a short queue starts building its refill now.
    public func queueStarted(for committed: StationConfiguration, songCount: Int? = nil) {
        // A newer queue (a tap) owns playback: an earlier hand-off's late failure restores nothing.
        pendingHandOff = nil
        playingKey = StationQueueKey(committed)
        queueStartReported = true
        if let songCount, songCount <= refillLead { prefetch(committed) }
    }

    /// The one call at a natural boundary, after the break, before the next song loads. `queue` is
    /// the playing queue and `finishedIndex` the song that just ended. Returns the queue to start
    /// instead of loading `queue[finishedIndex + 1]`, or `nil` to load it exactly as today:
    /// 1. the station's music settings changed since this queue began: the new station's queue;
    /// 2. the next song is the queue's last: a refill, `[that song] + station songs`, started now so
    ///    the DJ plans the last song's break with a song that is really queued next.
    /// Anything not ready, empty, held, or no next song at all: `nil` (today's stop path).
    /// `sameSong` matches two items as the same song; station songs already in `queue` are dropped.
    public func queueForNextSong(after finishedIndex: Int, in queue: [Item], active: StationConfiguration,
                                 playbackMayStart: Bool, sameSong: (Item, Item) -> Bool) -> [Item]? {
        if let switched = takeForBoundary(active: active, playbackMayStart: playbackMayStart) { return switched }
        let next = finishedIndex + 1
        guard queue.indices.contains(next) else { return nil }
        if queue.count - next <= refillLead { prefetch(active) }
        guard next == queue.count - 1 else { return nil }
        return takeForRefill(lastSong: queue[next], queue: queue, active: active,
                             playbackMayStart: playbackMayStart, sameSong: sameSong)
    }

    /// `[lastSong] + staged station songs not already in `queue``, or `nil` (today's behavior).
    func takeForRefill(lastSong: Item, queue: [Item], active: StationConfiguration,
                       playbackMayStart: Bool, sameSong: (Item, Item) -> Bool) -> [Item]? {
        guard let key = StationQueueKey(active) else { return keep(.refill, .noStation) }
        guard playbackMayStart else { return keep(.refill, .playbackHeld) }
        guard let ready = staged, ready.key == key else {
            prefetch(active)
            return keep(.refill, .notReady)
        }
        // Ratings changed since this queue was built: rebuild for the next refill. The stale queue is
        // still handed out now, so a rating never strands the station (today's stop path), but
        // screened: a song excluded since (never, held tired) is dropped as it is handed over.
        if ready.revision != currentRatings(for: key).revision { prefetch(active) }
        let allowed = screened(ready.items, for: key)
        let fresh = allowed.filter { item in !queue.contains { sameSong($0, item) } }
        guard !fresh.isEmpty else {
            staged = nil
            prefetch(active)
            return keep(.refill, .notReady)
        }
        // Fry nit 1 (PR B): a failed start restores the screened list, never the unscreened build.
        pendingHandOff = PendingHandOff(trigger: .refill, key: key, revision: ready.revision, items: allowed,
                                        previousKey: playingKey, previousReported: queueStartReported)
        staged = nil
        playingKey = key
        // Echo (PR B): the last song is NOT screened. It is the song the DJ's break at this boundary
        // has already introduced ("up next") and the player loads next; dropping it here would make
        // the break name one song and a different one play. A never on it is handled by the player
        // instead: rating the playing song skips it, and rating it while queued drops it and the
        // breaks that name it through the skip path (`excludedUpcoming`, PR B).
        let refill = [lastSong] + fresh
        log(.handedOff(.refill, songs: refill.count))
        // A short refill starts its own refill now (its start skips `queueStarted`'s check).
        if refill.count <= refillLead { prefetch(active) }
        return refill
    }

    /// Builds `configuration`'s queue in the background unless it is staged or building.
    private func prefetch(_ configuration: StationConfiguration) {
        guard let key = StationQueueKey(configuration) else { return }
        let revision = currentRatings(for: key).revision
        if let s = staged, isCurrent(s.key, s.revision, against: key, revision) { return }
        if let b = building, isCurrent(b.key, b.revision, against: key, revision) { return }
        Task { await self.prepare(configuration) }
    }

    /// Call at a natural boundary, after `DJBreakSession.naturalBoundary` applied pending changes
    /// and the break is over, before the next song loads. Returns the station's queue when the
    /// active station's music settings changed since the playing queue started and its queue is
    /// staged; `nil` keeps the current queue (today's behavior). `playbackMayStart` false (a held
    /// start) always keeps the current queue: the existing deferral rules run unchanged.
    public func takeForBoundary(active: StationConfiguration, playbackMayStart: Bool) -> [Item]? {
        take(.songBoundary, active: active, playbackMayStart: playbackMayStart, requireChange: true)
    }

    /// Play was pressed with nothing queued. Returns the active station's staged queue, or `nil`
    /// (Play then shows its existing message).
    public func takeForIdleStart(active: StationConfiguration) -> [Item]? {
        take(.idleStart, active: active, playbackMayStart: true, requireChange: false)
    }

    private func take(_ trigger: StationQueueTrigger, active: StationConfiguration,
                      playbackMayStart: Bool, requireChange: Bool) -> [Item]? {
        guard let key = StationQueueKey(active) else { return keep(trigger, .noStation) }
        if requireChange, key == playingKey { return keep(trigger, .sameStation) }
        if requireChange, playingKey == nil, !queueStartReported {
            // No queue start was reported: the playing queue is not known to be older than this
            // station, so it is never replaced on a guess.
            playingKey = key
            return keep(trigger, .sameStation)
        }
        guard playbackMayStart else { return keep(trigger, .playbackHeld) }
        guard let ready = staged, ready.key == key, !ready.items.isEmpty else {
            // Not built in time, or the build failed (offline): try again for a later boundary.
            prefetch(active)
            return keep(trigger, .notReady)
        }
        // Built before the current ratings: rebuild, and hand over only what they still allow.
        if ready.revision != currentRatings(for: key).revision { prefetch(active) }
        let items = screened(ready.items, for: key)
        guard !items.isEmpty else {
            staged = nil
            prefetch(active)
            return keep(trigger, .notReady)
        }
        // Fry nit 1 (PR B): a failed start restores the screened list, never the unscreened build.
        pendingHandOff = PendingHandOff(trigger: trigger, key: key, revision: ready.revision, items: items,
                                        previousKey: playingKey, previousReported: queueStartReported)
        staged = nil
        playingKey = key
        log(.handedOff(trigger, songs: items.count))
        return items
    }

    /// #204 (-Atlas): the start of the queue just handed out reported. `.failed` puts the hand-off
    /// back: the playing queue keeps its own station (`playingKey`) and the station's songs are
    /// staged again (unless a newer build is already staged), so the next boundary or Play retries.
    /// `.started` and `.superseded` keep the hand-off. A queue start reported since (a tap) wins.
    public func handOffFinished(_ result: StationHandOffResult) {
        guard let handOff = pendingHandOff else { return }
        pendingHandOff = nil
        guard result == .failed else { return }
        playingKey = handOff.previousKey
        queueStartReported = handOff.previousReported
        if staged == nil { staged = (handOff.key, handOff.revision, handOff.items) }
        log(.handOffFailed(handOff.trigger))
    }

    private func keep(_ trigger: StationQueueTrigger, _ reason: StationQueueKeepReason) -> [Item]? {
        log(.keptCurrentQueue(trigger, reason))
        return nil
    }

    // MARK: Following the station

    /// Prepares the committed station now and again whenever its seeds, reach or discovery change
    /// (a save, a recipe, a created station). Only the committed configuration is read, never an
    /// unsaved Tune draft. Call once.
    public func follow(_ station: StationConfigurationModel) {
        guard !observing else { return }
        observing = true
        track(station)
    }

    private func track(_ station: StationConfigurationModel) {
        let committed = withObservationTracking {
            station.committedDisplayed
        } onChange: { [weak self, weak station] in
            Task { @MainActor in
                guard let self, let station else { return }
                self.track(station)
            }
        }
        let key = StationQueueKey(committed)
        guard key != observedKey else { return }
        observedKey = key
        Task { await self.prepare(committed) }
    }
}

/// The default song ID for a feed item: a `String` item is its own ID; an `Identifiable` item with a
/// `String` ID (the app's `Track`, whose `id` is the song ID) uses it. Anything else is never screened.
enum StationQueueSongID {
    static func of<Item>(_ item: Item) -> String? {
        if let id = item as? String { return id }
        if let identifiable = item as? any Identifiable { return identifiable.id as? String }
        return nil
    }
}
