import XCTest
@testable import AeroDJCore

// Regression for the P1 raised on #61 at 691937a: withdrawing OS permission in Settings
// (not via the in-app Revoke) must purge narration derived from previously approved items,
// before the refreshed state is exposed, and again after a re-grant. -Fry

/// EventKit stand-in whose access the "user" can change in Settings.
private actor SettingsCalendar: CalendarEventReading {
    var current: CalendarAccess
    let now: Date
    init(access: CalendarAccess, now: Date) { current = access; self.now = now }
    func set(_ access: CalendarAccess) { current = access }
    func access() async -> CalendarAccess { current }
    func calendars() async -> [CalendarDescriptor] { current == .fullAccess ? [.init(id: "work", title: "Work")] : [] }
    func requestFullAccess() async throws -> CalendarAccess { current }
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEventSnapshot] {
        guard current == .fullAccess else { return [] }
        return [CalendarEventSnapshot(calendarItemID: "evt-work", occurrenceDate: now.addingTimeInterval(3600),
                                      title: "Dentist", start: now.addingTimeInterval(3600),
                                      end: now.addingTimeInterval(5400), isAllDay: false, calendarID: "work")]
    }
}

private struct WordVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private actor KeyedCache: AudioCache {
    private let inner = InMemoryAudioCache()
    private var keys: [String] = []
    func audio(for key: String) async -> CachedAudio? { await inner.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async { keys.append(key); await inner.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func remaining() async -> [CachedAudio] {
        var out: [CachedAudio] = []
        for key in keys { if let a = await inner.audio(for: key) { out.append(a) } }
        return out
    }
}

/// Records each purge and what the model exposed at that moment.
@MainActor
private final class PurgeProbe: NarrationPurging, @unchecked Sendable {
    let inner: any NarrationPurging
    weak var model: ConnectionsModel?
    private(set) var calls: [Set<UUID>] = []
    private(set) var exposedDuringPurge: [Set<UUID>] = []
    init(_ inner: any NarrationPurging) { self.inner = inner }
    nonisolated func purge(sourceItemIDs: Set<UUID>) async {
        await record(sourceItemIDs)
        await inner.purge(sourceItemIDs: sourceItemIDs)
    }
    private func record(_ ids: Set<UUID>) {
        calls.append(ids)
        exposedDuringPurge.append(Set(model?.items.map(\.id) ?? []))
    }
}

/// Approved items until `failing`, then every read throws.
private actor FlakyProvider: ConnectionItemProvider {
    nonisolated let integration: StationIntegration = .obsidian
    let item: ConnectionItem
    var failing = false
    init(item: ConnectionItem) { self.item = item }
    func fail() { failing = true }
    func items(now: Date) async throws -> [ConnectionItem] {
        if failing { throw MarkdownReadError.accessDenied }
        return [item]
    }
    func perform(_ action: ConnectionAction, on id: UUID) async throws {}
}

@MainActor
final class ConsentWithdrawalTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func until(_ condition: @MainActor () -> Bool, _ message: String = "") async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func cue(for id: UUID) -> NarrationCue {
        NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: "Later today: Dentist at four.",
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: id, source: .calendar, provenance: "test:evt")
    }

    /// Prepares a break that uses `id`, and waits until it is ready.
    private func prepare(_ session: DJBreakSession, dj: DJPresentationStore, using id: UUID) async {
        await session.queueStarted(djTracks(12), briefing: NarrationHandoff(cues: [cue(for: id)], maxSpokenSeconds: 60,
                                                                           experienceSeconds: 600))
        await session.songStarted(index: 0, remaining: .seconds(180))
        await until({ if case .ready(true, _) = dj.studioState { true } else { false } }, "break with the event is prepared")
    }

    private func narrates(_ id: UUID, session: DJBreakSession, cache: KeyedCache) async -> Bool {
        let cached = await cache.remaining().contains { $0.sourceItemIDs.contains(id) }
        let prepared = await session.naturalBoundary(afterTrack: 0)
        return cached || (prepared?.cues.contains { $0.sourceItemID == id } ?? false)
    }

    func testWithdrawingCalendarPermissionInSettingsPurgesBeforeExposingNewStateAndAgainAfterRegrant() async throws {
        let now = self.now
        let cal = SettingsCalendar(access: .fullAccess, now: now)
        let sources = LiveConnectionSources(calendar: cal, files: nil, store: InMemoryConnectionChoicesStore(),
                                            shareInboxAvailable: false)
        try await sources.setSelectedCalendars(["work"])
        let chosen = ChosenCalendarContextSource(reader: cal, sources: sources, now: { now })

        var config = StationConfiguration(commentary: .frequent)
        config.requestedIntegrations = [.calendar]
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))), consent: sources)
        await station.load()
        let cache = KeyedCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: WordVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await session.start()
        let probe = PurgeProbe(NarrationPurger(cache: cache, preparer: preparer, session: session))
        let connections = ConnectionsModel(station: station, sourceReader: sources,
                                           providers: [CalendarConnectionProvider(source: chosen)],
                                           purger: probe, now: { now })
        probe.model = connections

        await connections.refresh()
        let event = try XCTUnwrap(connections.items(for: .calendar).first)
        XCTAssertEqual(event.state, .approved)
        await prepare(session, dj: dj, using: event.id)

        // 1. Permission turned off in Settings; the listener comes back to the app.
        await cal.set(.denied)
        await connections.refresh()
        XCTAssertEqual(station.consent[.calendar], .denied)
        XCTAssertTrue(connections.items(for: .calendar).isEmpty)
        XCTAssertEqual(probe.calls.last, [event.id], "the previously approved event is purged")
        XCTAssertTrue(probe.exposedDuringPurge.last?.contains(event.id) ?? false,
                      "purged before the refreshed (empty) state was exposed")
        let afterWithdrawal = await narrates(event.id, session: session, cache: cache)
        XCTAssertFalse(afterWithdrawal, "nothing narratable from the event remains in cache, preparer or session")

        // 2. Re-grant, prepare again, withdraw again: the second withdrawal purges too.
        await cal.set(.fullAccess)
        await connections.refresh()
        XCTAssertEqual(connections.items(for: .calendar).map(\.id), [event.id])
        await prepare(session, dj: dj, using: event.id)
        let purgesBefore = probe.calls.count
        await cal.set(.denied)
        await connections.refresh()
        XCTAssertEqual(probe.calls.count, purgesBefore + 1)
        XCTAssertEqual(probe.calls.last, [event.id], "not suppressed by the earlier purge")
        let afterSecond = await narrates(event.id, session: session, cache: cache)
        XCTAssertFalse(afterSecond)
    }

    func testProviderReadFailureFailsClosedAndPurges() async {
        let id = UUID()
        let provider = FlakyProvider(item: ConnectionItem(id: id, integration: .obsidian, title: "[TEST] note", state: .approved))
        let station = StationConfigurationModel(store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init()))),
                                                consent: StaticIntegrationConsent([.obsidian: .granted]))
        await station.load()
        let probe = PurgeProbe(NarrationPurger(cache: InMemoryAudioCache(), preparer: nil))
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(),
                                           providers: [provider], purger: probe)
        await connections.refresh()
        XCTAssertTrue(probe.calls.isEmpty, "an approved, readable item is not purged")
        await provider.fail()
        await connections.refresh()
        XCTAssertEqual(probe.calls, [[id]], "an item that can no longer be read is treated as withdrawn")
        await connections.refresh()
        XCTAssertEqual(probe.calls.count, 1, "purged once, not on every refresh")
    }

    func testConsentWithdrawnForAnIntegrationPurgesItsItemsEvenIfTheProviderStillListsThem() async {
        let id = UUID()
        let consent = MutableConsent()
        let provider = InMemoryConnectionItemProvider(integration: .shareInbox, items: [
            ConnectionItem(id: id, integration: .shareInbox, title: "[TEST] shared", state: .approved)])
        let station = StationConfigurationModel(store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init()))),
                                                consent: consent)
        await station.load()
        let probe = PurgeProbe(NarrationPurger(cache: InMemoryAudioCache(), preparer: nil))
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(),
                                           providers: [provider], purger: probe)
        await connections.refresh()
        XCTAssertTrue(probe.calls.isEmpty)
        await consent.set(.revoked)
        await connections.refresh()
        XCTAssertEqual(probe.calls, [[id]])
    }
}

/// One item whose state the source can change under the same ID.
private actor DemotingProvider: ConnectionItemProvider {
    nonisolated let integration: StationIntegration = .shareInbox
    let id: UUID
    var state: ConnectionItemState = .approved
    init(id: UUID) { self.id = id }
    func set(_ s: ConnectionItemState) { state = s }
    func items(now: Date) async throws -> [ConnectionItem] {
        [ConnectionItem(id: id, integration: .shareInbox, title: "[TEST] shared", state: state)]
    }
    func perform(_ action: ConnectionAction, on id: UUID) async throws {}
}

@MainActor
final class NarratableDemotionTests: XCTestCase {
    // Reviewer finding on #62: pending/flagged were treated as alive. Visible is not narratable.
    func testSameIDDemotedToPendingOrFlaggedPurgesEachTimeAndStaysVisible() async {
        let id = UUID()
        let provider = DemotingProvider(id: id)
        let consent = MutableConsent()
        let station = StationConfigurationModel(store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init()))),
                                                consent: consent)
        await station.load()
        let cache = InMemoryAudioCache()
        let probe = PurgeProbe(NarrationPurger(cache: cache, preparer: nil))
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(),
                                           providers: [provider], purger: probe)
        probe.model = connections
        func cacheNarration() async {
            await cache.store(CachedAudio(data: Data("x".utf8), seconds: 1, providerID: "device", voiceID: "host",
                                          sourceItemIDs: [id]), for: "k-\(probe.calls.count)")
        }
        func cached() async -> Bool { await cache.audio(for: "k-\(probe.calls.count)") != nil }

        await connections.refresh()
        XCTAssertTrue(probe.calls.isEmpty, "approved + granted is narratable")
        XCTAssertTrue(connections.isNarratable(connections.items[0]))

        // 1. Same ID comes back pending approval.
        await cacheNarration()
        await provider.set(.pendingApproval)
        await connections.refresh()
        XCTAssertEqual(probe.calls, [[id]], "demoted to pending: purged")
        XCTAssertEqual(probe.exposedDuringPurge.last, [id], "purged while the approved state was still exposed")
        XCTAssertEqual(connections.items.map(\.id), [id], "still visible for review")
        XCTAssertFalse(connections.isNarratable(connections.items[0]))
        let afterPending = await cache.audio(for: "k-0")
        XCTAssertNil(afterPending, "cached narration purged")

        // 2. Re-approved, narration cached again, then flagged: purged a second time.
        await provider.set(.approved)
        await connections.refresh()
        XCTAssertEqual(probe.calls.count, 1, "re-approval does not purge")
        await cacheNarration()
        await provider.set(.flaggedForReview)
        await connections.refresh()
        XCTAssertEqual(probe.calls, [[id], [id]], "no stale purge state after re-approval")
        let afterFlag = await cache.audio(for: "k-1")
        XCTAssertNil(afterFlag)

        // 3. Re-approved, then integration consent drops to notRequested: purged a third time.
        await provider.set(.approved)
        await connections.refresh()
        await cacheNarration()
        await consent.set(.notRequested)
        await connections.refresh()
        XCTAssertEqual(probe.calls.count, 3, "consent no longer granted: purged")
        let afterConsent = await cache.audio(for: "k-2")
        XCTAssertNil(afterConsent)
    }
}

private actor MutableConsent: IntegrationConsentReading {
    var state: ConsentState = .granted
    func set(_ s: ConsentState) { state = s }
    func consentState(for integration: StationIntegration) async -> ConsentState { state }
}
