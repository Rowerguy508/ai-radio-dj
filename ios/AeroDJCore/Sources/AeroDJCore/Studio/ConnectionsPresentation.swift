import Foundation
import Observation

// Connections read model: per source (Calendar, Obsidian, Mail/Messages via Share) and per
// item. Built on the existing sources: `CalendarAccess` / `CalendarEventReading` (#50),
// `MarkdownReadError` / `ObsidianSkipReason` (#38), `SharedInboxReview` (#42), consent via
// `StationIntegration` + `ConsentState`. Revoke and delete always go through
// `NarrationPurging` (cached narration + prepared DJ breaks).

// MARK: - Actions

/// Everything a Connections control may offer. The model only lists actions that are valid
/// for the current state; `ConnectionsModel.perform` rejects anything else.
public enum ConnectionAction: String, Equatable, Sendable, CaseIterable {
    /// Show the system calendar prompt (only while access is `notDetermined`).
    case allowAccess
    /// Pick, or pick again, which calendars or which Obsidian files AeroDJ may read.
    case reselect
    /// Open the app's page in iOS Settings (access can only be changed there).
    case openSettings
    case approve
    /// Open the item so the user can read, label or redact it.
    case review
    /// Approve an item the sanitizer held back and confirm it may be read as written.
    case readAnyway
    /// Stop using it. Purges derived narration and prepared breaks first.
    case revoke
    /// Remove it from AeroDJ. Purges derived narration and prepared breaks first.
    case delete

    public var title: String {
        switch self {
        case .allowAccess: "Allow access"
        case .reselect: "Choose again"
        case .openSettings: "Open Settings"
        case .approve: "Approve"
        case .review: "Review"
        case .readAnyway: "Read anyway"
        case .revoke: "Stop using"
        case .delete: "Delete"
        }
    }

    /// Actions that remove data from narration. Always purge before anything else.
    public var purgesNarration: Bool { self == .revoke || self == .delete }
}

// MARK: - Source state

/// Calendar: OS permission plus the calendars the user picked. Nothing is read without
/// `fullAccess` *and* at least one picked calendar.
public struct CalendarConnectionState: Equatable, Sendable {
    public var access: CalendarAccess
    public var calendars: [CalendarDescriptor]
    public var selectedCalendarIDs: Set<String>

    public init(access: CalendarAccess, calendars: [CalendarDescriptor] = [], selectedCalendarIDs: Set<String> = []) {
        self.access = access
        self.calendars = calendars
        self.selectedCalendarIDs = selectedCalendarIDs
    }

    /// Picked calendars that still exist and are readable.
    public var readableSelection: Set<String> {
        access == .fullAccess ? selectedCalendarIDs.intersection(calendars.map(\.id)) : []
    }

    public var isReading: Bool { !readableSelection.isEmpty }

    public var description: String {
        switch access {
        case .notDetermined: return "AeroDJ hasn't asked to read your calendar yet."
        case .denied: return "Calendar access is off. You can turn it on in Settings."
        case .restricted: return "Calendar access is restricted on this device, for example by Screen Time or device management."
        case .writeOnly: return "AeroDJ can only add events, not read them. Briefings need Full Access, which you can allow in Settings."
        case .fullAccess:
            let n = readableSelection.count
            if n == 0 { return "No calendars chosen. AeroDJ reads only the calendars you pick." }
            return "Reading today's events from \(n) of \(calendars.count) \(calendars.count == 1 ? "calendar" : "calendars")."
        }
    }

    public var actions: [ConnectionAction] {
        switch access {
        case .notDetermined: [.allowAccess]
        case .denied, .writeOnly: [.openSettings]
        case .restricted: []
        case .fullAccess: isReading ? [.reselect, .revoke] : [.reselect]
        }
    }
}

/// Obsidian: only Markdown files the user explicitly picked (security-scoped bookmarks).
public enum ObsidianSelectionState: Equatable, Sendable {
    case notSelected
    case valid(fileCount: Int)
    /// A picked file was moved or renamed; the bookmark must be renewed by picking again.
    case stale
    /// The picked files are gone or access was lost.
    case missing
    /// iCloud placeholder that isn't downloaded.
    case notDownloaded

    public init(readError: MarkdownReadError) {
        switch readError {
        case .bookmarkStale: self = .stale
        case .notFound, .accessDenied: self = .missing
        case .notDownloaded: self = .notDownloaded
        }
    }

    public var isReading: Bool { if case .valid(let n) = self { n > 0 } else { false } }

    public var description: String {
        switch self {
        case .notSelected: "No notes chosen. AeroDJ reads only the Markdown files you pick."
        case .valid(let n): "Using \(n) \(n == 1 ? "file" : "files") you picked. Nothing else in your vault is read."
        case .stale: "A file you picked was moved or renamed. Choose it again to keep using it."
        case .missing: "The files you picked are gone, or AeroDJ lost access to them. Choose them again."
        case .notDownloaded: "The files you picked are in iCloud and not downloaded. Download them in Files, then come back."
        }
    }

    public var actions: [ConnectionAction] {
        switch self {
        case .notSelected: [.reselect]
        case .valid, .stale, .missing, .notDownloaded: [.reselect, .revoke]
        }
    }
}

/// Mail and Messages: only what the user shared to AeroDJ with the Share button.
/// There is no mailbox or Messages access, so there is no authorization state.
public struct SharedImportsState: Equatable, Sendable {
    public var waitingForReview: Int
    public var approved: Int

    public init(waitingForReview: Int = 0, approved: Int = 0) {
        self.waitingForReview = waitingForReview
        self.approved = approved
    }

    public var isReading: Bool { approved > 0 }

    public var description: String {
        if waitingForReview > 0 {
            return "\(waitingForReview) shared \(waitingForReview == 1 ? "item is" : "items are") waiting for your review."
        }
        if approved > 0 { return "\(approved) shared \(approved == 1 ? "item" : "items") approved for briefings." }
        return "Nothing shared yet. Use the Share button in Mail or Messages to send something to AeroDJ."
    }
}

/// One row in the Connections list.
public struct ConnectionSourceRow: Equatable, Sendable, Identifiable {
    public enum Detail: Equatable, Sendable {
        case calendar(CalendarConnectionState)
        case obsidian(ObsidianSelectionState)
        case sharedImports(SharedImportsState)
    }

    public let integration: StationIntegration
    /// The listener's request combined with consent (`StationConfigurationModel`).
    public let status: StationIntegrationStatus
    public let detail: Detail
    public var id: StationIntegration { integration }

    public var title: String { StationSetting.integration(integration).title }

    /// Fixed privacy scope copy. Always shown; it never changes with state.
    public var scope: String {
        switch integration {
        case .calendar: "Reads today's events from calendars you choose. Read-only: AeroDJ never adds or changes events."
        case .obsidian: "Reads only the Markdown files you pick. Stays on this device."
        case .shareInbox: "Only what you share to AeroDJ from Mail, Messages or other apps. AeroDJ never opens your mailbox or messages."
        }
    }

    public var description: String {
        switch status {
        case .off: return "Off. Turn it on in the Station Tuner to use it in briefings."
        case .checking: return "Checking…"
        case .consentReviewRequired: return "Needs your permission before anything is used."
        case .blocked: return "Permission is off. Nothing from here is used."
        case .on:
            switch detail {
            case .calendar(let c): return c.description
            case .obsidian(let o): return o.description
            case .sharedImports(let s): return s.description
            }
        }
    }

    public var actions: [ConnectionAction] {
        switch detail {
        case .calendar(let c): c.actions
        case .obsidian(let o): o.actions
        case .sharedImports: []
        }
    }

    /// "Connected" may be shown only when consent is granted and the source can actually be read.
    public var mayShowConnected: Bool {
        guard status.mayShowConnected else { return false }
        switch detail {
        case .calendar(let c): return c.isReading
        case .obsidian(let o): return o.isReading
        case .sharedImports(let s): return s.isReading
        }
    }
}

// MARK: - Item lifecycle

public enum ConnectionUnavailableReason: Equatable, Sendable {
    case calendarAccess(CalendarAccess)
    case file(ObsidianSkipReason)

    public var description: String {
        switch self {
        case .calendarAccess(let a): return "Unavailable: \(CalendarConnectionState(access: a).description)"
        case .file(let r):
            switch r {
            case .bookmarkStale: return "Unavailable: the file was moved or renamed. Choose it again."
            case .notFound, .accessDenied: return "Unavailable: the file is gone or AeroDJ lost access."
            case .notDownloaded: return "Unavailable: the file is in iCloud and not downloaded."
            case .optedOut: return "Not used: the note asks not to be read (aerodj: false or private: true)."
            case .tooLarge: return "Not used: the file is too large."
            case .unsupportedType, .binaryContent, .notUTF8: return "Not used: this isn't a readable Markdown file."
            case .empty: return "Not used: nothing readable was left after cleanup."
            case .invalidPath, .outsideScope, .hiddenOrSystem: return "Not used: the file is outside what you picked."
            case .fileLimitReached: return "Not used: too many files picked."
            }
        }
    }
}

public enum ConnectionItemState: Equatable, Sendable {
    case pendingApproval
    /// The injection sanitizer flagged it; it is never read until the user reviews it.
    case flaggedForReview
    case approved
    case expired
    /// Consent denied or withdrawn by the user.
    case revoked
    case unavailable(ConnectionUnavailableReason)

    /// One precedence for every source: unavailable > expired > revoked > flagged > pending > approved.
    public static func resolve(consent: ConsentState, expiresAt: Date?, now: Date, flagged: Bool,
                               reconfirmed: Bool, unavailable: ConnectionUnavailableReason? = nil) -> ConnectionItemState {
        if let unavailable { return .unavailable(unavailable) }
        if let expiresAt, expiresAt <= now { return .expired }
        switch consent {
        case .denied, .revoked: return .revoked
        case .notRequested: return flagged ? .flaggedForReview : .pendingApproval
        case .granted: return flagged && !reconfirmed ? .flaggedForReview : .approved
        }
    }

    /// The only state whose content the DJ may narrate.
    public var mayBeNarrated: Bool { self == .approved }

    public var description: String {
        switch self {
        case .pendingApproval: "Waiting for your OK. The DJ won't mention it until you approve it."
        case .flaggedForReview: "Held back: it contains text that looks like instructions to the DJ. Review it before it can be read."
        case .approved: "Approved. The DJ may mention it in a briefing."
        case .expired: "Expired. It's no longer used."
        case .revoked: "Not used. You turned this off."
        case .unavailable(let r): r.description
        }
    }

    /// Valid actions for this state from `integration`.
    public func actions(for integration: StationIntegration) -> [ConnectionAction] {
        switch integration {
        case .shareInbox:
            switch self {
            case .pendingApproval: [.approve, .review, .delete]
            case .flaggedForReview: [.review, .readAnyway, .delete]
            case .approved: [.review, .revoke, .delete]
            case .revoked: [.approve, .delete]
            case .expired, .unavailable: [.delete]
            }
        case .obsidian:
            switch self {
            case .pendingApproval: [.approve, .review]
            case .flaggedForReview: [.review, .readAnyway]
            case .approved: [.review, .revoke]
            case .revoked: [.approve]
            case .expired: []
            case .unavailable(.file(.bookmarkStale)), .unavailable(.file(.notFound)), .unavailable(.file(.accessDenied)):
                [.reselect]
            case .unavailable: []
            }
        case .calendar:
            // Calendar consent and selection are per source, not per event.
            switch self {
            case .unavailable(.calendarAccess(.notDetermined)): [.allowAccess]
            case .unavailable(.calendarAccess(.denied)), .unavailable(.calendarAccess(.writeOnly)): [.openSettings]
            default: []
            }
        }
    }
}

public struct ConnectionItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let integration: StationIntegration
    public let title: String
    public let state: ConnectionItemState
    public let expiresAt: Date?

    public init(id: UUID, integration: StationIntegration, title: String, state: ConnectionItemState, expiresAt: Date? = nil) {
        self.id = id
        self.integration = integration
        self.title = title
        self.state = state
        self.expiresAt = expiresAt
    }

    public var description: String { state.description }
    public var actions: [ConnectionAction] { state.actions(for: integration) }

    /// Whether the DJ may narrate it at `now`: its last known state is `.approved` and it has
    /// not expired since, by the same rule as `ConnectionItemState.resolve` (`expiresAt <= now`
    /// is expired). Used at song boundaries, where no `refresh()` has re-resolved the state.
    public func mayBeNarrated(at now: Date) -> Bool {
        state.mayBeNarrated
            && ConnectionItemState.resolve(consent: .granted, expiresAt: expiresAt, now: now,
                                           flagged: false, reconfirmed: false).mayBeNarrated
    }
}

// MARK: - Boundaries the app implements

/// Lists and changes the items of one source. Implementations must never read beyond what
/// the user selected or shared.
public protocol ConnectionItemProvider: Sendable {
    var integration: StationIntegration { get }
    func items(now: Date) async throws -> [ConnectionItem]
    /// Approve, read anyway, revoke or delete one item. `review` / `reselect` are UI navigation.
    func perform(_ action: ConnectionAction, on id: UUID) async throws
}

/// Source-level state the app reads from the OS (EventKit, bookmarks).
public protocol ConnectionSourceReading: Sendable {
    func calendarState() async -> CalendarConnectionState
    func obsidianSelection() async -> ObsidianSelectionState
    /// User-initiated only (`allowAccess`).
    func requestCalendarAccess() async -> CalendarAccess
    func setSelectedCalendars(_ ids: Set<String>) async throws
    /// `revoke` on a source: forget the picked calendars / file bookmarks.
    func clearSelection(_ integration: StationIntegration) async throws
}

/// Removes everything derived from personal items. Production: `NarrationPurger`.
public protocol NarrationPurging: Sendable {
    func purge(sourceItemIDs: Set<UUID>) async
}

/// Removes the items from future break plans, then purges prepared DJ breaks (so they can
/// never play), then cached narration audio.
public struct NarrationPurger: NarrationPurging {
    public let cache: any AudioCache
    public let preparer: DJBreakPreparer?
    /// Weak: the session holds this purger too (`DJBreakSession.purger`, boundary expiry).
    public private(set) weak var session: DJBreakSession?
    public let revocations: NarrationRevocations
    /// Every completed purge is published here (for example, to stop on-air speech elsewhere).
    public let feed: NarrationPurgeFeed

    public init(cache: any AudioCache, preparer: DJBreakPreparer?, session: DJBreakSession? = nil,
                revocations: NarrationRevocations = .shared, feed: NarrationPurgeFeed = .shared) {
        self.cache = cache
        self.preparer = preparer
        self.session = session
        self.revocations = revocations
        self.feed = feed
    }

    public func purge(sourceItemIDs: Set<UUID>) async {
        guard !sourceItemIDs.isEmpty else { return }
        // First: an in-flight render for these items must not cache its result (VoiceRenderer).
        revocations.revoke(sourceItemIDs)
        // The session first: it stops a break that is on air for these items right away.
        if let session { await session.purge(sourceItemIDs: sourceItemIDs) }
        await preparer?.purge(sourceItemIDs: sourceItemIDs)
        await cache.purge(sourceItemIDs: sourceItemIDs)
        revocations.purgeCompleted(sourceItemIDs)
        await AudioCacheFileLog.record(cache, after: .purge)
        feed.publish(.items(sourceItemIDs))
    }

    /// Removes all personal narration without knowing item ids: renders in flight, planned and
    /// on-air breaks that mention any personal item, and every personal clip in the cache.
    /// Works in live mode, where consent is not persisted across launches.
    public func purgeAllPersonalNarration() async {
        revocations.revokeAll()
        let known = await session?.purgeAllPersonal() ?? []
        if !known.isEmpty { await preparer?.purge(sourceItemIDs: known) }
        await cache.purgeAllPersonal()
        revocations.purgeAllCompleted()
        await AudioCacheFileLog.record(cache, after: .purge)
        feed.publish(.all)
    }
}

/// What a completed purge removed.
public enum NarrationPurge: Equatable, Sendable {
    case items(Set<UUID>)
    /// Every personal item (`purgeAllPersonalNarration`).
    case all
}

/// Broadcasts completed purges. Each `updates()` stream gets every purge published after it
/// was created. Process-wide by default, like `NarrationRevocations`.
public final class NarrationPurgeFeed: @unchecked Sendable {
    public static let shared = NarrationPurgeFeed()
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<NarrationPurge>.Continuation] = [:]

    public init() {}

    public func updates() -> AsyncStream<NarrationPurge> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NarrationPurge>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.continuations[id] = nil } }
        lock.withLock { continuations[id] = continuation }
        return stream
    }

    public func publish(_ purge: NarrationPurge) {
        for continuation in lock.withLock({ Array(continuations.values) }) { continuation.yield(purge) }
    }
}

/// `ConnectionItemProvider` over the existing share inbox review (#42).
public struct SharedInboxConnectionProvider: ConnectionItemProvider {
    public let integration: StationIntegration = .shareInbox
    public let review: SharedInboxReview
    private let sanitizer = PromptInjectionSanitizer()

    public init(review: SharedInboxReview) { self.review = review }

    public func items(now: Date) async throws -> [ConnectionItem] {
        try await review.refresh()
        let sanitizer = sanitizer
        return await review.entries.map { entry in
            let context = SharedInboxReview.contextItem(entry)
            let state = ConnectionItemState.resolve(
                consent: context.consent, expiresAt: entry.item.expiresAt, now: now,
                flagged: sanitizer.isSuspicious(entry.displayText), reconfirmed: entry.isReconfirmed)
            return ConnectionItem(id: entry.id, integration: .shareInbox, title: context.title,
                                  state: state, expiresAt: entry.item.expiresAt)
        }
    }

    public func perform(_ action: ConnectionAction, on id: UUID) async throws {
        switch action {
        case .approve: try await review.setDecision(.approved, for: id)
        case .readAnyway:
            try await review.setDecision(.approved, for: id)
            try await review.reconfirm(id)
        case .revoke: try await review.setDecision(.excluded, for: id)
        case .delete: try await review.delete(id)
        case .review, .reselect, .allowAccess, .openSettings: break
        }
    }
}

/// Fixed items, for previews, tests and the debug test station. Not an integration.
public actor InMemoryConnectionItemProvider: ConnectionItemProvider {
    public nonisolated let integration: StationIntegration
    public private(set) var stored: [ConnectionItem]
    public private(set) var performed: [(ConnectionAction, UUID)] = []

    public init(integration: StationIntegration, items: [ConnectionItem]) {
        self.integration = integration
        self.stored = items
    }

    public func items(now: Date) async throws -> [ConnectionItem] { stored }

    public func perform(_ action: ConnectionAction, on id: UUID) async throws {
        performed.append((action, id))
        guard let i = stored.firstIndex(where: { $0.id == id }) else { return }
        let item = stored[i]
        func with(_ s: ConnectionItemState) -> ConnectionItem {
            ConnectionItem(id: item.id, integration: item.integration, title: item.title, state: s, expiresAt: item.expiresAt)
        }
        switch action {
        case .approve, .readAnyway: stored[i] = with(.approved)
        case .revoke: stored[i] = with(.revoked)
        case .delete: stored.remove(at: i)
        default: break
        }
    }
}

/// Fixed source state, for previews and tests.
public actor StaticConnectionSourceReader: ConnectionSourceReading {
    public private(set) var calendar: CalendarConnectionState
    public private(set) var obsidian: ObsidianSelectionState
    public private(set) var accessRequests = 0

    public init(calendar: CalendarConnectionState = .init(access: .notDetermined),
                obsidian: ObsidianSelectionState = .notSelected) {
        self.calendar = calendar
        self.obsidian = obsidian
    }

    public func calendarState() async -> CalendarConnectionState { calendar }
    public func obsidianSelection() async -> ObsidianSelectionState { obsidian }
    public func requestCalendarAccess() async -> CalendarAccess { accessRequests += 1; return calendar.access }
    public func setSelectedCalendars(_ ids: Set<String>) async throws { calendar.selectedCalendarIDs = ids }
    public func clearSelection(_ integration: StationIntegration) async throws {
        switch integration {
        case .calendar: calendar.selectedCalendarIDs = []
        case .obsidian: obsidian = .notSelected
        case .shareInbox: break
        }
    }
}

// MARK: - Model

public enum ConnectionActionError: Error, Equatable, Sendable {
    /// The action isn't offered for the item's current state.
    case notAllowed
    case unknownItem
    /// The provider failed. For revoke/delete, narration was already purged.
    case failed
}

/// Connections read model and intents for the Studio. Create once at app/scene level.
@MainActor @Observable
public final class ConnectionsModel {
    public private(set) var calendar = CalendarConnectionState(access: .notDetermined)
    public private(set) var obsidian: ObsidianSelectionState = .notSelected
    public private(set) var items: [ConnectionItem] = []
    public private(set) var isRefreshing = false
    public private(set) var lastError: ConnectionActionError?

    @ObservationIgnored private let station: StationConfigurationModel
    @ObservationIgnored private let sourceReader: any ConnectionSourceReading
    @ObservationIgnored private let providers: [StationIntegration: any ConnectionItemProvider]
    @ObservationIgnored private let purger: any NarrationPurging
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var purged: Set<UUID> = []

    public init(station: StationConfigurationModel, sourceReader: any ConnectionSourceReading,
                providers: [any ConnectionItemProvider], purger: any NarrationPurging,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.station = station
        self.sourceReader = sourceReader
        self.providers = Dictionary(providers.map { ($0.integration, $0) }, uniquingKeysWith: { a, _ in a })
        self.purger = purger
        self.now = now
    }

    // MARK: Read model

    public var sources: [ConnectionSourceRow] {
        [StationIntegration.calendar, .obsidian, .shareInbox].map(source)
    }

    public func source(_ integration: StationIntegration) -> ConnectionSourceRow {
        let detail: ConnectionSourceRow.Detail = switch integration {
        case .calendar: .calendar(calendar)
        case .obsidian: .obsidian(obsidian)
        case .shareInbox: .sharedImports(SharedImportsState(
            waitingForReview: items(for: .shareInbox).filter { $0.state == .pendingApproval || $0.state == .flaggedForReview }.count,
            approved: items(for: .shareInbox).filter { $0.state == .approved }.count))
        }
        return ConnectionSourceRow(integration: integration, status: station.integrationStatus(integration), detail: detail)
    }

    public func items(for integration: StationIntegration) -> [ConnectionItem] {
        items.filter { $0.integration == integration }
    }

    // MARK: Intents

    /// Re-reads consent, source state and items, and purges narration that may no longer be used
    /// *before* the new state is exposed. Only narratable items keep their narration
    /// (`isNarratable`): everything else known before or after the re-read is purged. That covers
    /// items that are gone (permission removed in Settings, calendar deselected, file missing,
    /// provider read failed: fail closed), expired, revoked or unavailable; items demoted to
    /// pending approval or flagged for review under the same ID; and items whose integration
    /// consent is no longer granted. Narratable items leave `purged`, so a later demotion or
    /// withdrawal purges again: re-authorization leaves no stale purge state.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let previous = items
        await station.refreshConsent()
        let nextCalendar = await sourceReader.calendarState()
        let nextObsidian = await sourceReader.obsidianSelection()
        var next: [ConnectionItem] = []
        let current = now()
        for integration in [StationIntegration.calendar, .obsidian, .shareInbox] {
            guard let provider = providers[integration] else { continue }
            if let list = try? await provider.items(now: current) { next += list }
        }
        let narratable = Set(next.filter { isNarratable($0) }.map(\.id))
        let known = Set(previous.map(\.id)).union(next.map(\.id))
        await purge(known.subtracting(narratable).subtracting(purged))
        purged.subtract(narratable)
        calendar = nextCalendar
        obsidian = nextObsidian
        items = next
    }

    /// May feed narration: approved by the listener *and* its integration's consent granted.
    /// Deliberately stricter than what the list shows: pending and flagged items stay visible
    /// so they can be reviewed, but nothing derived from them may be spoken.
    func isNarratable(_ item: ConnectionItem) -> Bool {
        guard station.consent[item.integration] == .granted else { return false }
        if case .approved = item.state { return true }
        return false
    }

    /// Performs an item action. Revoke and delete purge cached narration and prepared breaks
    /// *before* the provider runs, so a provider failure can never leave narratable audio.
    @discardableResult
    public func perform(_ action: ConnectionAction, on id: UUID) async -> Result<Void, ConnectionActionError> {
        guard let item = items.first(where: { $0.id == id }) else { return fail(.unknownItem) }
        guard item.actions.contains(action) else { return fail(.notAllowed) }
        if action.purgesNarration { await purge([id]) }
        guard let provider = providers[item.integration] else { return fail(.failed) }
        do {
            try await provider.perform(action, on: id)
        } catch {
            await refresh()
            return fail(.failed)
        }
        lastError = nil
        await refresh()
        return .success(())
    }

    /// Source-level actions: allow calendar access, or stop using a source's selection.
    /// `reselect` and `openSettings` are UI navigation (picker / Settings) followed by `refresh()`.
    @discardableResult
    public func perform(_ action: ConnectionAction, onSource integration: StationIntegration) async -> Result<Void, ConnectionActionError> {
        guard source(integration).actions.contains(action) else { return fail(.notAllowed) }
        switch action {
        case .allowAccess:
            _ = await sourceReader.requestCalendarAccess()
        case .revoke:
            await purge(Set(items(for: integration).map(\.id)))
            do { try await sourceReader.clearSelection(integration) } catch { await refresh(); return fail(.failed) }
        default:
            break
        }
        lastError = nil
        await refresh()
        return .success(())
    }

    /// Saves the calendars the user picked (only from `calendar.calendars`).
    @discardableResult
    public func selectCalendars(_ ids: Set<String>) async -> Result<Void, ConnectionActionError> {
        guard calendar.access == .fullAccess else { return fail(.notAllowed) }
        let allowed = ids.intersection(calendar.calendars.map(\.id))
        let dropped = calendar.selectedCalendarIDs.subtracting(allowed)
        if !dropped.isEmpty { await purge(Set(items(for: .calendar).map(\.id))) }
        do { try await sourceReader.setSelectedCalendars(allowed) } catch { return fail(.failed) }
        lastError = nil
        await refresh()
        return .success(())
    }

    /// Feed `StationConfigurationModel.changes()` here: a withdrawn integration purges
    /// everything derived from its items immediately.
    public func handle(_ change: StationConfigurationChange) async {
        let withdrawn = change.withdrawnIntegrations
        guard !withdrawn.isEmpty else { return }
        await purge(Set(items.filter { withdrawn.contains($0.integration) }.map(\.id)))
    }

    // MARK: Internals

    private func purge(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        await purger.purge(sourceItemIDs: ids)
        purged.formUnion(ids)
    }

    private func fail(_ error: ConnectionActionError) -> Result<Void, ConnectionActionError> {
        lastError = error
        return .failure(error)
    }
}
