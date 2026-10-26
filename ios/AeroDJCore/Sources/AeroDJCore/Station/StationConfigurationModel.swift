import Foundation
import Observation

/// Reads the existing consent state for an integration. Implemented by the app's
/// consent flow; this model never changes consent.
public protocol IntegrationConsentReading: Sendable {
    func consentState(for integration: StationIntegration) async -> ConsentState
}

/// Fixed consent answers, for tests and previews. Not an integration.
public struct StaticIntegrationConsent: IntegrationConsentReading {
    public let states: [StationIntegration: ConsentState]
    public init(_ states: [StationIntegration: ConsentState]) { self.states = states }
    public func consentState(for integration: StationIntegration) async -> ConsentState {
        states[integration] ?? .notRequested
    }
}

/// What a control may honestly show.
public enum StationControlStatus: Equatable, Sendable {
    case idle
    case saving
    /// Saved; becomes active at this point ("Applies after this song", ...).
    case pendingBoundary(StationChangeTiming)
    /// The integration is requested but consent is not granted; nothing is read from it.
    case consentRequired(ConsentState)
    case error(StationControlError)
}

public enum StationControlError: Equatable, Sendable {
    /// The edit was not saved and was rolled back.
    case saveFailed
    /// A privacy reduction is in effect now but could not be saved; it will be saved with the next change.
    case reductionNotSaved
    /// Settings on disk are from a newer AeroDJ; editing is disabled to avoid overwriting them.
    case readOnlyNewerVersion
    /// Settings have not finished loading.
    case notLoaded
}

/// Honest state of one integration, combining the listener's request with real consent.
public enum StationIntegrationStatus: Equatable, Sendable {
    /// Not requested by the listener.
    case off
    /// Requested; consent has not been read yet. Show "Checking…", never "Connected".
    case checking
    /// Requested and consent granted. Items are still filtered by `isNarratable(at:)`.
    case on
    /// Requested; the user has not been asked yet. Route to the existing consent flow.
    case consentReviewRequired
    /// Requested; consent denied or revoked. Only the user can change that, in the consent flow or Settings.
    case blocked(ConsentState)

    /// Only `.on` may be shown as connected or in use.
    public var mayShowConnected: Bool { self == .on }
}

public enum StationConfigurationLoadState: Equatable, Sendable {
    case notLoaded
    case loading
    case ready
    /// Defaults are in use; the error says why.
    case failed(StationConfigurationStoreError)
}

/// UI-facing read model and intents for the station configuration (Claudio's contract).
/// Create once at app/scene level, not in a view, so fold/unfold never recreates it.
@MainActor @Observable
public final class StationConfigurationModel {
    public private(set) var state: StationConfigurationState
    public private(set) var loadState: StationConfigurationLoadState = .notLoaded
    public private(set) var consent: [StationIntegration: ConsentState] = [:]
    private var saving: [StationSetting: Int] = [:]
    private var errors: [StationSetting: StationControlError] = [:]

    @ObservationIgnored private let store: any StationConfigurationPersisting
    @ObservationIgnored private let consentReader: any IntegrationConsentReading
    @ObservationIgnored private var lastSave: Task<Bool, Never>?
    @ObservationIgnored private var listeners: [UUID: AsyncStream<StationConfigurationChange>.Continuation] = [:]
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?

    public init(store: any StationConfigurationPersisting,
                consent: any IntegrationConsentReading,
                initial: StationConfigurationState = .init()) {
        self.store = store
        self.consentReader = consent
        self.state = initial
    }

    // MARK: Read model

    /// What every control should display (pending value if one is waiting).
    public var displayed: StationConfiguration { state.displayed }
    /// What playback and the DJ use right now.
    public var active: StationConfiguration { state.active }
    public var hasPendingChanges: Bool { state.pending != nil }

    public func status(for setting: StationSetting) -> StationControlStatus {
        if saving[setting, default: 0] > 0 { return .saving }
        if let error = errors[setting] { return .error(error) }
        if case .integration(let i) = setting, displayed.requestedIntegrations.contains(i),
           let c = consent[i], c != .granted {
            return .consentRequired(c)
        }
        if let timing = state.pendingSettings[setting] { return .pendingBoundary(timing) }
        return .idle
    }

    public func integrationStatus(_ integration: StationIntegration) -> StationIntegrationStatus {
        guard displayed.requestedIntegrations.contains(integration) else { return .off }
        switch consent[integration] {
        case nil: return .checking
        case .granted?: return .on
        case .notRequested?: return .consentReviewRequired
        case let other?: return .blocked(other)
        }
    }

    /// Integrations that are both requested (active) and consented. Context sources must use only these.
    public var usableIntegrations: Set<StationIntegration> {
        active.requestedIntegrations.filter { consent[$0] == .granted }
    }

    /// Briefing sections that can really be planned now.
    public var plannableBriefingSections: Set<BriefingSection> {
        active.briefing.plannableSections(grantedIntegrations: usableIntegrations)
    }

    /// Active-configuration changes (immediate and at boundaries), for the scheduler and DJ preparer.
    public func changes() -> AsyncStream<StationConfigurationChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<StationConfigurationChange>.makeStream(bufferingPolicy: .unbounded)
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
        return stream
    }

    // MARK: Lifecycle

    public func load() async {
        loadState = .loading
        do {
            if let snapshot = try await store.load() { state = snapshot.state }
            loadState = .ready
        } catch let error as StationConfigurationStoreError {
            state = .init()
            loadState = .failed(error)
        } catch {
            state = .init()
            loadState = .failed(.unreadable)
        }
        await refreshConsent()
    }

    /// Re-reads consent (call after the consent flow returns or on foreground).
    public func refreshConsent() async {
        var next: [StationIntegration: ConsentState] = [:]
        for integration in StationIntegration.allCases {
            next[integration] = await consentReader.consentState(for: integration)
        }
        consent = next
    }

    /// Starts applying pending changes at the scheduler's boundary events.
    public func attach(to source: some StationBoundaryEventSource) {
        boundaryTask?.cancel()
        let events = source.stationBoundaryEvents()
        boundaryTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    public func detach() { boundaryTask?.cancel(); boundaryTask = nil }

    /// Applies what `event` allows, publishes the change, and saves.
    public func handle(_ event: StationBoundaryEvent) async {
        guard let change = state.apply(event) else { return }
        publish(change)
        if canSave { _ = await enqueueSave().value }
    }

    // MARK: Intents

    public func setGenres(_ genres: [String]) async { await edit(.genres) { $0.genres = genres } }
    public func setMoods(_ moods: [String]) async { await edit(.moods) { $0.moods = moods } }
    public func setEnergy(_ energy: Double) async { await edit(.energy) { $0.energy = energy } }
    public func setDiscovery(_ discovery: Double) async { await edit(.discovery) { $0.discovery = discovery } }
    public func setPersonality(_ p: DJPersonality) async { await edit(.personality) { $0.personality = p } }
    public func setCommentary(_ c: CommentaryFrequency) async { await edit(.commentary) { $0.commentary = c } }
    public func setBriefing(_ transform: @escaping (inout BriefingPreferences) -> Void) async {
        await edit(.briefing) { transform(&$0.briefing) }
    }

    /// Requests or withdraws an integration. Requesting never grants access: if consent is
    /// not granted the control shows `.consentRequired` and the UI should open the consent flow.
    public func setIntegration(_ integration: StationIntegration, requested: Bool) async {
        await edit(.integration(integration)) {
            if requested { $0.requestedIntegrations.insert(integration) }
            else { $0.requestedIntegrations.remove(integration) }
        }
    }

    /// Applies a saved recipe's tuning (everything except connections) with the same
    /// boundary rules as editing each control: music settings wait for the song boundary,
    /// personality for the next DJ break, briefing for the next briefing; turning
    /// commentary or the briefing off applies now. Connections (`requestedIntegrations`)
    /// are never changed by a recipe.
    public func applyRecipe(_ recipe: StationRecipe) async {
        let target = recipe.configuration
        await edit(Set(StationSetting.tuning)) { config in
            let keep = config.requestedIntegrations
            config = target
            config.requestedIntegrations = keep
        }
    }

    /// Throws away pending edits; active settings are untouched.
    public func discardPendingChanges() async {
        guard state.pending != nil, canSave else { return }
        state.discardPending()
        _ = await enqueueSave().value
    }

    // MARK: Internals

    private var canSave: Bool {
        if case .failed(.newerVersion) = loadState { return false }
        return true
    }

    private func edit(_ setting: StationSetting, _ transform: (inout StationConfiguration) -> Void) async {
        await edit([setting], transform)
    }

    /// One edit that may touch several controls (a recipe). Same rules as single edits:
    /// privacy reductions apply now, everything else waits for its boundary, and a failed
    /// save rolls back only what was not a reduction.
    private func edit(_ settings: Set<StationSetting>, _ transform: (inout StationConfiguration) -> Void) async {
        guard !settings.isEmpty else { return }
        switch loadState {
        case .notLoaded, .loading: for s in settings { errors[s] = .notLoaded }; return
        case .failed(.newerVersion): for s in settings { errors[s] = .readOnlyNewerVersion }; return
        default: break
        }
        let before = state
        let outcome = state.edit(transform)
        var reductions = Set<StationSetting>()
        switch outcome {
        case .unchanged:
            return
        case .pending:
            break
        case .applied(let change, _):
            reductions = change.applied.intersection(settings)
            publish(change)  // privacy reductions take effect before any disk write
        }
        for s in settings { errors[s] = nil; saving[s, default: 0] += 1 }
        let saved = await enqueueSave().value
        for s in settings { saving[s, default: 1] -= 1 }
        guard !saved else { return }
        for s in settings {
            if reductions.contains(s) {
                errors[s] = .reductionNotSaved
            } else if s.differs(before.displayed, state.displayed) || s.differs(before.active, state.active) {
                state.restore(s, from: before)
                errors[s] = .saveFailed
            }
        }
    }

    /// Saves are serialized so a slow earlier write can never overwrite a later one.
    private func enqueueSave() -> Task<Bool, Never> {
        let previous = lastSave
        let store = store
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            let snapshot = StationConfigurationSnapshot(state: self.state)
            do { try await store.save(snapshot); return true } catch { return false }
        }
        lastSave = task
        return task
    }

    private func publish(_ change: StationConfigurationChange) {
        for continuation in listeners.values { continuation.yield(change) }
    }
}
