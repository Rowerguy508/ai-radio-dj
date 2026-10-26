import Foundation
import Observation

/// The one model the Studio UI binds to: Station Tuner, recipes, Connections and DJ status.
/// It owns no playback, voice or provider code; the app's composition root (Claude's
/// `AppDependencies`, #58) creates the parts and feeds the inputs listed in
/// docs/studio-presentation-contract.md.
@MainActor @Observable
public final class StudioPresentationModel {
    public let station: StationConfigurationModel
    public let recipes: StationRecipeLibrary
    public let connections: ConnectionsModel
    /// Fed by `DJBreakPreparer` events and the player's started/finished/failed callbacks.
    public let dj: DJPresentationStore

    @ObservationIgnored private var changeTask: Task<Void, Never>?

    public init(station: StationConfigurationModel, recipes: StationRecipeLibrary,
                connections: ConnectionsModel, dj: DJPresentationStore) {
        self.station = station
        self.recipes = recipes
        self.connections = connections
        self.dj = dj
    }

    /// DJ status in the owner's five states. `isOnAir` is true only while `speaking`.
    public var djState: DJStudioState { dj.studioState }
    public var isOnAir: Bool { djState.isOnAir }
    /// True only while a rendered DJ break waits for the boundary of the song playing now: the
    /// DJ status is `.ready(afterTrack: k)`, song `k` is playing and its boundary hasn't passed.
    /// False when idle, preparing, speaking or failed, once the break is dropped or its source
    /// revoked, purged or expired, and once playback moved past `k` (a break handed out that
    /// never played leaves the status on `.ready`). Fails closed: false until the player reports
    /// a position. A Bool only, never text, names or ids. Backs the fixed "A break is coming" line.
    public var isBreakPrepared: Bool {
        guard case .ready(let k, _, _) = dj.state, k == playingSong, dj.state != staleBreak else { return false }
        return true
    }

    /// Index of the song playing now, as the player reports it; nil until the first report.
    private var playingSong: Int?
    /// A `.ready` status left behind after playback passed its boundary. Cleared on the next
    /// DJ status change, so an equal new break counts again once it is prepared.
    private var staleBreak: DJPresentationState?
    @ObservationIgnored private var staleWatch: Task<Void, Never>?

    /// Player input: song `index` of the queue started (natural advance, skip or new queue).
    public func songStarted(index: Int) {
        playingSong = index
        if case .ready(let k, _, _) = dj.state, k != index { markStale() }
    }

    /// Player input: song `k` ended on its own; its break, if any, is no longer coming.
    public func songBoundaryReached(afterTrack k: Int) {
        if case .ready(k, _, _) = dj.state { markStale() }
    }

    private func markStale() {
        staleBreak = dj.state
        staleWatch?.cancel()
        let updates = dj.updates()   // current status first, then each change
        staleWatch = Task { [weak self] in
            for await state in updates {
                guard let self, !Task.isCancelled else { return }
                if state != self.staleBreak { self.staleBreak = nil; return }
            }
        }
    }

    /// Loads persisted state and starts forwarding station changes to Connections, so a
    /// withdrawn integration purges its narration immediately.
    public func start() async {
        await station.load()
        await recipes.load()
        await connections.refresh()
        guard changeTask == nil else { return }
        let changes = station.changes()
        changeTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                await self.connections.handle(change)
            }
        }
    }

    public func stop() { changeTask?.cancel(); changeTask = nil }

    /// Saves the tuning the controls currently show (pending edits included) as a recipe.
    @discardableResult
    public func saveRecipe(named name: String) async -> Result<StationRecipe, StationRecipeError> {
        await recipes.save(name: name, configuration: station.displayed)
    }

    @discardableResult
    public func applyRecipe(_ id: UUID) async -> Result<[StationSetting: StationChangeTiming], StationRecipeError> {
        await recipes.apply(id, to: station)
    }
}

// MARK: - Previews (synthetic, in memory; no real providers)

@MainActor
public extension StudioPresentationModel {
    /// A loaded Studio for SwiftUI previews: pending tuning edit, two recipes, calendar
    /// connected, Obsidian stale, one flagged and one pending share. Synthetic data only.
    static func preview(dj: DJPresentationState = .idle) async -> StudioPresentationModel {
        let station = await StationConfigurationModel.preview(consent: [.calendar: .granted, .shareInbox: .granted, .obsidian: .granted])
        await station.setIntegration(.obsidian, requested: true)
        let recipes = StationRecipeLibrary(store: InMemoryStationRecipeStore(snapshot: .init(recipes: [
            StationRecipe(name: "Morning Mix", configuration: .sampleMorningMix),
            StationRecipe(name: "Late Night", configuration: .sampleLateNight),
        ])))
        let shared = InMemoryConnectionItemProvider(integration: .shareInbox, items: [
            ConnectionItem(id: UUID(), integration: .shareInbox, title: "[TEST] Dinner plans", state: .pendingApproval),
            ConnectionItem(id: UUID(), integration: .shareInbox, title: "[TEST] Odd message", state: .flaggedForReview),
            ConnectionItem(id: UUID(), integration: .shareInbox, title: "[TEST] Flight reminder", state: .approved),
        ])
        let reader = StaticConnectionSourceReader(
            calendar: .init(access: .fullAccess, calendars: [.init(id: "work", title: "Work"), .init(id: "home", title: "Home")],
                            selectedCalendarIDs: ["work"]),
            obsidian: .stale)
        let connections = ConnectionsModel(station: station, sourceReader: reader, providers: [shared],
                                           purger: NoopNarrationPurger())
        let store = DJPresentationStore()
        for event in DJPresentationEvent.previewEvents(for: dj) { store.send(event) }
        let model = StudioPresentationModel(station: station, recipes: recipes, connections: connections, dj: store)
        switch dj {   // the synthetic break belongs to the song "playing" in the preview
        case .preparing(let k, _), .ready(let k, _, _), .speaking(let k, _): model.songStarted(index: k)
        case .idle, .unavailable: break
        }
        await recipes.load()
        await connections.refresh()
        return model
    }
}

/// Purges nothing. Previews only: there is no narration to purge.
public struct NoopNarrationPurger: NarrationPurging {
    public init() {}
    public func purge(sourceItemIDs: Set<UUID>) async {}
}

extension DJPresentationEvent {
    /// Real event sequences that reach `state`, so previews use the same reducer as the app.
    static func previewEvents(for state: DJPresentationState) -> [DJPresentationEvent] {
        switch state {
        case .idle: []
        case .preparing(let k, let b): [.breakPreparing(afterTrack: k, includesBriefing: b)]
        case .ready(let k, let b, let s): [.breakReady(afterTrack: k, includesBriefing: b, seconds: s)]
        case .speaking(let k, let b): [.breakReady(afterTrack: k, includesBriefing: b, seconds: 8), .playbackStarted(afterTrack: k)]
        case .unavailable(.consentReviewRequired(let n)): [.consentReviewPending(count: n)]
        case .unavailable(.voiceFailed): [.breakSkipped(afterTrack: 0, .renderFailed)]
        case .unavailable(.budgetReached): [.breakSkipped(afterTrack: 0, .costCap)]
        }
    }
}
