import XCTest
@testable import AeroDJCore

/// EventKit stand-in: access is whatever the "user" answered; one event per calendar today.
private actor FakeCalendar: CalendarEventReading {
    var current: CalendarAccess
    var answer: CalendarAccess
    private(set) var requests = 0
    let now: Date
    init(access: CalendarAccess, answer: CalendarAccess = .fullAccess, now: Date) {
        current = access; self.answer = answer; self.now = now
    }
    func access() async -> CalendarAccess { current }
    func calendars() async -> [CalendarDescriptor] {
        current == .fullAccess ? [.init(id: "work", title: "Work"), .init(id: "home", title: "Home")] : []
    }
    func requestFullAccess() async throws -> CalendarAccess { requests += 1; current = answer; return answer }
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEventSnapshot] {
        ["work", "home"].filter { calendarIDs?.contains($0) ?? true }.map {
            CalendarEventSnapshot(calendarItemID: "evt-\($0)", occurrenceDate: now.addingTimeInterval(3600),
                                  title: "Standup \($0)", start: now.addingTimeInterval(3600),
                                  end: now.addingTimeInterval(5400), isAllDay: false, calendarID: $0)
        }
    }
}

/// Bookmark stand-in: the "bookmark" bytes are a key into this dictionary.
private struct FakeFiles: SecurityScopedFileReading {
    let files: [String: String]
    func read(bookmark: Data) async throws -> (data: Data, renewedBookmark: Data?) {
        guard let text = files[String(decoding: bookmark, as: UTF8.self)] else { throw MarkdownReadError.notFound }
        return (Data(text.utf8), nil)
    }
}

private actor PurgeLog: NarrationPurging {
    var ids: Set<UUID> = []
    func purge(sourceItemIDs: Set<UUID>) async { ids.formUnion(sourceItemIDs) }
}

@MainActor
final class LiveConnectionsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func station(consent: any IntegrationConsentReading) async -> StationConfigurationModel {
        var config = StationConfiguration.sampleMorningMix
        config.requestedIntegrations = Set(StationIntegration.allCases)
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))), consent: consent)
        await model.load()
        return model
    }

    func testCalendarConsentFollowsRealAccessAndSelection() async throws {
        let now = self.now
        let cal = FakeCalendar(access: .notDetermined, now: now)
        let sources = LiveConnectionSources(calendar: cal, files: nil, store: InMemoryConnectionChoicesStore(),
                                            shareInboxAvailable: false)
        var state = await sources.consentState(for: .calendar)
        XCTAssertEqual(state, .notRequested)
        let v1 = await sources.calendarState().actions
        XCTAssertEqual(v1, [.allowAccess])

        let v2 = await sources.requestCalendarAccess()

        XCTAssertEqual(v2, .fullAccess)
        state = await sources.consentState(for: .calendar)
        XCTAssertEqual(state, .notRequested, "access alone reads nothing: no calendar is chosen yet")
        try await sources.setSelectedCalendars(["work"])
        state = await sources.consentState(for: .calendar)
        XCTAssertEqual(state, .granted)
        let v3 = await sources.calendarState().selectedCalendarIDs
        XCTAssertEqual(v3, ["work"])

        let chosen = ChosenCalendarContextSource(reader: cal, sources: sources, now: { now })
        let items = try await chosen.fetchItems()
        XCTAssertEqual(items.map(\.title), ["Standup work"], "only the opted-in calendar is read")

        try await sources.clearSelection(.calendar)
        state = await sources.consentState(for: .calendar)
        XCTAssertEqual(state, .revoked)
        let after = try await chosen.fetchItems()
        XCTAssertTrue(after.isEmpty)
    }

    func testDeniedAndUnavailableCalendar() async {
        let now = self.now
        let denied = LiveConnectionSources(calendar: FakeCalendar(access: .denied, now: now), files: nil,
                                           store: InMemoryConnectionChoicesStore(), shareInboxAvailable: false)
        let deniedConsent = await denied.consentState(for: .calendar)
        XCTAssertEqual(deniedConsent, .denied)
        let v4 = await denied.calendarState().actions
        XCTAssertEqual(v4, [.openSettings])
        let none = LiveConnectionSources(calendar: nil, files: nil, store: InMemoryConnectionChoicesStore(),
                                         shareInboxAvailable: false)
        let v5 = await none.calendarState().access
        XCTAssertEqual(v5, .restricted)
        let v6 = await none.requestCalendarAccess()
        XCTAssertEqual(v6, .restricted)
        XCTAssertFalse(none.canPickNotes)
    }

    func testPickedNotesUseTheParserAndNeedApproval() async throws {
        let now = self.now
        let files = FakeFiles(files: ["a": "# Groceries\n- [ ] oat milk\n- [x] bread", "b": "---\nprivate: true\n---\nSecret"])
        let sources = LiveConnectionSources(calendar: nil, files: files, store: InMemoryConnectionChoicesStore(),
                                            shareInboxAvailable: false)
        let v7 = await sources.obsidianSelection()
        XCTAssertEqual(v7, .notSelected)
        try await sources.addNotes([PickedNote(fileName: "Groceries.md", bookmark: Data("a".utf8)),
                                    PickedNote(fileName: "Diary.md", bookmark: Data("b".utf8))])
        let v8 = await sources.obsidianSelection()
        XCTAssertEqual(v8, .valid(fileCount: 2))
        let consent = await sources.consentState(for: .obsidian)
        XCTAssertEqual(consent, .granted)

        let provider = PickedNotesConnectionProvider(sources: sources)
        let items = try await provider.items(now: now)
        let note = try XCTUnwrap(items.first { $0.title == "Groceries" })
        XCTAssertEqual(note.state, .pendingApproval)
        XCTAssertEqual(items.first { $0.title == "Diary.md" }?.state, .unavailable(.file(.optedOut)),
                       "#38 parser honours private: true")

        let briefing = ApprovedNotesContextSource(sources: sources)
        var narratable = try await briefing.fetchItems()
        XCTAssertTrue(narratable.isEmpty, "nothing is narratable before approval")
        try await provider.perform(.approve, on: note.id)
        narratable = try await briefing.fetchItems()
        XCTAssertEqual(narratable.map(\.id), [note.id])
        XCTAssertEqual(narratable.first?.consent, .granted)
        XCTAssertTrue(narratable.first?.summary.contains("oat milk") ?? false)
    }

    func testMissingFileIsReportedNotRead() async throws {
        let now = self.now
        let sources = LiveConnectionSources(calendar: nil, files: FakeFiles(files: [:]),
                                            store: InMemoryConnectionChoicesStore(), shareInboxAvailable: false)
        try await sources.addNotes([PickedNote(fileName: "Gone.md", bookmark: Data("x".utf8))])
        let v9 = await sources.obsidianSelection()
        XCTAssertEqual(v9, .missing)
    }

    /// Revoking a source purges every narration derived from it (prepared breaks and cached
    /// audio, through `NarrationPurger`) before the choice is forgotten, and nothing from it
    /// is read again.
    func testRevokingCalendarPurgesCachedAudioThenStopsReading() async throws {
        let now = self.now
        let cal = FakeCalendar(access: .fullAccess, now: now)
        let sources = LiveConnectionSources(calendar: cal, files: nil, store: InMemoryConnectionChoicesStore(),
                                            shareInboxAvailable: false)
        try await sources.setSelectedCalendars(["work", "home"])
        let chosen = ChosenCalendarContextSource(reader: cal, sources: sources, now: { now })
        let items = try await chosen.fetchItems()
        XCTAssertEqual(items.count, 2)

        let cache = InMemoryAudioCache(now: { now })
        await cache.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v",
                                      sourceItemIDs: [items[0].id], createdAt: now), for: "break-1")
        await cache.store(CachedAudio(data: Data([2]), seconds: 1, providerID: "device", voiceID: "v",
                                      sourceItemIDs: [], createdAt: now), for: "plain")
        let model = ConnectionsModel(station: await station(consent: sources), sourceReader: sources,
                                     providers: [CalendarConnectionProvider(source: chosen)],
                                     purger: NarrationPurger(cache: cache, preparer: nil), now: { now })
        await model.refresh()
        XCTAssertEqual(Set(model.items(for: .calendar).map(\.id)), Set(items.map(\.id)))
        XCTAssertTrue(model.source(.calendar).actions.contains(.revoke))

        _ = try await model.perform(.revoke, onSource: .calendar).get()
        let purged = await cache.audio(for: "break-1")
        let kept = await cache.audio(for: "plain")
        XCTAssertNil(purged, "narration derived from the calendar is gone before future playback")
        XCTAssertNotNil(kept, "unrelated audio stays")
        XCTAssertTrue(model.items(for: .calendar).isEmpty)
        let consent = await sources.consentState(for: .calendar)
        XCTAssertEqual(consent, .revoked)
        let reread = try await chosen.fetchItems()
        XCTAssertTrue(reread.isEmpty)
    }

    func testRevokingNotesPurgesTheirIDs() async throws {
        let now = self.now
        let sources = LiveConnectionSources(calendar: nil, files: FakeFiles(files: ["a": "# Plan\nCall the bank."]),
                                            store: InMemoryConnectionChoicesStore(), shareInboxAvailable: false)
        try await sources.addNotes([PickedNote(fileName: "Plan.md", bookmark: Data("a".utf8))])
        let log = PurgeLog()
        let model = ConnectionsModel(station: await station(consent: sources), sourceReader: sources,
                                     providers: [PickedNotesConnectionProvider(sources: sources)], purger: log, now: { now })
        await model.refresh()
        let id = try XCTUnwrap(model.items(for: .obsidian).first?.id)
        _ = try await model.perform(.revoke, onSource: .obsidian).get()
        let ids = await log.ids
        XCTAssertEqual(ids, [id])
        XCTAssertEqual(model.obsidian, .notSelected)
        let consent = await sources.consentState(for: .obsidian)
        XCTAssertEqual(consent, .revoked)
    }

    func testChoicesPersistToFileWithoutContent() async throws {
        let now = self.now
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("choices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileConnectionChoicesStore(fileURL: url)
        let empty = try await store.load()
        XCTAssertEqual(empty, ConnectionChoices())
        let sources = LiveConnectionSources(calendar: nil, files: FakeFiles(files: ["a": "# Secret plan\nbody text"]),
                                            store: store, shareInboxAvailable: false)
        try await sources.addNotes([PickedNote(fileName: "Plan.md", bookmark: Data("a".utf8))])
        _ = try await PickedNotesConnectionProvider(sources: sources).items(now: now)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("Secret plan") || raw.contains("body text"), "note text is never stored")
        let reloaded = try await FileConnectionChoicesStore(fileURL: url).load()
        XCTAssertEqual(reloaded.notes.map(\.fileName), ["Plan.md"])
    }

    /// The test station must never construct a real private source.
    func testFixtureModeNeverCallsLiveFactories() async {
        let now = self.now
        final class Calls: @unchecked Sendable { var names: [String] = [] }
        let calls = Calls()
        let live = ConnectionsComposition.LiveFactories(
            calendar: { calls.names.append("calendar"); return nil },
            files: { calls.names.append("files"); return nil },
            store: { calls.names.append("store"); return InMemoryConnectionChoicesStore() },
            shareInbox: { calls.names.append("shareInbox"); return [] })
        let fixtures = ConnectionsComposition.make(mode: .testStation, live: live,
                                                              testStation: .testStationFixtures(TestStationFixtures(now: now)))
        XCTAssertEqual(calls.names, [], "no EventKit, bookmark, choices file or inbox in the test station")
        XCTAssertNil(fixtures.notes)
        XCTAssertTrue(fixtures.sourceReader is StaticConnectionSourceReader)
        XCTAssertFalse(fixtures.contextSources.contains { $0 is ChosenCalendarContextSource || $0 is ApprovedNotesContextSource })
        var provenance: [String] = []
        for source in fixtures.contextSources { provenance += ((try? await source.fetchItems()) ?? []).map(\.provenance) }
        XCTAssertFalse(provenance.isEmpty)
        XCTAssertTrue(provenance.allSatisfy { $0.hasPrefix(TestStation.provenancePrefix) }, "fixtures only")

        _ = ConnectionsComposition.make(mode: .live, live: live)
        XCTAssertEqual(calls.names, ["calendar", "files", "shareInbox", "store"])
    }

    func testLiveCompositionOnlyAddsAvailableSources() {
        let now = self.now
        let live = ConnectionsComposition.make(
            mode: .live,
            live: .init(calendar: { FakeCalendar(access: .notDetermined, now: now) }, files: { nil },
                        store: { InMemoryConnectionChoicesStore() }, shareInbox: { [] }),
        )
        XCTAssertNil(live.notes, "no file reader, no picker")
        XCTAssertEqual(live.providers.map(\.integration), [.calendar])
        XCTAssertEqual(live.contextSources.map(\.source), [.calendar])
    }
}

