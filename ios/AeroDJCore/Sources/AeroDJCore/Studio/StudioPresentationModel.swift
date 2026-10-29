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
    /// True only while a rendered DJ break waits for the next boundary (`.ready`): false when
    /// idle, preparing, speaking or failed, and once the break is dropped or its source revoked,
    /// purged or expired. Derived from the one DJ status the break session feeds; a Bool only,
    /// never text, names or ids. Backs the fixed "A break is coming" line.
    public var isBreakPrepared: Bool { if case .ready = dj.state { true } else { false } }

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

    /// Creates a station from artists, a genre or a playlist at a discovery level, and saves it
    /// as a recipe named `name` (same name rules and errors as `saveRecipe(named:)`). The new
    /// recipe keeps the tuning the controls show (energy, DJ personality, talk, briefing) and
    /// takes its seeds, reach and discovery from `request`. An invalid request fails with
    /// `.invalidStation(_)` and saves nothing. The live station is untouched unless `applying` is
    /// true, which then applies the saved recipe with the normal boundary rules (`applyRecipe`).
    @discardableResult
    public func saveRecipe(named name: String, from request: StationCreationRequest,
                           applying: Bool = false) async -> Result<StationRecipe, StationRecipeError> {
        let configuration: StationConfiguration
        switch request.configuration(base: station.displayed) {
        case .failure(let reason): return .failure(.invalidStation(reason))
        case .success(let config): configuration = config
        }
        let saved = await recipes.save(name: name, configuration: configuration)
        if applying, case .success(let recipe) = saved {
            _ = await recipes.apply(recipe.id, to: station)
        }
        return saved
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
