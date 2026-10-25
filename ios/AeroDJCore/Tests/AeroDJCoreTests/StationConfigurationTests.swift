import XCTest
@testable import AeroDJCore

final class StationConfigurationValidationTests: XCTestCase {
    func testDefaultsAreMigrationSafe() {
        let d = StationConfiguration.default
        XCTAssertEqual(d.energy, 0.5)
        XCTAssertEqual(d.discovery, 0.3)
        XCTAssertEqual(d.commentary, .occasional)
        XCTAssertEqual(d.commentary.talkFraction, 0.3)
        XCTAssertTrue(d.briefing.enabled)
        XCTAssertEqual(d.briefing.targetSeconds, 300)
        XCTAssertTrue(d.requestedIntegrations.isEmpty, "no integration is requested by default")
    }

    func testClampsUnitValuesAndNonFinite() {
        XCTAssertEqual(StationConfiguration(energy: 4, discovery: -1).energy, 1)
        XCTAssertEqual(StationConfiguration(energy: 4, discovery: -1).discovery, 0)
        XCTAssertEqual(StationConfiguration(energy: .nan).energy, 0.5)
        XCTAssertEqual(StationConfiguration(discovery: .infinity).discovery, 0.3)
    }

    func testTagsAreNormalizedDeduplicatedAndBounded() {
        let c = StationConfiguration(genres: ["  Indie   Pop ", "indie pop", "", "   ", String(repeating: "x", count: 50)]
                                     + (1...20).map { "g\($0)" })
        XCTAssertEqual(c.genres.first, "indie pop")
        XCTAssertEqual(c.genres.count, StationConfiguration.Limits.maxTags)
        XCTAssertEqual(c.genres[1].count, StationConfiguration.Limits.maxTagLength)
        XCTAssertEqual(Set(c.genres).count, c.genres.count)
    }

    func testBriefingBounds() {
        let b = BriefingPreferences(window: .init(startMinute: -30, durationMinutes: 10_000), targetSeconds: 5)
        XCTAssertEqual(b.window.startMinute, 1410)
        XCTAssertEqual(b.window.durationMinutes, 240)
        XCTAssertEqual(b.targetSeconds, 60)
        XCTAssertEqual(BriefingPreferences(targetSeconds: 9999).targetSeconds, 600)
    }

    func testValidatedIsIdempotent() {
        let c = StationConfiguration(genres: ["A", "a"], energy: 9)
        XCTAssertEqual(c, c.validated())
    }

    func testBriefingWindowWrapsMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let window = BriefingWindow(startMinute: 23 * 60, durationMinutes: 120)
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: h, minute: m))!
        }
        XCTAssertTrue(window.contains(at(23, 30), calendar: cal))
        XCTAssertTrue(window.contains(at(0, 59), calendar: cal))
        XCTAssertFalse(window.contains(at(1, 0), calendar: cal), "end is exclusive")
        XCTAssertFalse(window.contains(at(22, 59), calendar: cal))
    }

    func testCommentaryMapsOntoBoundedCadence() {
        for c in CommentaryFrequency.allCases {
            XCTAssertLessThanOrEqual(c.talkFraction, CommentaryFrequency.maxTalkFraction)
        }
        let base = DJCadence(talkFraction: 0.9, minSongsBetweenBreaks: 3, maxTransitionSeconds: 12, maxBriefingBreakSeconds: 45)
        let cadence = StationConfiguration(personality: .minimal, commentary: .rare).cadence(base: base)
        XCTAssertEqual(cadence.talkFraction, 0.15)
        XCTAssertEqual(cadence.minSongsBetweenBreaks, 3, "never back-to-back rule is kept")
        XCTAssertEqual(cadence.maxTransitionSeconds, 6)
        XCTAssertEqual(cadence.maxBriefingBreakSeconds, 45)
        XCTAssertEqual(StationConfiguration(commentary: .off).cadence().talkFraction, 0)
    }

    func testCommentaryOffKeepsDJWriterSilentBetweenSongs() {
        let tracks = (0..<12).map { DJTrack(id: "t\($0)", title: "Song \($0)", artist: "Artist \($0)") }
        var writer = DJScriptWriter(cadence: StationConfiguration(commentary: .off).cadence(), seed: 7)
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 9)
        XCTAssertTrue(plan.breaks.isEmpty)
    }

    func testIntegrationsMapToContextSources() {
        let c = StationConfiguration(requestedIntegrations: [.shareInbox])
        XCTAssertEqual(c.requestedContextSources, [.emailShared, .messagesShared, .userShared])
        for kind in [ContextSourceKind.calendar, .emailShared, .messagesShared, .obsidian, .userShared] {
            XCTAssertTrue(StationIntegration(source: kind).contextSources.contains(kind))
        }
    }

    func testPlannableSectionsNeedConsentedIntegration() {
        let b = BriefingPreferences(sections: [.calendar, .notes])
        XCTAssertEqual(b.plannableSections(grantedIntegrations: [.calendar]), [.calendar])
        XCTAssertEqual(BriefingPreferences(enabled: false).plannableSections(grantedIntegrations: [.calendar]), [])
    }
}

final class StationConfigurationPersistenceTests: XCTestCase {
    func testRoundTrip() throws {
        let snapshot = StationConfigurationSnapshot(state: .samplePendingEdit)
        let decoded = try StationConfigurationSnapshot.decode(snapshot.encoded())
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNotNil(decoded.state.pending, "pending survives relaunch")
    }

    func testEncodingIsStableAndSorted() throws {
        let a = try StationConfigurationSnapshot(state: .init(active: .sampleMorningMix)).encoded()
        let b = try StationConfigurationSnapshot(state: .init(active: .sampleMorningMix)).encoded()
        XCTAssertEqual(a, b)
        let json = String(decoding: a, as: UTF8.self)
        XCTAssertTrue(json.contains(#""requestedIntegrations":["calendar","shareInbox"]"#), json)
        XCTAssertTrue(json.contains(#""version":1"#))
    }

    func testUnversionedPartialPayloadMigratesToDefaults() throws {
        let json = #"{"active":{"genres":["Jazz"],"energy":7,"personality":"robot","requestedIntegrations":["calendar","fax"]}}"#
        let s = try StationConfigurationSnapshot.decode(Data(json.utf8))
        XCTAssertEqual(s.version, 1)
        XCTAssertEqual(s.state.active.genres, ["jazz"])
        XCTAssertEqual(s.state.active.energy, 1)
        XCTAssertEqual(s.state.active.personality, .warm, "unknown preset falls back")
        XCTAssertEqual(s.state.active.discovery, 0.3)
        XCTAssertEqual(s.state.active.briefing, BriefingPreferences())
        XCTAssertEqual(s.state.active.requestedIntegrations, [.calendar], "unknown integration is ignored, never granted")
        XCTAssertNil(s.state.pending)
    }

    func testPendingEqualToActiveIsDropped() throws {
        let json = #"{"version":1,"active":{"energy":0.4},"pending":{"energy":0.4}}"#
        XCTAssertNil(try StationConfigurationSnapshot.decode(Data(json.utf8)).state.pending)
    }

    func testNewerVersionIsRejected() {
        XCTAssertThrowsError(try StationConfigurationSnapshot.decode(Data(#"{"version":2,"active":{}}"#.utf8))) {
            XCTAssertEqual($0 as? StationConfigurationStoreError, .newerVersion(2))
        }
    }

    func testCorruptDataIsUnreadable() {
        XCTAssertThrowsError(try StationConfigurationSnapshot.decode(Data("not json".utf8))) {
            XCTAssertEqual($0 as? StationConfigurationStoreError, .unreadable)
        }
    }

    func testFileStoreRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStationConfigurationStore(fileURL: dir.appendingPathComponent("station.json"))
        let empty = try await store.load()
        XCTAssertNil(empty)
        let snapshot = StationConfigurationSnapshot(state: .samplePendingEdit)
        try await store.save(snapshot)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, snapshot)
    }
}

final class StationConfigurationStateTests: XCTestCase {
    func testUnchangedEditIsNoOp() {
        var s = StationConfigurationState()
        XCTAssertEqual(s.edit { $0.energy = 0.5 }, .unchanged)
        XCTAssertEqual(s.edit { $0.energy = 3; $0.energy = 0.5 }, .unchanged)
        XCTAssertEqual(s.edit { $0.genres = [] }, .unchanged)
        XCTAssertNil(s.pending)
    }

    func testClampedToSameValueIsNoOp() {
        var s = StationConfigurationState(active: .init(energy: 1))
        XCTAssertEqual(s.edit { $0.energy = 5 }, .unchanged)
    }

    func testTuningWaitsForSongBoundaryNotMidSongEvents() {
        var s = StationConfigurationState()
        XCTAssertEqual(s.edit { $0.energy = 0.9; $0.genres = ["house"] }, .pending([.energy, .genres]))
        XCTAssertEqual(s.active.energy, 0.5, "active untouched mid-song")
        XCTAssertEqual(s.displayed.energy, 0.9)
        XCTAssertEqual(s.pendingSettings, [.energy: .nextSongBoundary, .genres: .nextSongBoundary])
        XCTAssertNil(s.apply(.djBreakWillPrepare(afterTrack: 3)))
        XCTAssertNil(s.apply(.briefingWillPlan))
        XCTAssertEqual(s.active.energy, 0.5)
        let change = s.apply(.songBoundary(afterTrack: 3))
        XCTAssertEqual(change?.applied, [.energy, .genres])
        XCTAssertEqual(change?.boundary, .songBoundary(afterTrack: 3))
        XCTAssertEqual(s.active.energy, 0.9)
        XCTAssertNil(s.pending)
        XCTAssertNil(s.apply(.songBoundary(afterTrack: 4)), "nothing left to apply")
    }

    /// Safe-boundary guarantee: during a song, no edit or non-boundary event changes what
    /// drives song selection, so nothing can retune or restart the song that is playing.
    func testMidSongEditsNeverChangeActiveTuningUntilSongBoundary() {
        var s = StationConfigurationState(active: .sampleMorningMix)
        let playing = s.active
        var changes: [StationConfigurationChange] = []
        for i in 0..<20 {
            s.edit { $0.energy = Double(i) / 20; $0.discovery = 1 - Double(i) / 20
                     $0.genres = ["g\(i)"]; $0.moods = ["m\(i)"]; $0.personality = i.isMultiple(of: 2) ? .upbeat : .laidBack }
            if let c = s.apply(.djBreakWillPrepare(afterTrack: 0)) { changes.append(c) }
            if let c = s.apply(.briefingWillPlan) { changes.append(c) }
            XCTAssertEqual(s.active.energy, playing.energy)
            XCTAssertEqual(s.active.discovery, playing.discovery)
            XCTAssertEqual(s.active.genres, playing.genres)
            XCTAssertEqual(s.active.moods, playing.moods)
        }
        let tuning: Set<StationSetting> = [.energy, .discovery, .genres, .moods]
        XCTAssertTrue(changes.allSatisfy { $0.applied.isDisjoint(with: tuning) }, "mid-song events never apply tuning")
        let boundary = s.apply(.songBoundary(afterTrack: 0))
        XCTAssertTrue(tuning.isSubset(of: boundary?.applied ?? []))
        XCTAssertEqual(boundary?.boundary, .songBoundary(afterTrack: 0))
    }

    func testBetaCommentaryDefaultIsThirtyPercent() {
        XCTAssertEqual(StationConfiguration.default.cadence().talkFraction, 0.3)
        XCTAssertEqual(StationConfiguration.default.cadence().talkFraction, DJCadence().talkFraction)
    }

    func testPersonalityAppliesAtNextBreakPreparation() {
        var s = StationConfigurationState()
        s.edit { $0.personality = .upbeat; $0.energy = 0.8 }
        let change = s.apply(.djBreakWillPrepare(afterTrack: 2))
        XCTAssertEqual(change?.applied, [.personality])
        XCTAssertEqual(s.active.personality, .upbeat)
        XCTAssertEqual(s.active.energy, 0.5, "tuning still waits for the song boundary")
        XCTAssertEqual(s.pendingSettings, [.energy: .nextSongBoundary])
    }

    func testBriefingChangesApplyAtBriefingPlanOrBoundary() {
        var s = StationConfigurationState()
        s.edit { $0.briefing.targetSeconds = 180 }
        XCTAssertEqual(s.pendingSettings, [.briefing: .nextBriefing])
        XCTAssertNil(s.apply(.djBreakWillPrepare(afterTrack: 1)))
        XCTAssertEqual(s.apply(.briefingWillPlan)?.applied, [.briefing])
        XCTAssertEqual(s.active.briefing.targetSeconds, 180)

        var t = StationConfigurationState()
        t.edit { $0.briefing.sections = [.calendar] }
        XCTAssertEqual(t.apply(.songBoundary(afterTrack: 1))?.applied, [.briefing], "song boundary is the latest point")
    }

    func testPrivacyReductionsApplyImmediately() {
        var s = StationConfigurationState(active: .init(requestedIntegrations: [.calendar, .obsidian]))
        guard case .applied(let change, let stillPending) = s.edit({ $0.requestedIntegrations.remove(.obsidian) }) else {
            return XCTFail("withdrawal must be immediate")
        }
        XCTAssertEqual(change.withdrawnIntegrations, [.obsidian])
        XCTAssertTrue(change.invalidatesPreparedBreaks)
        XCTAssertNil(change.boundary)
        XCTAssertTrue(stillPending.isEmpty)
        XCTAssertEqual(s.active.requestedIntegrations, [.calendar])

        guard case .applied(let off, _) = s.edit({ $0.briefing.enabled = false }) else { return XCTFail() }
        XCTAssertFalse(s.active.briefing.enabled)
        XCTAssertTrue(off.invalidatesPreparedBreaks)

        guard case .applied(let quiet, _) = s.edit({ $0.commentary = .off }) else { return XCTFail() }
        XCTAssertEqual(s.active.commentary, .off)
        XCTAssertTrue(quiet.invalidatesPreparedBreaks)
    }

    func testRequestingIntegrationIsPendingAndNeverImmediate() {
        var s = StationConfigurationState()
        XCTAssertEqual(s.edit { $0.requestedIntegrations.insert(.calendar) }, .pending([.integration(.calendar)]))
        XCTAssertEqual(s.pendingSettings, [.integration(.calendar): .nextBriefing])
        XCTAssertTrue(s.active.requestedIntegrations.isEmpty)
    }

    func testMixedEditSplitsImmediateFromPending() {
        var s = StationConfigurationState(active: .init(requestedIntegrations: [.calendar]))
        guard case .applied(let change, let stillPending) = s.edit({
            $0.requestedIntegrations = []
            $0.energy = 0.1
        }) else { return XCTFail() }
        XCTAssertEqual(change.applied, [.integration(.calendar)])
        XCTAssertEqual(stillPending, [.energy])
        XCTAssertEqual(s.active.energy, 0.5)
    }

    func testRevertingAPendingEditClearsPending() {
        var s = StationConfigurationState()
        s.edit { $0.energy = 0.9 }
        XCTAssertEqual(s.edit { $0.energy = 0.5 }, .pending([]))
        XCTAssertNil(s.pending)
        XCTAssertNil(s.apply(.songBoundary(afterTrack: 1)))
    }

    func testWithdrawingAPendingRequestIsNotAnImmediateChange() {
        var s = StationConfigurationState()
        s.edit { $0.requestedIntegrations.insert(.obsidian) }
        XCTAssertEqual(s.edit { $0.requestedIntegrations.remove(.obsidian) }, .pending([]))
        XCTAssertNil(s.pending)
    }

    func testDiscardPending() {
        var s = StationConfigurationState()
        s.edit { $0.moods = ["calm"] }
        s.discardPending()
        XCTAssertEqual(s.displayed, .default)
    }

    func testRepeatedEditsCoalesceIntoOnePendingConfig() {
        var s = StationConfigurationState()
        for v in [0.55, 0.65, 0.75, 0.85, 0.95] { s.edit { $0.energy = v } }
        XCTAssertEqual(s.displayed.energy, 0.95, accuracy: 1e-9)
        XCTAssertEqual(s.apply(.songBoundary(afterTrack: 0))?.applied, [.energy])
    }
}

/// Scheduler stand-in for `StationBoundaryEventSource`.
final class FakeBoundarySource: StationBoundaryEventSource, @unchecked Sendable {
    let stream: AsyncStream<StationBoundaryEvent>
    let continuation: AsyncStream<StationBoundaryEvent>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func stationBoundaryEvents() -> AsyncStream<StationBoundaryEvent> { stream }
}

@MainActor
final class StationConfigurationModelTests: XCTestCase {
    private func makeModel(_ state: StationConfigurationState = .init(),
                           consent: [StationIntegration: ConsentState] = [:],
                           store: InMemoryStationConfigurationStore? = nil) async
        -> (StationConfigurationModel, InMemoryStationConfigurationStore) {
        let store = store ?? InMemoryStationConfigurationStore(snapshot: .init(state: state))
        let model = StationConfigurationModel(store: store, consent: StaticIntegrationConsent(consent))
        await model.load()
        return (model, store)
    }

    func testLoadsPersistedStateAndConsent() async {
        let (model, _) = await makeModel(.samplePendingEdit, consent: [.calendar: .granted])
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertEqual(model.active, .sampleMorningMix)
        XCTAssertEqual(model.displayed.energy, 0.85)
        XCTAssertTrue(model.hasPendingChanges)
        XCTAssertEqual(model.status(for: .energy), .pendingBoundary(.nextSongBoundary))
        XCTAssertEqual(model.status(for: .personality), .pendingBoundary(.nextDJBreak))
        XCTAssertEqual(model.status(for: .moods), .idle)
    }

    func testEditSavesAndShowsPendingBoundary() async {
        let (model, store) = await makeModel()
        await model.setEnergy(0.9)
        XCTAssertEqual(model.status(for: .energy), .pendingBoundary(.nextSongBoundary))
        let count = await store.saveCount
        XCTAssertEqual(count, 1)
        let saved = try? await store.load()
        XCTAssertEqual(saved?.state.pending?.energy, 0.9)
    }

    func testUnchangedEditDoesNotSave() async {
        let (model, store) = await makeModel()
        await model.setEnergy(0.5)
        await model.setGenres([])
        let count = await store.saveCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.status(for: .energy), .idle)
    }

    func testFailedSaveRollsBackAndReportsError() async {
        let (model, store) = await makeModel()
        await store.setFailSaves(true)
        await model.setEnergy(0.9)
        XCTAssertEqual(model.displayed.energy, 0.5, "UI never shows a value that was not saved")
        XCTAssertEqual(model.status(for: .energy), .error(.saveFailed))
        await store.setFailSaves(false)
        await model.setEnergy(0.8)
        XCTAssertEqual(model.status(for: .energy), .pendingBoundary(.nextSongBoundary))
    }

    func testFailedSaveKeepsPrivacyReductionInEffect() async {
        let (model, store) = await makeModel(.init(active: .init(requestedIntegrations: [.calendar])),
                                             consent: [.calendar: .granted])
        await store.setFailSaves(true)
        await model.setIntegration(.calendar, requested: false)
        XCTAssertFalse(model.active.requestedIntegrations.contains(.calendar), "withdrawal is never rolled back")
        XCTAssertEqual(model.status(for: .integration(.calendar)), .error(.reductionNotSaved))
        XCTAssertTrue(model.usableIntegrations.isEmpty)
    }

    func testRequestingIntegrationNeverGrantsAccess() async {
        let (model, _) = await makeModel(consent: [.calendar: .notRequested, .obsidian: .denied])
        await model.setIntegration(.calendar, requested: true)
        await model.setIntegration(.obsidian, requested: true)
        await model.handle(.songBoundary(afterTrack: 1))
        XCTAssertEqual(model.active.requestedIntegrations, [.calendar, .obsidian])
        XCTAssertEqual(model.integrationStatus(.calendar), .consentReviewRequired)
        XCTAssertEqual(model.integrationStatus(.obsidian), .blocked(.denied))
        XCTAssertEqual(model.status(for: .integration(.calendar)), .consentRequired(.notRequested))
        XCTAssertFalse(model.integrationStatus(.calendar).mayShowConnected)
        XCTAssertTrue(model.usableIntegrations.isEmpty)
        XCTAssertTrue(model.plannableBriefingSections.isEmpty)
        XCTAssertEqual(model.integrationStatus(.shareInbox), .off)
    }

    func testIntegrationStatusIsCheckingUntilConsentRead() async {
        let model = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init(requestedIntegrations: [.calendar])))),
            consent: StaticIntegrationConsent([.calendar: .granted]),
            initial: .init(active: .init(requestedIntegrations: [.calendar])))
        XCTAssertEqual(model.integrationStatus(.calendar), .checking)
        await model.load()
        XCTAssertEqual(model.integrationStatus(.calendar), .on)
        XCTAssertEqual(model.usableIntegrations, [.calendar])
    }

    func testEditsBeforeLoadAreRejectedHonestly() async {
        let model = StationConfigurationModel(store: InMemoryStationConfigurationStore(), consent: StaticIntegrationConsent([:]))
        await model.setEnergy(0.9)
        XCTAssertEqual(model.status(for: .energy), .error(.notLoaded))
        XCTAssertEqual(model.displayed.energy, 0.5)
    }

    func testNewerVersionOnDiskIsReadOnly() async {
        let store = InMemoryStationConfigurationStore(rawData: Data(#"{"version":9,"active":{}}"#.utf8))
        let (model, _) = await makeModel(store: store)
        XCTAssertEqual(model.loadState, .failed(.newerVersion(9)))
        XCTAssertEqual(model.active, .default)
        await model.setEnergy(0.9)
        XCTAssertEqual(model.status(for: .energy), .error(.readOnlyNewerVersion))
        let count = await store.saveCount
        XCTAssertEqual(count, 0, "never overwrite a newer file")
    }

    func testCorruptFileFallsBackToDefaultsAndStaysEditable() async {
        let store = InMemoryStationConfigurationStore(rawData: Data("garbage".utf8))
        let (model, _) = await makeModel(store: store)
        XCTAssertEqual(model.loadState, .failed(.unreadable))
        await model.setEnergy(0.7)
        XCTAssertEqual(model.status(for: .energy), .pendingBoundary(.nextSongBoundary))
    }

    func testBoundaryEventsFromSchedulerApplyPendingAndPublish() async {
        let (model, store) = await makeModel()
        let changes = model.changes()
        let source = FakeBoundarySource()
        model.attach(to: source)
        await model.setEnergy(0.9)
        await model.setPersonality(.laidBack)

        source.continuation.yield(.djBreakWillPrepare(afterTrack: 4))
        var iterator = changes.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.applied, [.personality])
        XCTAssertEqual(model.active.energy, 0.5)

        source.continuation.yield(.songBoundary(afterTrack: 4))
        let second = await iterator.next()
        XCTAssertEqual(second?.applied, [.energy])
        XCTAssertEqual(second?.boundary, .songBoundary(afterTrack: 4))
        XCTAssertEqual(model.active.energy, 0.9)
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertEqual(model.status(for: .energy), .idle)
        // The boundary save runs after the change is published; wait for it (bounded).
        var tries = 0
        while await store.saveCount < 4, tries < 200 { tries += 1; try? await Task.sleep(for: .milliseconds(5)) }
        let saved = try? await store.load()
        XCTAssertEqual(saved?.state.active.energy, 0.9)
        XCTAssertNil(saved?.state.pending)
        model.detach()
    }

    func testImmediateChangeIsPublishedWithoutBoundary() async {
        let (model, _) = await makeModel(.init(active: .init(requestedIntegrations: [.obsidian])))
        let changes = model.changes()
        await model.setIntegration(.obsidian, requested: false)
        var iterator = changes.makeAsyncIterator()
        let change = await iterator.next()
        XCTAssertNil(change?.boundary)
        XCTAssertEqual(change?.withdrawnIntegrations, [.obsidian])
    }

    func testStateSurvivesModelRecreation() async {
        // Fold/unfold or relaunch: a new model over the same store sees the same active + pending.
        let (model, store) = await makeModel()
        await model.setMoods(["Calm"])
        await model.setBriefing { $0.targetSeconds = 240 }
        let (again, _) = await makeModel(store: store)
        XCTAssertEqual(again.state, model.state)
        XCTAssertEqual(again.status(for: .briefing), .pendingBoundary(.nextBriefing))
    }

    func testDiscardPendingChanges() async {
        let (model, _) = await makeModel()
        await model.setEnergy(0.9)
        await model.discardPendingChanges()
        XCTAssertFalse(model.hasPendingChanges)
        XCTAssertEqual(model.status(for: .energy), .idle)
    }

    func testPreviewModelIsLoaded() async {
        let model = await StationConfigurationModel.preview()
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertEqual(model.integrationStatus(.calendar), .on)
        XCTAssertEqual(model.integrationStatus(.shareInbox), .consentReviewRequired)
        XCTAssertEqual(model.plannableBriefingSections, [.calendar])
    }
}
