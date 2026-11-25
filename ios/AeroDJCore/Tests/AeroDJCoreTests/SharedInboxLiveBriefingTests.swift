import XCTest
@testable import AeroDJCore

// #313 (-Nova): an approved shared item never reached a live briefing.
//
// The app runs two `SharedInboxReview` actors over the same App Group files: the Connections
// provider's (created at launch) and the "Shared with" sheet's, where "Include in my briefing"
// lives. Before the fix, an entry the provider's review had already loaded kept its in-memory
// decision on every `refresh()`, so a sheet approval stayed `pendingApproval` in Connections (and
// in the briefing) until relaunch. The same staleness kept an excluded, edited or deleted share
// speakable. These tests run the whole live chain the app wires: sheet review -> Connections
// refresh -> `DJBreakSession.briefingProvider` -> `forQueue()` -> `queueStarted` -> render ->
// `naturalBoundary`. Fixture text only; messages print counts and ids, never cue text.
@MainActor
final class SharedInboxLiveBriefingTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))! }

    private struct Rig {
        let studio: StudioPresentationModel
        let session: DJBreakSession
        let dj: DJPresentationStore
        let cache: InMemoryAudioCache
        /// The sheet's own review (`SharedInboxReview.appGroupInbox()` in the app).
        let sheet: SharedInboxReview
        let ids: [UUID]
        let clock: Clock
        let dir: URL
        let state: URL
    }

    /// Share Extension envelopes, then the app's launch: one review for the Connections provider,
    /// a second one for the sheet, both over the same inbox and review-state file.
    private func rig(_ texts: [String]) async throws -> Rig {
        let clock = Clock(noon)
        let sharedAt = noon.addingTimeInterval(-600)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nova313-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ids: [UUID] = []
        for text in texts {
            let item = try XCTUnwrap(SharedInboxItem(kind: .text, content: text, now: sharedAt))
            try JSONEncoder().encode(item).write(to: dir.appendingPathComponent("\(item.id.uuidString).json"))
            ids.append(item.id)
        }
        let state = dir.deletingLastPathComponent().appendingPathComponent("nova313-\(UUID().uuidString)-state.json")
        let now: @Sendable () -> Date = { clock.now }
        func review() -> SharedInboxReview {
            SharedInboxReview(reader: SharedInboxReader(directory: dir), store: SharedReviewStore(file: state), now: now)
        }

        var config = StationConfiguration(commentary: .frequent)
        config.briefing = BriefingPreferences(enabled: true, sections: Set(BriefingSection.allCases))
        config.requestedIntegrations = [.shareInbox]
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([.shareInbox: .granted]))
        await station.load()
        let cache = InMemoryAudioCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DeviceVoice313(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 12 },
                                     now: { clock.now }, personalUpdates: PersonalUpdateLedger(calendar: calendar),
                                     calendar: calendar)
        await session.start()
        let purger = NarrationPurger(cache: cache, preparer: preparer, session: session,
                                     revocations: NarrationRevocations(), feed: NarrationPurgeFeed())
        session.purger = purger
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(),
                                           providers: [SharedInboxConnectionProvider(review: review())],
                                           purger: purger, now: now)
        let studio = StudioPresentationModel(station: station, recipes: StationRecipeLibrary(store: InMemoryStationRecipeStore()),
                                             connections: connections, dj: dj)
        await studio.start()   // launch: Connections reads the inbox once (every share pending)
        let sheet = review()
        try await sheet.refresh()   // the sheet's `.task`
        return Rig(studio: studio, session: session, dj: dj, cache: cache, sheet: sheet, ids: ids, clock: clock,
                   dir: dir, state: state)
    }

    /// The sheet's `onChange` in the app (`StationListView`): Connections re-reads.
    private func sheetChanged(_ r: Rig) async { await r.studio.connections.refresh() }

    private func queuedContentIDs(_ r: Rig) -> [UUID] {
        let provider = r.session.briefingProvider(studio: r.studio, now: { r.clock.now }, calendar: calendar)
        return (provider().forQueue()?.cues ?? []).filter(\.isContent).compactMap(\.sourceItemID)
    }

    /// A song tap exactly as `MusicSearch.live` does it: read the provider, `forQueue()`, then
    /// background queue setup; the first song starts and its break renders.
    private func tapAndRender(_ r: Rig) async {
        let provider = r.session.briefingProvider(studio: r.studio, now: { r.clock.now }, calendar: calendar)
        let handoff = provider()
        await r.session.queueStarted(djTracks(8), briefing: handoff.forQueue(), sources: handoff.connectionItems)
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        for _ in 0..<500 { if case .ready = r.dj.studioState { break }; try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func personalClips(_ r: Rig) async -> Int { await r.cache.fileCount().personal }

    // MARK: An approved item reaches the live briefing

    /// Red before #313: 0 content cues (Connections kept the launch-time `pendingApproval`).
    func testASheetApprovalReachesTheLiveBriefingAndAirs() async throws {
        let r = try await rig(["Fixture: dentist moved to Thursday"])
        let id = r.ids[0]
        XCTAssertEqual(r.studio.connections.items.map(\.state), [.pendingApproval], "launch: pending")

        try await r.sheet.setDecision(.approved, for: id)
        await sheetChanged(r)
        XCTAssertEqual(r.studio.connections.items.map(\.state), [.approved], "Connections sees the sheet's approval")
        XCTAssertEqual(queuedContentIDs(r), [id], "the live provider offers it")

        await tapAndRender(r)
        let boundary = await r.session.naturalBoundary(afterTrack: 0)
        let handed = try XCTUnwrap(boundary, "the briefing break is handed out")
        let content = handed.cues.filter(\.isContent)
        XCTAssertEqual(content.compactMap(\.sourceItemID), [id], "\(content.count) content cues")
        let cueID = try XCTUnwrap(content.first?.id)
        guard case .personalContext(let itemID, _, _)? = handed.attributions[cueID] else {
            return XCTFail("the personal line is attributed to its row")
        }
        XCTAssertEqual(itemID, id)
        XCTAssertNotNil(handed.clips.first { $0.cueID == cueID }, "and it has rendered audio")
    }

    /// Connections' own Approve (same review instance) kept working; pinned so both paths stay equal.
    func testAConnectionsApprovalStillReachesTheLiveBriefing() async throws {
        let r = try await rig(["Fixture: call the landlord"])
        _ = await r.studio.connections.perform(.approve, on: r.ids[0])
        XCTAssertEqual(queuedContentIDs(r), [r.ids[0]])
    }

    // MARK: An unapproved item never does

    func testPendingAndExcludedSharesNeverReachTheLiveBriefing() async throws {
        let r = try await rig(["Fixture: approved", "Fixture: still pending", "Fixture: excluded"])
        let approved = r.ids[0], pending = r.ids[1], excluded = r.ids[2]
        try await r.sheet.setDecision(.approved, for: approved)
        try await r.sheet.setDecision(.excluded, for: excluded)
        await sheetChanged(r)
        XCTAssertEqual(queuedContentIDs(r), [approved], "only the included share")

        await tapAndRender(r)
        XCTAssertFalse(r.session.testPlannedSourceItemIDs.contains(pending))
        XCTAssertFalse(r.session.testPlannedSourceItemIDs.contains(excluded))
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        let spoken = Set((handed?.cues ?? []).compactMap(\.sourceItemID))
        XCTAssertEqual(spoken, [approved], "\(spoken.count) personal ids handed out")
    }

    /// Never approved: no Connections refresh, sheet change or relaunch makes it speakable.
    func testAShareThatWasNeverIncludedStaysSilentAfterRefreshes() async throws {
        let r = try await rig(["Fixture: never included"])
        try await r.sheet.setLabel(.email, for: r.ids[0])   // a sheet edit that is not an include
        await sheetChanged(r)
        await sheetChanged(r)
        XCTAssertEqual(r.studio.connections.items.map(\.state), [.pendingApproval])
        XCTAssertEqual(queuedContentIDs(r), [])
    }

    // MARK: Withdrawal purges

    /// Red before #313: the exclusion never reached Connections, so the prepared break and its
    /// cached clip kept the share and the next boundary aired it.
    func testExcludingInTheSheetPurgesThePreparedBreakAndItsClips() async throws {
        let r = try await rig(["Fixture: pick up the parcel"])
        let id = r.ids[0]
        try await r.sheet.setDecision(.approved, for: id)
        await sheetChanged(r)
        await tapAndRender(r)
        XCTAssertTrue(r.session.testPlannedSourceItemIDs.contains(id), "fixture: planned")
        let before = await personalClips(r)
        XCTAssertGreaterThan(before, 0, "fixture: its line was rendered and cached")

        try await r.sheet.setDecision(.excluded, for: id)
        await sheetChanged(r)
        XCTAssertFalse(r.session.testPlannedSourceItemIDs.contains(id), "dropped from the prepared plan")
        let after = await personalClips(r)
        XCTAssertEqual(after, 0, "its cached clips are purged")
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertFalse((handed?.cues ?? []).contains { $0.sourceItemID == id }, "never handed out")
        XCTAssertEqual(queuedContentIDs(r), [], "and the next briefing leaves it out")
    }

    func testDeletingInTheSheetPurgesToo() async throws {
        let r = try await rig(["Fixture: delete me"])
        let id = r.ids[0]
        try await r.sheet.setDecision(.approved, for: id)
        await sheetChanged(r)
        await tapAndRender(r)
        XCTAssertTrue(r.session.testPlannedSourceItemIDs.contains(id), "fixture: planned")
        let before = await personalClips(r)
        XCTAssertGreaterThan(before, 0, "fixture: rendered")
        try await r.sheet.delete(id)
        await sheetChanged(r)
        XCTAssertFalse(r.session.testPlannedSourceItemIDs.contains(id))
        let after = await personalClips(r)
        XCTAssertEqual(after, 0)
        XCTAssertEqual(queuedContentIDs(r), [])
    }

    /// An edit in the sheet replaces the text Connections (and the briefing) reads: the old,
    /// unredacted first line is never offered again, and the break prepared next is built and
    /// rendered from the edited text. Red before #313 (the launch-time text stayed).
    func testARedactionInTheSheetReplacesTheTextTheBriefingReads() async throws {
        let r = try await rig(["Fixture original 555-0100"])
        let id = r.ids[0]
        try await r.sheet.setDecision(.approved, for: id)
        try await r.sheet.redact(id, to: "Fixture edited")
        await sheetChanged(r)
        XCTAssertEqual(r.studio.connections.items.map(\.title), ["Fixture edited"])
        XCTAssertFalse(r.studio.connections.items.contains { $0.title.contains("555-0100") })

        await tapAndRender(r)
        XCTAssertTrue(r.session.testPlannedSourceItemIDs.contains(id), "the edited item is prepared")
        let boundary = await r.session.naturalBoundary(afterTrack: 0)
        let handed = try XCTUnwrap(boundary, "a break is handed out")
        let line = try XCTUnwrap(handed.cues.first { $0.isContent && $0.sourceItemID == id }, "its line is in the break")
        XCTAssertTrue(line.text.contains("Fixture edited"), "the prepared line reads the edited text")
        XCTAssertFalse(handed.cues.contains { $0.text.contains("555-0100") }, "no cue reads the original")
        XCTAssertNotNil(handed.clips.first { $0.cueID == line.id }, "and its rendered clip is for that line")
    }

    /// #313 B1 (Sentinel's probe): a redaction after the break was prepared and rendered. The
    /// item keeps its id and its approval, so before the fix nothing was purged: the clip
    /// rendered from the original text stayed cached and the next boundary aired it.
    func testARedactionAfterRenderPurgesTheBreakAndClipsBuiltFromTheOriginalText() async throws {
        let r = try await rig(["Fixture original 555-0100"])
        let id = r.ids[0]
        try await r.sheet.setDecision(.approved, for: id)
        await sheetChanged(r)
        await tapAndRender(r)
        XCTAssertTrue(r.session.testPlannedSourceItemIDs.contains(id), "fixture: planned")
        let before = await personalClips(r)
        XCTAssertGreaterThan(before, 0, "fixture: rendered")

        try await r.sheet.redact(id, to: "Fixture edited")
        await sheetChanged(r)
        XCTAssertFalse(r.session.testPlannedSourceItemIDs.contains(id), "dropped from the prepared plan")
        let after = await personalClips(r)
        XCTAssertEqual(after, 0, "clips rendered from the original text are purged")
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        let leaked = (handed?.cues ?? []).filter { $0.text.contains("555-0100") }.count
        XCTAssertEqual(leaked, 0, "\(leaked) cues read the original text")
        XCTAssertEqual(r.studio.connections.items.map(\.state), [.approved], "the item stays included")
        XCTAssertEqual(queuedContentIDs(r), [id], "and the next briefing offers it with the edited text")
    }

    /// The sheet's pre-edit purge (`willRedact` -> `purgeNarration(for:)`) drops prepared
    /// narration before the redaction is even written, and leaves no stale purge state: after the
    /// refresh the edited item is prepared and rendered again.
    func testPurgingAheadOfAnEditDropsThePreparedBreakAndTheItemComesBack() async throws {
        let r = try await rig(["Fixture original 555-0100"])
        let id = r.ids[0]
        try await r.sheet.setDecision(.approved, for: id)
        await sheetChanged(r)
        await tapAndRender(r)
        let before = await personalClips(r)
        XCTAssertGreaterThan(before, 0, "fixture: rendered")

        await r.studio.connections.purgeNarration(for: [id])
        XCTAssertFalse(r.session.testPlannedSourceItemIDs.contains(id), "purged before the write")
        let purgedClips = await personalClips(r)
        XCTAssertEqual(purgedClips, 0)
        try await r.sheet.redact(id, to: "Fixture edited")
        await sheetChanged(r)
        XCTAssertEqual(queuedContentIDs(r), [id])
        await tapAndRender(r)
        let rerendered = await personalClips(r)
        XCTAssertGreaterThan(rerendered, 0, "prepared again from the edited text")
    }

    /// Guards the B1 purge against over-reach: a refresh, or a sheet edit that does not change
    /// the narrated text (a source label), keeps the prepared break and its clip.
    func testARefreshWithoutATextChangeKeepsThePreparedBreak() async throws {
        let r = try await rig(["Fixture: keep me"])
        let id = r.ids[0]
        try await r.sheet.setDecision(.approved, for: id)
        await sheetChanged(r)
        await tapAndRender(r)
        let before = await personalClips(r)
        XCTAssertGreaterThan(before, 0, "fixture: rendered")

        await sheetChanged(r)
        try await r.sheet.setLabel(.email, for: id)
        await sheetChanged(r)
        XCTAssertTrue(r.session.testPlannedSourceItemIDs.contains(id), "still planned")
        let after = await personalClips(r)
        XCTAssertEqual(after, before, "its clip is kept")
    }

    // MARK: SharedInboxReview: the store is the truth

    func testTwoReviewsOverOneStoreAgreeAfterRefresh() async throws {
        let r = try await rig(["Fixture: a", "Fixture: b"])
        let other = SharedInboxReview(reader: SharedInboxReader(directory: r.dir),
                                      store: SharedReviewStore(file: r.state), now: { r.clock.now })
        try await other.refresh()
        try await r.sheet.setDecision(.approved, for: r.ids[0])
        try await other.refresh()
        var seen = await other.entries
        XCTAssertEqual(seen.first { $0.id == r.ids[0] }?.decision, .approved)
        try await r.sheet.setDecision(.excluded, for: r.ids[0])
        try await other.refresh()
        seen = await other.entries
        XCTAssertEqual(seen.first { $0.id == r.ids[0] }?.decision, .excluded)
        XCTAssertEqual(seen.first { $0.id == r.ids[1] }?.decision, .pending)
    }

    /// Without a store, in-memory state is all there is: a refresh keeps it (unchanged behavior).
    func testAReviewWithoutAStoreKeepsItsOwnDecisionsOnRefresh() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nova313-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let item = try XCTUnwrap(SharedInboxItem(kind: .text, content: "Fixture memory", now: noon))
        try JSONEncoder().encode(item).write(to: dir.appendingPathComponent("\(item.id.uuidString).json"))
        let now = noon
        let review = SharedInboxReview(reader: SharedInboxReader(directory: dir), now: { now })
        try await review.refresh()
        try await review.setDecision(.approved, for: item.id)
        try await review.refresh()
        let kept = await review.entries.map(\.decision)
        XCTAssertEqual(kept, [.approved])
    }

    /// A decision that could not be saved is not kept in memory either: the store is the truth,
    /// so the review never claims a state a refresh (or the other review) would not see.
    func testAnUnsavedDecisionIsNotKept() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nova313-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let item = try XCTUnwrap(SharedInboxItem(kind: .text, content: "Fixture unsaved", now: noon))
        try JSONEncoder().encode(item).write(to: dir.appendingPathComponent("\(item.id.uuidString).json"))
        // A directory where the state file should be: every save fails.
        let blocked = dir.appendingPathComponent("state.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let now = noon
        let review = SharedInboxReview(reader: SharedInboxReader(directory: dir), store: SharedReviewStore(file: blocked),
                                       now: { now })
        _ = try? await review.refresh()
        do {
            try await review.setDecision(.approved, for: item.id)
            XCTFail("the save must fail")
        } catch {}
        let decisions = await review.entries.map(\.decision)
        XCTAssertEqual(decisions, [.pending])
        _ = try? await review.refresh()
        let after = await review.entries.map(\.decision)
        XCTAssertEqual(after, [.pending], "nor after a reload")
    }
}

private struct DeviceVoice313: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}
