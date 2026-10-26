import Foundation

// Live Connections: the user's own choices (calendars they opted in, Markdown files they
// picked) and the consent derived from them. Nothing here reads a mailbox, a vault or a
// calendar the user didn't choose. The app supplies the OS boundaries: EventKit
// (`CalendarEventReading`) and security-scoped bookmarks (`SecurityScopedFileReading`).
//
// Revocation order is ConnectionsModel's: narration derived from the source is purged first
// (`NarrationPurging`), then the choice is forgotten here, so consent reads `.revoked` and
// the context sources below return nothing for that source again.

/// One Markdown file the user picked with the system file picker. Only the bookmark and
/// the file name are stored; the note's text is read when needed and never persisted.
public struct PickedNote: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let fileName: String
    public var bookmark: Data

    public init(id: UUID = UUID(), fileName: String, bookmark: Data) {
        self.id = id
        self.fileName = fileName
        self.bookmark = bookmark
    }

    /// Path handed to `ObsidianContextSource` (keeps the `.md` extension check meaningful).
    var path: String { "\(id.uuidString)/\(fileName)" }
}

/// What the user chose in Connections. Choices only, no content.
public struct ConnectionChoices: Codable, Equatable, Sendable {
    public var calendarIDs: Set<String>
    public var notes: [PickedNote]
    /// Note items the user approved / turned off in the review list.
    public var approvedNoteItems: Set<UUID>
    public var revokedNoteItems: Set<UUID>
    /// Sources the user stopped using (shown as "Revoked" until they choose again).
    public var revokedSources: Set<StationIntegration>

    public init(calendarIDs: Set<String> = [], notes: [PickedNote] = [], approvedNoteItems: Set<UUID> = [],
                revokedNoteItems: Set<UUID> = [], revokedSources: Set<StationIntegration> = []) {
        self.calendarIDs = calendarIDs
        self.notes = notes
        self.approvedNoteItems = approvedNoteItems
        self.revokedNoteItems = revokedNoteItems
        self.revokedSources = revokedSources
    }
}

public protocol ConnectionChoicesStore: Sendable {
    func load() async throws -> ConnectionChoices
    func save(_ choices: ConnectionChoices) async throws
}

public actor InMemoryConnectionChoicesStore: ConnectionChoicesStore {
    private var choices: ConnectionChoices
    public init(_ choices: ConnectionChoices = .init()) { self.choices = choices }
    public func load() async throws -> ConnectionChoices { choices }
    public func save(_ choices: ConnectionChoices) async throws { self.choices = choices }
}

/// JSON file in Application Support. A missing file is "nothing chosen".
public actor FileConnectionChoicesStore: ConnectionChoicesStore {
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() async throws -> ConnectionChoices {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .init() }
        return try JSONDecoder().decode(ConnectionChoices.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ choices: ConnectionChoices) async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(choices).write(to: fileURL, options: .atomic)
    }
}

/// Reads one picked file through its security-scoped bookmark (app target). Throws
/// `MarkdownReadError`. Returns a renewed bookmark when the system reports it stale but
/// still resolvable.
public protocol SecurityScopedFileReading: Sendable {
    func read(bookmark: Data) async throws -> (data: Data, renewedBookmark: Data?)
}

/// The live `ConnectionSourceReading` and `IntegrationConsentReading`: one object, so the
/// Connections screen and the station's consent can never disagree.
public actor LiveConnectionSources: ConnectionSourceReading, IntegrationConsentReading {
    private let calendar: (any CalendarEventReading)?
    private let files: (any SecurityScopedFileReading)?
    private let store: any ConnectionChoicesStore
    private let shareInboxAvailable: Bool
    private var cached: ConnectionChoices?

    /// `calendar` / `files` nil: that source is unavailable on this device or build.
    public init(calendar: (any CalendarEventReading)?, files: (any SecurityScopedFileReading)?,
                store: any ConnectionChoicesStore, shareInboxAvailable: Bool) {
        self.calendar = calendar
        self.files = files
        self.store = store
        self.shareInboxAvailable = shareInboxAvailable
    }

    public nonisolated var canPickNotes: Bool { files != nil }

    // MARK: ConnectionSourceReading

    public func calendarState() async -> CalendarConnectionState {
        guard let calendar else { return .init(access: .restricted) }
        let access = await calendar.access()
        guard access == .fullAccess else { return .init(access: access) }
        let calendars = await calendar.calendars()
        let selected = await choices().calendarIDs.intersection(calendars.map(\.id))
        return .init(access: access, calendars: calendars, selectedCalendarIDs: selected)
    }

    public func obsidianSelection() async -> ObsidianSelectionState {
        let notes = await choices().notes
        guard !notes.isEmpty else { return .notSelected }
        guard files != nil else { return .missing }
        var readable = 0
        var firstError: MarkdownReadError?
        for note in notes {
            do { _ = try await readNote(note); readable += 1 } catch let e as MarkdownReadError {
                firstError = firstError ?? e
            } catch { firstError = firstError ?? .accessDenied }
        }
        if readable == notes.count { return .valid(fileCount: readable) }
        return ObsidianSelectionState(readError: firstError ?? .notFound)
    }

    public func requestCalendarAccess() async -> CalendarAccess {
        guard let calendar else { return .restricted }
        if let granted = try? await calendar.requestFullAccess() { return granted }
        return await calendar.access()
    }

    public func setSelectedCalendars(_ ids: Set<String>) async throws {
        var c = await choices()
        c.calendarIDs = ids
        if !ids.isEmpty { c.revokedSources.remove(.calendar) }
        try await save(c)
    }

    public func clearSelection(_ integration: StationIntegration) async throws {
        var c = await choices()
        switch integration {
        case .calendar:
            c.calendarIDs = []
        case .obsidian:
            c.notes = []
            c.approvedNoteItems = []
            c.revokedNoteItems = []
        case .shareInbox:
            break   // shared items are approved and revoked one by one
        }
        c.revokedSources.insert(integration)
        try await save(c)
    }

    // MARK: Notes

    /// Adds files the user just picked. Same file name replaces the earlier pick.
    public func addNotes(_ picked: [PickedNote]) async throws {
        var c = await choices()
        let names = Set(picked.map(\.fileName))
        c.notes = c.notes.filter { !names.contains($0.fileName) } + picked
        c.revokedSources.remove(.obsidian)
        try await save(c)
    }

    func notePaths() async -> [String] { await choices().notes.map(\.path) }

    func readNote(path: String) async throws -> Data {
        guard let note = await choices().notes.first(where: { $0.path == path }) else { throw MarkdownReadError.notFound }
        return try await readNote(note)
    }

    private func readNote(_ note: PickedNote) async throws -> Data {
        guard let files else { throw MarkdownReadError.accessDenied }
        let result = try await files.read(bookmark: note.bookmark)
        if let renewed = result.renewedBookmark {
            var c = await choices()
            if let i = c.notes.firstIndex(where: { $0.id == note.id }) { c.notes[i].bookmark = renewed; try? await save(c) }
        }
        return result.data
    }

    func setNoteItem(_ id: UUID, approved: Bool) async throws {
        var c = await choices()
        if approved { c.approvedNoteItems.insert(id); c.revokedNoteItems.remove(id) }
        else { c.approvedNoteItems.remove(id); c.revokedNoteItems.insert(id) }
        try await save(c)
    }

    func noteConsent(_ id: UUID) async -> ConsentState {
        let c = await choices()
        if c.approvedNoteItems.contains(id) { return .granted }
        if c.revokedNoteItems.contains(id) { return .revoked }
        return .notRequested
    }

    // MARK: IntegrationConsentReading

    public func consentState(for integration: StationIntegration) async -> ConsentState {
        let c = await choices()
        switch integration {
        case .calendar:
            guard let calendar else { return .denied }
            switch await calendar.access() {
            case .fullAccess:
                if !c.calendarIDs.isEmpty { return .granted }
            case .denied, .restricted, .writeOnly:
                return .denied
            case .notDetermined:
                break
            }
            return c.revokedSources.contains(.calendar) ? .revoked : .notRequested
        case .obsidian:
            if !c.notes.isEmpty { return .granted }
            return c.revokedSources.contains(.obsidian) ? .revoked : .notRequested
        case .shareInbox:
            // Only what the user shared; each item still needs its own approval.
            return shareInboxAvailable ? .granted : .notRequested
        }
    }

    /// The calendar policy for briefings right now: only opted-in calendars, and consent
    /// only while access is full and at least one calendar is chosen.
    public func calendarPolicy() async -> CalendarSourcePolicy {
        let consent = await consentState(for: .calendar)
        return CalendarSourcePolicy(includedCalendarIDs: consent == .granted ? await choices().calendarIDs : [],
                                    consent: consent)
    }

    // MARK: Storage

    private func choices() async -> ConnectionChoices {
        if let cached { return cached }
        let loaded = (try? await store.load()) ?? .init()
        cached = loaded
        return loaded
    }

    private func save(_ c: ConnectionChoices) async throws {
        try await store.save(c)
        cached = c
    }
}

// MARK: - Context sources and providers over the live choices

/// `MarkdownDocumentReader` over the picked files only.
public struct PickedNotesReader: MarkdownDocumentReader {
    let sources: LiveConnectionSources
    public init(sources: LiveConnectionSources) { self.sources = sources }
    public func selectedPaths() async throws -> [String] { await sources.notePaths() }
    public func read(relativePath: String) async throws -> Data { try await sources.readNote(path: relativePath) }
}

/// Calendar context for briefings, re-reading the user's calendar choice on every fetch.
public struct ChosenCalendarContextSource: ContextSource {
    public let source: ContextSourceKind = .calendar
    let reader: any CalendarEventReading
    let sources: LiveConnectionSources
    let now: @Sendable () -> Date

    public init(reader: any CalendarEventReading, sources: LiveConnectionSources,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.sources = sources
        self.now = now
    }

    public func fetchItems() async throws -> [ContextItem] {
        let policy = await sources.calendarPolicy()
        guard policy.consent == .granted, !policy.includedCalendarIDs.isEmpty else { return [] }
        return try await CalendarContextSource(reader: reader, policy: policy, now: now).fetchItems()
    }
}

/// Picked notes for briefings: only items the user approved in Connections.
public struct ApprovedNotesContextSource: ContextSource {
    public let source: ContextSourceKind = .obsidian
    let sources: LiveConnectionSources
    public init(sources: LiveConnectionSources) { self.sources = sources }

    public func fetchItems() async throws -> [ContextItem] {
        var out: [ContextItem] = []
        for item in try await ObsidianContextSource(reader: PickedNotesReader(sources: sources)).fetchItems()
        where await sources.noteConsent(item.id) == .granted {
            out.append(ContextItem(id: item.id, source: item.source, createdAt: item.createdAt, eventAt: item.eventAt,
                                   title: item.title, summary: item.summary, sensitivity: item.sensitivity,
                                   consent: .granted, expiresAt: item.expiresAt, provenance: item.provenance))
        }
        return out
    }
}

/// Today's events from the chosen calendars, listed in Connections so the user sees exactly
/// what may be mentioned (and so revoking the calendar purges their narration by ID).
public struct CalendarConnectionProvider: ConnectionItemProvider {
    public let integration: StationIntegration = .calendar
    let source: ChosenCalendarContextSource
    public init(source: ChosenCalendarContextSource) { self.source = source }

    public func items(now: Date) async throws -> [ConnectionItem] {
        try await source.fetchItems().map {
            ConnectionItem(id: $0.id, integration: .calendar, title: $0.title.isEmpty ? "Event" : $0.title,
                           state: ConnectionItemState.resolve(consent: $0.consent, expiresAt: $0.expiresAt, now: now,
                                                              flagged: false, reconfirmed: false),
                           expiresAt: $0.expiresAt)
        }
    }

    /// Calendar is chosen per calendar, not per event.
    public func perform(_ action: ConnectionAction, on id: UUID) async throws {
        throw ConnectionActionError.notAllowed
    }
}

/// Picked notes in Connections: each starts waiting for approval; skipped files show why.
public struct PickedNotesConnectionProvider: ConnectionItemProvider {
    public let integration: StationIntegration = .obsidian
    let sources: LiveConnectionSources
    public init(sources: LiveConnectionSources) { self.sources = sources }

    public func items(now: Date) async throws -> [ConnectionItem] {
        let result = try await ObsidianContextSource(reader: PickedNotesReader(sources: sources)).importNotes()
        var out: [ConnectionItem] = []
        for item in result.items {
            let consent = await sources.noteConsent(item.id)
            out.append(ConnectionItem(id: item.id, integration: .obsidian,
                                      title: item.title.isEmpty ? String(item.summary.prefix(40)) : item.title,
                                      state: .resolve(consent: consent, expiresAt: nil, now: now, flagged: false, reconfirmed: false)))
        }
        for (path, reason) in result.skipped.sorted(by: { $0.key < $1.key }) {
            out.append(ConnectionItem(id: ObsidianContextSource.stableID(for: "skipped:" + path), integration: .obsidian,
                                      title: (path as NSString).lastPathComponent, state: .unavailable(.file(reason))))
        }
        return out
    }

    public func perform(_ action: ConnectionAction, on id: UUID) async throws {
        switch action {
        case .approve, .readAnyway: try await sources.setNoteItem(id, approved: true)
        case .revoke: try await sources.setNoteItem(id, approved: false)
        default: throw ConnectionActionError.notAllowed
        }
    }
}

// MARK: - Composition

/// Everything Connections and briefings need, for one runtime mode. The composition root
/// calls `make` for both modes, so the rule "the test station never constructs a real private
/// source" is enforced (and tested) here: in `.testStation` the live factories are never
/// called: no EventKit store, no bookmark reader, no choices file, no share inbox.
public struct ConnectionsComposition: Sendable {
    public let sourceReader: any ConnectionSourceReading
    public let consent: any IntegrationConsentReading
    public let providers: [any ConnectionItemProvider]
    public let contextSources: [any ContextSource]
    /// Non-nil only in live mode with a file reader: the app may offer the file picker.
    public let notes: LiveConnectionSources?

    /// Live OS boundaries, created only when `make` runs in `.live`.
    public struct LiveFactories {
        public var calendar: () -> (any CalendarEventReading)?
        public var files: () -> (any SecurityScopedFileReading)?
        public var store: () -> any ConnectionChoicesStore
        public var shareInbox: () -> [any ConnectionItemProvider]

        public init(calendar: @escaping () -> (any CalendarEventReading)?,
                    files: @escaping () -> (any SecurityScopedFileReading)?,
                    store: @escaping () -> any ConnectionChoicesStore,
                    shareInbox: @escaping () -> [any ConnectionItemProvider]) {
            self.calendar = calendar
            self.files = files
            self.store = store
            self.shareInbox = shareInbox
        }

        /// No OS boundaries at all. For the test station, where `make` must not call them anyway.
        public static var unavailable: LiveFactories {
            LiveFactories(calendar: { nil }, files: { nil }, store: { InMemoryConnectionChoicesStore() }, shareInbox: { [] })
        }
    }

    /// Empty Connections: no sources, nothing granted. Used where no fixtures apply.
    public static var unavailable: ConnectionsComposition {
        ConnectionsComposition(
            sourceReader: StaticConnectionSourceReader(),
            consent: StaticIntegrationConsent(Dictionary(uniqueKeysWithValues: StationIntegration.allCases.map { ($0, ConsentState.notRequested) })),
            providers: [], contextSources: [], notes: nil)
    }

    /// `.testStation` returns the caller's fixture composition; the shared code never names the
    /// fixture type, so Release builds (which do not compile the test station) stay clean.
    public static func make(mode: AppRuntimeMode, live: LiveFactories,
                            testStation: @autoclosure () -> ConnectionsComposition = .unavailable) -> ConnectionsComposition {
        switch mode {
        case .testStation:
            return testStation()
        case .live:
            let calendar = live.calendar()
            let files = live.files()
            let inbox = live.shareInbox()
            let sources = LiveConnectionSources(calendar: calendar, files: files, store: live.store(),
                                                shareInboxAvailable: !inbox.isEmpty)
            var providers = inbox
            var context: [any ContextSource] = []
            if let calendar {
                let chosen = ChosenCalendarContextSource(reader: calendar, sources: sources)
                providers.append(CalendarConnectionProvider(source: chosen))
                context.append(chosen)
            }
            if files != nil {
                providers.append(PickedNotesConnectionProvider(sources: sources))
                context.append(ApprovedNotesContextSource(sources: sources))
            }
            return ConnectionsComposition(sourceReader: sources, consent: sources, providers: providers,
                                          contextSources: context, notes: files != nil ? sources : nil)
        }
    }
}
