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
//   Fry N2 (#456): "started" means the transport reports `.playing`, not just a queue that was set,
//   so a start refused by a hold or a call never begins an intro.
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
    /// #456 (Fry N4): the tapped station is the active one and was paused: it resumed, as before.
    case resumed
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

/// The do-nothing async default for `CreatedStationStarter.open` (`switchNow`, `resume`). A stored
/// constant, so its closure exists once, in this module, instead of a weak copy in every caller
/// that omits the argument (swiftlang/swift#92017; see `CreatedStationStarter.init`).
public enum StationStartNoWork {
    public static let none: @MainActor () async -> Void = {}
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
    /// The clock the intro's confirmation wait is bounded by (tests supply their own).
    private let now: @MainActor () -> ContinuousClock.Instant
    private let readyTimeout: Duration
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
    ///   - sleep: the wait between polls. Nil: `Task.sleep`.
    ///
    /// The real sleep is supplied in the body, not as a closure-literal default argument
    /// (swiftlang/swift#92017, the #456 macOS abort): a default-argument async closure is emitted
    /// in this module AND in every caller that omits it, as weak copies whose async-context sizes
    /// disagree at -Onone (here 160 bytes in the library, 144 in each test file). The linker can pair
    /// one copy's body with another's size record, so every poll overran its task allocation and the
    /// next `swift_task_dealloc` aborted with "freed pointer was not the last allocation".
    public init(feed: StationQueueFeed<Item>,
                readyTimeout: Duration = .seconds(10),
                pollInterval: Duration = .milliseconds(100),
                fillTimeout: Duration = .seconds(30),
                introDelay: Duration = .seconds(2),
                sleep: (@MainActor (Duration) async -> Void)? = nil,
                now: (@MainActor () -> ContinuousClock.Instant)? = nil) {
        let sleep = sleep ?? { try? await Task.sleep(for: $0) }
        self.now = now ?? { ContinuousClock.now }
        self.feed = feed
        self.pollInterval = pollInterval
        self.maxPolls = max(1, Int((readyTimeout / pollInterval).rounded(.up)))
        self.maxFillPolls = max(1, Int((fillTimeout / pollInterval).rounded(.up)))
        self.introDelay = introDelay
        self.readyTimeout = readyTimeout
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
    ///   - transport: the transport as shown (`MusicKitService.snapshot.transport`). `.playing` confirms
    ///     a start before its intro begins (Fry N2); `.paused` on the active station resumes (Fry N4).
    ///   - resume: resumes the paused active station (the Play button's path).
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
                     switchNow: @MainActor () async -> Void = StationStartNoWork.none,
                     queueEpoch: @escaping @MainActor () -> Int = { 0 },
                     transport: @escaping @MainActor () -> TransportState = { .playing },
                     resume: @MainActor () async -> Void = StationStartNoWork.none,
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
        // Fry N3: a re-tap on the current station applied nothing, so nothing is promoted either
        // (pending Tune edits keep their boundary) when its queue is the one playing.
        if !wasIdle, alreadyCurrent, let current = StationQueueKey(active()), playingStation() == current {
            return await sameStation(transport: transport, resume: resume)
        }
        if !wasIdle {
            // A row tap switches now; the applied change would otherwise wait for the boundary.
            await switchNow()
            guard mine == tapGeneration else { return .notStarted(.superseded) }
        }
        let config = active()
        guard let key = StationQueueKey(config) else { return .notStarted(.noStation) }
        if !wasIdle, !nothingQueued(), playingStation() == key {
            return await sameStation(transport: transport, resume: resume)
        }
        let epoch = queueEpoch()

        // The full queue builds in the background; the first song resolves on its own, faster.
        // macOS #456 crash ("freed pointer was not the last allocation"): this async frame holds no
        // value of the generic `Item` type, creates no Task and calls no local function. Those
        // live in the synchronous helpers below, so no task-allocator slot spans an `await` here.
        var build = buildIfIdle(config, key: key)
        let first = lookUpFirstSong(config, key: key)

        var waited = false
        var polls = 0
        while true {
            guard mine == tapGeneration, StationQueueKey(active()) == key else { return .notStarted(.superseded) }
            guard queueEpoch() == epoch, !wasIdle || nothingQueued() else { return .notStarted(.playbackBegan) }
            if feed.stagedKey == key, let items = feed.takeForIdleStart(active: config) {
                await start(items)
                startConfirmed(introFacts, tap: mine, key: key, nothingQueued: nothingQueued,
                               queueEpoch: queueEpoch, playingStation: playingStation, transport: transport)
                return .started(songs: items.count, waited: waited)
            }
            if let items = takeFastStart(first, active: config) {
                await start(items)
                startConfirmed(introFacts, tap: mine, key: key, nothingQueued: nothingQueued,
                               queueEpoch: queueEpoch, playingStation: playingStation, transport: transport)
                if mine == tapGeneration {
                    scheduleFill(tap: mine, key: key, startedWith: items, active: active,
                                 queueEpoch: queueEpoch, epoch: queueEpoch(), append: append)
                }
                return .started(songs: items.count, waited: waited)
            }
            if let box = build, box.done {
                if case .skipped(let skip) = box.value, skip != .superseded, first.done {
                    return .notStarted(.buildFailed)
                }
                if feed.stagedKey != key { build = nil }
            }
            if build == nil { build = buildIfIdle(config, key: key) }
            guard polls < maxPolls else { return .notStarted(.notReadyInTime) }
            polls += 1
            waited = true
            await sleep(pollInterval)
        }
    }

    /// The active station tapped again: playing is a no-op, paused resumes (Fry N4).
    private func sameStation(transport: @MainActor () -> TransportState,
                             resume: @MainActor () async -> Void) async -> CreatedStationOpenOutcome {
        guard transport() == .paused else { return .alreadyPlaying }
        await resume()
        return .resumed
    }

    /// After `start`: the intro may begin once this start is confirmed and stays current.
    private func startConfirmed(_ facts: StationIntroFacts?, tap: Int, key: StationQueueKey,
                                nothingQueued: @MainActor () -> Bool,
                                queueEpoch: @escaping @MainActor () -> Int,
                                playingStation: @escaping @MainActor () -> StationQueueKey?,
                                transport: @escaping @MainActor () -> TransportState) {
        guard tap == tapGeneration, !nothingQueued(), playingStation() == key else { return }
        scheduleIntro(facts, tap: tap, key: key, epoch: queueEpoch(),
                      queueEpoch: queueEpoch, playingStation: playingStation, transport: transport)
    }

    /// Starts the station's full build in the background unless it is already building or staged.
    /// Nil when nothing was started.
    private func buildIfIdle(_ config: StationConfiguration, key: StationQueueKey) -> Pending<StationQueuePrepareOutcome>? {
        guard feed.buildingKey != key, feed.stagedKey != key else { return nil }
        let box = Pending<StationQueuePrepareOutcome>()
        Task { @MainActor [feed] in
            box.value = await feed.prepare(config)
            box.done = true
        }
        return box
    }

    /// Resolves the station's first song in the background (not needed when the queue is staged).
    private func lookUpFirstSong(_ config: StationConfiguration, key: StationQueueKey) -> Pending<Item> {
        let first = Pending<Item>()
        guard feed.stagedKey != key else { return first }
        Task { @MainActor [feed] in
            first.value = await feed.firstSong(for: config)
            first.done = true
        }
        return first
    }

    /// The fast start (#454): the resolved first song alone, once the feed has handed the playing
    /// queue to the station. Nil while it is unresolved or when there is none.
    private func takeFastStart(_ first: Pending<Item>, active config: StationConfiguration) -> [Item]? {
        guard first.done, let song = first.value, feed.fastStartBegan(with: song, active: config) else { return nil }
        return [song]
    }

    /// Begins the confirmed station's intro after `introDelay`, if nothing replaced the start
    /// meanwhile (a newer tap cancels this task first). Never awaited by the start.
    private func scheduleIntro(_ facts: StationIntroFacts?, tap: Int, key: StationQueueKey, epoch: Int,
                               queueEpoch: @escaping @MainActor () -> Int,
                               playingStation: @escaping @MainActor () -> StationQueueKey?,
                               transport: @escaping @MainActor () -> TransportState) {
        introTask?.cancel()
        introTask = nil
        guard let facts, intro != nil, airIntro != nil else { return }
        let delay = introDelay
        let sleep = self.sleep
        let pollInterval = self.pollInterval
        let maxPolls = self.maxPolls
        let now = self.now
        // Fry N2: begin only once the first song is really playing (not preparing, held, or
        // refused), waiting at most the start's own bound. The bound is a deadline on the clock,
        // checked after every wake (#456 macOS): a count of polls stretched with every oversleep
        // (40 "1 ms" polls ran past 150 ms on a loaded runner), so a release after the bound still
        // began a render. The poll count stays as a backstop for a sleep that does not advance time.
        let deadline = now() + delay + readyTimeout
        introTask = Task { @MainActor [weak self] in
            await sleep(delay)
            var polls = 0
            while true {
                guard !Task.isCancelled, now() <= deadline else { return }
                if transport() == .playing { break }
                guard polls < maxPolls else { return }
                polls += 1
                await sleep(pollInterval)
            }
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
    private func scheduleFill(tap: Int, key: StationQueueKey, startedWith: [Item],
                              active: @escaping @MainActor () -> StationConfiguration,
                              queueEpoch: @escaping @MainActor () -> Int, epoch: Int,
                              append: @escaping @MainActor (_ first: Item, _ songs: [Item]) -> Bool) {
        fillTask?.cancel()
        guard let first = startedWith.first else { return }
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
