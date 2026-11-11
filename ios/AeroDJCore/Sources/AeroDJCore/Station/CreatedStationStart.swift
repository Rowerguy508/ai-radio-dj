import Foundation

// Station start (-Atlas; #213, reworked for #454). Every station row tap (built-in, library or
// created) goes through `CreatedStationStarter.open`, so the start path does not depend on how the
// station is made: the caller only supplies how to apply it.
// - Instant first song (#454): the tap starts as soon as ONE playable song is known (the staged
//   queue, a cached song from this station's last build, or the first seed's first song), never
//   after the whole queue. The rest of the queue is built in the background and APPENDED behind
//   the playing song (`append`), never a queue replace.
// - Switch now (#454): a tap on a different station while something plays switches right away; a
//   tap on the station already playing is a no-op. Tune edits keep the song-boundary rules
//   (`StationConfigurationModel`); only a row tap promotes its own station now (`switchNow`).
// - Station intro (#442, Fry's `DJBreakSession`). Spend gate (Sentinel): `beginStationIntro` is
//   called only after the station's first song really started for that tap (the player holds the
//   station's queue), and only after `introDelay` with no newer tap or queue change, so a burst of
//   taps begins at most the final station's intro. It renders only through the DJ session's
//   preparer, voice quota and reserve gate, and a different station id cancels a render in flight.
//   Echo: the first song never waits on the intro and is never talked over. The intro airs at the
//   first song boundary (`songBoundary`, through the caller's break path), or is dropped and the
//   skip reported (`StationIntroDisposition`). A tap on the station already playing, a failed tap,
//   or a restore asks for no intro. With no `airIntro` sink nothing is ever begun (no unheard spend).
// Restoring the selection at launch never authorizes, applies or plays. The app supplies the
// closures; the decisions live here so they are tested on Linux. Diagnostics are enums and counts.

/// How a station row was opened.
public enum StationOpenTrigger: String, Equatable, Sendable, CaseIterable {
    /// The listener tapped the row.
    case userTap
    /// The saved selection was restored at launch (or after the list changed).
    case restore
}

/// What opening a station did.
public enum CreatedStationOpenOutcome: Equatable, Sendable {
    /// Restore: nothing authorized, applied or started.
    case restoredOnly
    /// The recipe could not be applied (deleted meanwhile, store failure). Nothing started.
    case notApplied
    /// #454: the tapped station's queue is already the one playing. Nothing changed.
    case alreadyPlaying
    /// The station started. `songs` is how many were handed to the player at once (1 on the fast
    /// path: the rest are appended in the background). `waited` is true when it was not staged.
    case started(songs: Int, waited: Bool)
    /// No start happened.
    case notStarted(CreatedStationNoStartReason)
}

public enum CreatedStationNoStartReason: String, Equatable, Sendable, CaseIterable {
    /// The applied station has no seeds.
    case noStation
    /// No playable song was found within the wait bound.
    case notReadyInTime
    /// The build failed (offline, empty pool, nothing playable) and no first song resolved.
    case buildFailed
    /// The listener started something else (a song tap, Play) while the station was starting.
    case playbackBegan
    /// A newer tap (or another station) replaced this one while it waited.
    case superseded
    /// #454: the tapped row has nothing to apply (a built-in id `BuiltInStations` does not
    /// know, or no station queue on this build). The Starting screen says so honestly; nothing is applied or played, and search never opens.
    case notAvailableYet
}

/// The station-start intro as the starter sees it (#442). `DJBreakSession` is the real one; tests
/// use a fake. `beginStationIntro` returns at once and cancels an intro render already in flight
/// for a different station id; `takeStationIntroAtSongStart` never waits on rendering.
@MainActor
public protocol StationIntroHook: AnyObject {
    func beginStationIntro(_ facts: StationIntroFacts)
    func takeStationIntroAtSongStart(id: String) async -> PreparedDJBreak?
}

extension DJBreakSession: StationIntroHook {}

/// What happened to a begun station intro at the first song boundary. Diagnostics only.
public enum StationIntroDisposition: String, Equatable, Sendable, CaseIterable {
    /// Ready audio was handed to the break path at the boundary (never over a song).
    case aired
    /// Not ready at the boundary: skipped (the DJ session reports `.notReadyAtBoundary`).
    case notReady
    /// The queue changed before the boundary (a song tap, another station): dropped.
    case droppedQueueChanged
    /// Ready, but there was nowhere to air it: dropped.
    case droppedNoPlayer
}

/// MainActor box for a value a child task fills in.
@MainActor
private final class Pending<Value> {
    var value: Value?
    var done = false
}

/// One per app session. Tracks the latest tap so only that tap may start playback.
@MainActor
public final class CreatedStationStarter<Item: Sendable> {
    private let feed: StationQueueFeed<Item>
    private let pollInterval: Duration
    private let maxPolls: Int
    private let maxFillPolls: Int
    private let sleep: @MainActor (Duration) async -> Void
    private var tapGeneration = 0
    private var fillTask: Task<Void, Never>?
    /// Fry's intro (#442). Nil: no intro is asked for.
    public weak var intro: (any StationIntroHook)?
    /// Airs a ready intro at the first song boundary through the break path (never over a song).
    /// Nil: no intro is ever begun, so nothing renders that nobody hears.
    public var airIntro: (@MainActor (PreparedDJBreak) -> Void)?
    private let introDelay: Duration
    /// The confirmed start's intro, waiting out `introDelay` before it begins.
    private var introTask: Task<Void, Never>?
    /// A begun intro waiting for the first song boundary: its id and the queue it belongs to.
    private var begunIntro: (id: String, epoch: Int)?
    /// The station the last tap applied (Fry #213 nit 3). Cleared by `cancelPending()`
    /// and by a failed apply, so only a station that is still the listener's choice is skipped.
    public private(set) var currentRecipeID: UUID?

    /// - Parameters:
    ///   - readyTimeout: how long a tap waits for its first song before giving up (retry starts again).
    ///   - pollInterval: how often the wait re-checks the feed.
    ///   - fillTimeout: how long the background fill waits for the full queue after a fast start.
    ///   - introDelay: how long a confirmed start must stay current before its intro begins.
    public init(feed: StationQueueFeed<Item>,
                readyTimeout: Duration = .seconds(10),
                pollInterval: Duration = .milliseconds(100),
                fillTimeout: Duration = .seconds(30),
                introDelay: Duration = .seconds(2),
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.feed = feed
        self.pollInterval = pollInterval
        self.maxPolls = max(1, Int((readyTimeout / pollInterval).rounded(.up)))
        self.maxFillPolls = max(1, Int((fillTimeout / pollInterval).rounded(.up)))
        self.introDelay = introDelay
        self.sleep = sleep
    }

    /// Another tap path took over (Fry #213 nit 2): a tap still waiting must not start, its fill
    /// stops, an intro not yet begun never begins, and the station is no longer current. (An intro
    /// already begun is dropped at the boundary, since the queue changed.)
    public func cancelPending() {
        tapGeneration += 1
        currentRecipeID = nil
        fillTask?.cancel()
        fillTask = nil
        introTask?.cancel()
        introTask = nil
    }

    /// Opens a station (built-in, library or created: the caller's `apply` decides which).
    /// - Parameters:
    ///   - recipeID: the station's identity. When it is already current the recipe is not
    ///     applied again, so unsaved Tune edits stay (Fry #213 nit 3).
    ///   - available: false when the station has nothing to apply (an unknown built-in id).
    ///   - introFacts: what the station intro may say. Nil: no intro for this tap.
    ///   - liveRecipeID: the recipe the live station last had applied from any caller
    ///     (`StudioPresentationModel.lastAppliedRecipeID`). The apply is skipped only when this tap's
    ///     cached id AND the live one both match (Fry #218). The default (nil) always applies.
    ///   - authorize: the music authorization prompt (user taps only).
    ///   - apply: applies the station's recipe; false if it failed.
    ///   - active: the station's active configuration, read after `apply` (and `switchNow`).
    ///   - nothingQueued: true while the player is idle with an empty queue.
    ///   - playingStation: the station whose queue is playing (`StationQueueFeed.playingKey` when the
    ///     playing queue is a station queue), nil when unknown. Also confirms a start before its intro.
    ///   - switchNow: promotes the just-applied station now (a row tap is not a Tune edit). Only
    ///     called while something is queued.
    ///   - queueEpoch: bumps every time the player's queue is replaced. A change while this tap
    ///     waits means the listener started something else.
    ///   - start: plays the items (`StationQueuePlayer.play`), replacing any queue.
    ///   - append: adds `songs` behind `first`, the song the fast start played. False when the queue
    ///     is no longer the one this tap started (nothing is added then).
    @discardableResult
    public func open(_ trigger: StationOpenTrigger,
                     recipeID: UUID? = nil,
                     available: Bool = true,
                     introFacts: StationIntroFacts? = nil,
                     liveRecipeID: @MainActor () -> UUID? = { nil },
                     authorize: @MainActor () async -> Void,
                     apply: @MainActor () async -> Bool,
                     active: @escaping @MainActor () -> StationConfiguration,
                     nothingQueued: @MainActor () -> Bool,
                     playingStation: @escaping @MainActor () -> StationQueueKey? = { nil },
                     switchNow: @MainActor () async -> Void = {},
                     queueEpoch: @escaping @MainActor () -> Int = { 0 },
                     start: @MainActor ([Item]) async -> Void,
                     append: @escaping @MainActor (_ first: Item, _ songs: [Item]) -> Bool = { _, _ in false }) async -> CreatedStationOpenOutcome {
        guard trigger == .userTap else { return .restoredOnly }
        tapGeneration += 1
        let mine = tapGeneration
        // Nothing from an older tap may keep filling, or begin an intro.
        fillTask?.cancel()
        fillTask = nil
        introTask?.cancel()
        introTask = nil
        await authorize()
        guard mine == tapGeneration else { return .notStarted(.superseded) }
        guard available else {
            currentRecipeID = nil
            return .notStarted(.notAvailableYet)
        }
        let alreadyCurrent = recipeID != nil && recipeID == currentRecipeID && liveRecipeID() == recipeID
        if !alreadyCurrent {
            guard await apply() else {
                if mine == tapGeneration { currentRecipeID = nil }
                return .notApplied
            }
            guard mine == tapGeneration else { return .notStarted(.superseded) }
            currentRecipeID = recipeID
        }
        let wasIdle = nothingQueued()
        if !wasIdle {
            // A row tap switches now; the applied change would otherwise wait for the boundary.
            await switchNow()
            guard mine == tapGeneration else { return .notStarted(.superseded) }
        }
        let config = active()
        guard let key = StationQueueKey(config) else { return .notStarted(.noStation) }
        if !wasIdle, !nothingQueued(), playingStation() == key { return .alreadyPlaying }
        let epoch = queueEpoch()
        /// After `start`: the intro may begin once this start is confirmed and stays current.
        func startConfirmed() {
            guard mine == tapGeneration, !nothingQueued(), playingStation() == key else { return }
            scheduleIntro(introFacts, tap: mine, key: key, epoch: queueEpoch(),
                          queueEpoch: queueEpoch, playingStation: playingStation)
        }

        // The full queue builds in the background; the first song resolves on its own, faster.
        var build: Pending<StationQueuePrepareOutcome>?
        func buildIfIdle() {
            guard feed.buildingKey != key, feed.stagedKey != key else { return }
            let box = Pending<StationQueuePrepareOutcome>()
            build = box
            Task { @MainActor [feed] in
                box.value = await feed.prepare(config)
                box.done = true
            }
        }
        buildIfIdle()
        let first = Pending<Item>()
        if feed.stagedKey != key {
            Task { @MainActor [feed] in
                first.value = await feed.firstSong(for: config)
                first.done = true
            }
        }

        var waited = false
        var polls = 0
        while true {
            guard mine == tapGeneration, StationQueueKey(active()) == key else { return .notStarted(.superseded) }
            guard queueEpoch() == epoch, !wasIdle || nothingQueued() else { return .notStarted(.playbackBegan) }
            if feed.stagedKey == key, let items = feed.takeForIdleStart(active: config) {
                await start(items)
                startConfirmed()
                return .started(songs: items.count, waited: waited)
            }
            if first.done, let song = first.value, feed.fastStartBegan(with: song, active: config) {
                await start([song])
                startConfirmed()
                if mine == tapGeneration {
                    scheduleFill(tap: mine, key: key, first: song, active: active,
                                 queueEpoch: queueEpoch, epoch: queueEpoch(), append: append)
                }
                return .started(songs: 1, waited: waited)
            }
            if let box = build, box.done {
                if case .skipped(let skip) = box.value, skip != .superseded, first.done {
                    return .notStarted(.buildFailed)
                }
                if feed.stagedKey != key { build = nil }
            }
            if build == nil { buildIfIdle() }
            guard polls < maxPolls else { return .notStarted(.notReadyInTime) }
            polls += 1
            waited = true
            await sleep(pollInterval)
        }
    }

    /// Begins the confirmed station's intro after `introDelay`, if nothing replaced the start
    /// meanwhile (a newer tap cancels this task first). Never awaited by the start.
    private func scheduleIntro(_ facts: StationIntroFacts?, tap: Int, key: StationQueueKey, epoch: Int,
                               queueEpoch: @escaping @MainActor () -> Int,
                               playingStation: @escaping @MainActor () -> StationQueueKey?) {
        introTask?.cancel()
        introTask = nil
        guard let facts, intro != nil, airIntro != nil else { return }
        let delay = introDelay
        let sleep = self.sleep
        introTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self, self.tapGeneration == tap, queueEpoch() == epoch,
                  playingStation() == key, let intro = self.intro, self.airIntro != nil else { return }
            intro.beginStationIntro(facts)
            self.begunIntro = (facts.id, epoch)
            self.introTask = nil
        }
    }

    /// The first song after a station start ended (a natural boundary). Takes the begun intro
    /// without waiting: ready audio goes to `airIntro` for the break path (never over a song);
    /// otherwise it is skipped or dropped. Nil when no intro was begun. Only the first call counts.
    @discardableResult
    public func songBoundary(queueEpoch: Int) async -> StationIntroDisposition? {
        introTask?.cancel()
        introTask = nil
        guard let begun = begunIntro, let intro else { return nil }
        begunIntro = nil
        let prepared = await intro.takeStationIntroAtSongStart(id: begun.id)
        guard queueEpoch == begun.epoch else { return .droppedQueueChanged }
        guard let prepared else { return .notReady }
        guard let airIntro else { return .droppedNoPlayer }
        airIntro(prepared)
        return .aired
    }

    /// After a fast start: waits (bounded) for the full build, then appends its songs behind the
    /// playing one. Stops when a newer tap, a queue change, or a station change happens.
    private func scheduleFill(tap: Int, key: StationQueueKey, first: Item,
                              active: @escaping @MainActor () -> StationConfiguration,
                              queueEpoch: @escaping @MainActor () -> Int, epoch: Int,
                              append: @escaping @MainActor (_ first: Item, _ songs: [Item]) -> Bool) {
        fillTask?.cancel()
        let feed = self.feed
        let maxFillPolls = self.maxFillPolls
        let pollInterval = self.pollInterval
        let sleep = self.sleep
        fillTask = Task { @MainActor [weak self] in
            var polls = 0
            var rebuilds = 0
            while !Task.isCancelled {
                guard let self, self.tapGeneration == tap, StationQueueKey(active()) == key,
                      queueEpoch() == epoch else { return }
                if feed.stagedKey == key {
                    if let songs = feed.takeForFill(active: active(), after: first) { _ = append(first, songs) }
                    return
                }
                if feed.buildingKey != key {
                    // The build failed or was replaced: try once more, then leave the one song
                    // (the queue then ends like any short queue; Play or a re-tap starts again).
                    guard rebuilds < 1 else { return }
                    rebuilds += 1
                    Task { @MainActor in _ = await feed.prepare(active()) }
                }
                guard polls < maxFillPolls else { return }
                polls += 1
                await sleep(pollInterval)
            }
        }
    }
}
