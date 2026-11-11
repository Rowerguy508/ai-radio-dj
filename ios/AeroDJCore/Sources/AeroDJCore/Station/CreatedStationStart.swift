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
// - Spend gate (Sentinel, #454): every tap first cancels any station intro still pending or
//   rendering (`StationIntroHook.cancelStationIntro`), and an intro is asked for only by the tap
//   that actually starts, without awaiting it, so the first song never waits on it and rapid taps
//   cannot fan out renders.
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
    /// #454: the station has no recipe yet (a built-in before #442 ships its content). The
    /// Starting screen says so honestly; nothing is applied or played, and search never opens.
    case notAvailableYet
}

/// #454 seam for Fry's station-start DJ intro (#442). Both calls are synchronous and must return
/// at once: the first song never waits on an intro. An intro must render only through the existing
/// TTS quota and reserve gate (no new speech path), and `cancelStationIntro` must drop any intro
/// still pending or rendering, so a burst of taps leaves at most one intro alive.
@MainActor
public protocol StationIntroHook: AnyObject {
    /// The tap with token `tap` is starting the station `key` now. Never awaited by the starter.
    func stationWillStart(_ key: StationQueueKey, tap: Int)
    /// A newer tap (or a cancel) replaced whatever intro was requested before.
    func cancelStationIntro()
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
    /// Fry's intro seam (#442). Nil: no intro is asked for.
    public weak var intro: (any StationIntroHook)?
    /// The station the last tap applied (Fry #213 nit 3). Cleared by `cancelPending()`
    /// and by a failed apply, so only a station that is still the listener's choice is skipped.
    public private(set) var currentRecipeID: UUID?

    /// - Parameters:
    ///   - readyTimeout: how long a tap waits for its first song before giving up (retry starts again).
    ///   - pollInterval: how often the wait re-checks the feed.
    ///   - fillTimeout: how long the background fill waits for the full queue after a fast start.
    public init(feed: StationQueueFeed<Item>,
                readyTimeout: Duration = .seconds(10),
                pollInterval: Duration = .milliseconds(100),
                fillTimeout: Duration = .seconds(30),
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.feed = feed
        self.pollInterval = pollInterval
        self.maxPolls = max(1, Int((readyTimeout / pollInterval).rounded(.up)))
        self.maxFillPolls = max(1, Int((fillTimeout / pollInterval).rounded(.up)))
        self.sleep = sleep
    }

    /// Another tap path took over (Fry #213 nit 2): a tap still waiting must not start, its fill
    /// stops, any intro is cancelled, and the station is no longer current.
    public func cancelPending() {
        tapGeneration += 1
        currentRecipeID = nil
        fillTask?.cancel()
        fillTask = nil
        intro?.cancelStationIntro()
    }

    /// Opens a station (built-in, library or created: the caller's `apply` decides which).
    /// - Parameters:
    ///   - recipeID: the station's identity. When it is already current the recipe is not
    ///     applied again, so unsaved Tune edits stay (Fry #213 nit 3).
    ///   - available: false when the station has nothing to apply yet (a built-in before #442).
    ///   - liveRecipeID: the recipe the live station last had applied from any caller
    ///     (`StudioPresentationModel.lastAppliedRecipeID`). The apply is skipped only when this tap's
    ///     cached id AND the live one both match (Fry #218). The default (nil) always applies.
    ///   - authorize: the music authorization prompt (user taps only).
    ///   - apply: applies the station's recipe; false if it failed.
    ///   - active: the station's active configuration, read after `apply` (and `switchNow`).
    ///   - nothingQueued: true while the player is idle with an empty queue.
    ///   - playingStation: the station whose queue is playing (`StationQueueFeed.playingKey` when the
    ///     playing queue is a station queue), nil when unknown. Only read while something is queued.
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
                     liveRecipeID: @MainActor () -> UUID? = { nil },
                     authorize: @MainActor () async -> Void,
                     apply: @MainActor () async -> Bool,
                     active: @escaping @MainActor () -> StationConfiguration,
                     nothingQueued: @MainActor () -> Bool,
                     playingStation: @MainActor () -> StationQueueKey? = { nil },
                     switchNow: @MainActor () async -> Void = {},
                     queueEpoch: @escaping @MainActor () -> Int = { 0 },
                     start: @MainActor ([Item]) async -> Void,
                     append: @escaping @MainActor (_ first: Item, _ songs: [Item]) -> Bool = { _, _ in false }) async -> CreatedStationOpenOutcome {
        guard trigger == .userTap else { return .restoredOnly }
        tapGeneration += 1
        let mine = tapGeneration
        // Sentinel's spend gate: nothing from an older tap may keep rendering or filling.
        fillTask?.cancel()
        fillTask = nil
        intro?.cancelStationIntro()
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
                intro?.stationWillStart(key, tap: mine)
                await start(items)
                return .started(songs: items.count, waited: waited)
            }
            if first.done, let song = first.value, feed.fastStartBegan(with: song, active: config) {
                intro?.stationWillStart(key, tap: mine)
                await start([song])
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
