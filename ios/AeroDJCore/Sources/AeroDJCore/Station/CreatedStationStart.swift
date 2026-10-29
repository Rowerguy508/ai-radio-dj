import Foundation

// Created-station start (-Atlas, Orion's decision on #213): tapping a created station when
// nothing is queued starts it right away; while something plays, the switch stays at the song
// boundary (StationQueueFeed.takeForBoundary). Restoring the selection at launch never
// authorizes, applies or plays. The app supplies the closures; the decisions live here so they
// are tested on Linux. Diagnostics are enums and counts only.

/// How a station row was opened.
public enum StationOpenTrigger: String, Equatable, Sendable, CaseIterable {
    /// The listener tapped the row.
    case userTap
    /// The saved selection was restored at launch (or after the list changed).
    case restore
}

/// What opening a created station did.
public enum CreatedStationOpenOutcome: Equatable, Sendable {
    /// Restore: nothing authorized, applied or started.
    case restoredOnly
    /// The recipe could not be applied (deleted meanwhile, store failure). Nothing started.
    case notApplied
    /// Something is queued or playing: the station takes over at the next song boundary.
    case switchesAtBoundary
    /// Nothing was queued: the station's queue started. `waited` is true when it had to be built first.
    case started(songs: Int, waited: Bool)
    /// Nothing was queued but no start happened.
    case notStarted(CreatedStationNoStartReason)
}

public enum CreatedStationNoStartReason: String, Equatable, Sendable, CaseIterable {
    /// The applied station has no seeds.
    case noStation
    /// The queue was not built within the wait bound.
    case notReadyInTime
    /// The build failed (offline, empty pool, nothing playable). Play keeps its existing message.
    case buildFailed
    /// The listener started something else (a song tap, Play) while the queue was building.
    case playbackBegan
    /// A newer tap (or another station) replaced this one while it waited.
    case superseded
}

/// One per app session. Tracks the latest tap so only that tap may start playback.
@MainActor
public final class CreatedStationStarter<Item: Sendable> {
    private let feed: StationQueueFeed<Item>
    private let pollInterval: Duration
    private let maxPolls: Int
    private let sleep: @MainActor (Duration) async -> Void
    private var tapGeneration = 0
    /// The created station the last tap applied (Fry #213 nit 3). Cleared by `cancelPending()`
    /// and by a failed apply, so only a station that is still the listener's choice is skipped.
    public private(set) var currentRecipeID: UUID?

    /// - Parameters:
    ///   - readyTimeout: how long a tap waits for its queue before giving up (Play still works later).
    ///   - pollInterval: how often the wait re-checks the feed.
    public init(feed: StationQueueFeed<Item>,
                readyTimeout: Duration = .seconds(10),
                pollInterval: Duration = .milliseconds(100),
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.feed = feed
        self.pollInterval = pollInterval
        let ratio = readyTimeout / pollInterval
        self.maxPolls = max(1, Int(ratio.rounded(.up)))
        self.sleep = sleep
    }

    /// A built-in station was tapped (Fry #213 nit 2): a created-station tap still waiting for its
    /// queue must not start, and the created station is no longer current.
    public func cancelPending() {
        tapGeneration += 1
        currentRecipeID = nil
    }

    /// Opens a created station.
    /// - Parameters:
    ///   - recipeID: the created station's recipe. When it is already current the recipe is not
    ///     applied again, so unsaved Tune edits stay (Fry #213 nit 3); an idle tap still starts it.
    ///   - liveRecipeID: the recipe the live station last had applied from any caller
    ///     (`StudioPresentationModel.lastAppliedRecipeID`). The apply is skipped only when this tap's
    ///     cached id AND the live one both match, so another recipe applied in between (Tune) is
    ///     replaced (Fry #218). The default (nil) always applies.
    ///   - authorize: the music authorization prompt (user taps only).
    ///   - apply: applies the station's recipe (`StudioPresentationModel.applyRecipe`); false if it failed.
    ///   - active: the station's active configuration, read after `apply`.
    ///   - nothingQueued: true while the player is idle with an empty queue. Read before every start.
    ///   - start: plays the items (the idle-Play path: `StationQueuePlayer.play`).
    @discardableResult
    public func open(_ trigger: StationOpenTrigger,
                     recipeID: UUID? = nil,
                     liveRecipeID: @MainActor () -> UUID? = { nil },
                     authorize: @MainActor () async -> Void,
                     apply: @MainActor () async -> Bool,
                     active: @MainActor () -> StationConfiguration,
                     nothingQueued: @MainActor () -> Bool,
                     start: @MainActor ([Item]) async -> Void) async -> CreatedStationOpenOutcome {
        guard trigger == .userTap else { return .restoredOnly }
        tapGeneration += 1
        let mine = tapGeneration
        await authorize()
        guard mine == tapGeneration else { return .notStarted(.superseded) }
        let alreadyCurrent = recipeID != nil && recipeID == currentRecipeID && liveRecipeID() == recipeID
        if !alreadyCurrent {
            guard await apply() else {
                if mine == tapGeneration { currentRecipeID = nil }
                return .notApplied
            }
            guard mine == tapGeneration else { return .notStarted(.superseded) }
            currentRecipeID = recipeID
        }
        guard nothingQueued() else { return .switchesAtBoundary }
        let config = active()
        guard let key = StationQueueKey(config) else { return .notStarted(.noStation) }

        var waited = false
        var polls = 0
        while true {
            guard mine == tapGeneration, StationQueueKey(active()) == key else { return .notStarted(.superseded) }
            guard nothingQueued() else { return .notStarted(.playbackBegan) }
            if feed.stagedKey == key, let items = feed.takeForIdleStart(active: config) {
                await start(items)
                return .started(songs: items.count, waited: waited)
            }
            if feed.buildingKey != key, feed.stagedKey != key {
                // Not building (the follow has not started it yet, or a build failed): build it now.
                waited = true
                if case .skipped(let skip) = await feed.prepare(config), skip != .superseded {
                    return .notStarted(.buildFailed)
                }
                continue
            }
            guard polls < maxPolls else { return .notStarted(.notReadyInTime) }
            polls += 1
            waited = true
            await sleep(pollInterval)
        }
    }
}
