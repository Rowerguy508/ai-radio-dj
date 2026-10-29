import XCTest
@testable import AeroDJCore

/// Voice whose measured duration is `secondsPerWord` per word.
private struct PacedVoice: VoiceProvider {
    var secondsPerWord: Double = 0.4
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * secondsPerWord,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

/// In-memory cache that remembers which keys were stored.
private actor RecordingCache: AudioCache {
    private let inner = InMemoryAudioCache()
    private(set) var keys: [String] = []
    func audio(for key: String) async -> CachedAudio? { await inner.audio(for: key) }
    func store(_ audio: CachedAudio, for key: String) async { keys.append(key); await inner.store(audio, for: key) }
    func purge(sourceItemIDs: Set<UUID>) async { await inner.purge(sourceItemIDs: sourceItemIDs) }
    func purgeExpired() async { await inner.purgeExpired() }
    func purgeAllPersonal() async { await inner.purgeAllPersonal() }
    func remaining() async -> [CachedAudio] {
        var out: [CachedAudio] = []
        for key in keys { if let a = await inner.audio(for: key) { out.append(a) } }
        return out
    }
}

@MainActor
final class DJBreakSessionTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let station: StationConfigurationModel
        let dj: DJPresentationStore
        let preparer: DJBreakPreparer
        let cache: RecordingCache
    }

    /// `frequent` with the default spacing talks at every third boundary (0, 3, 6, …), so plans are predictable.
    private func rig(_ config: StationConfiguration = .init(commentary: .frequent), voice: PacedVoice = .init()) async -> Rig {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let cache = RecordingCache()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: voice, voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await session.start()
        return Rig(session: session, station: station, dj: dj, preparer: preparer, cache: cache)
    }

    private func until(_ condition: @MainActor () -> Bool, _ message: String = "") async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    func testEmptyLineAfterHandoffLeavesReadyAndResumesMusic() async {
        await assertUnplayedBreakLeavesReady(.emptyLine, afterTrack: 4)
    }

    func testAdapterRefusesAnUnplayableBreakAndResumesMusic() async {
        await assertUnplayedBreakLeavesReady(.notPlayable, afterTrack: 4)
    }

    func testClipThatFailsToDecodeLeavesReadyAndResumesMusic() async {
        await assertUnplayedBreakLeavesReady(.decodeFailed, afterTrack: 4)
    }

    /// A handed-out break that never starts audio reports `.failed` through the session.
    /// The boundary returns to music. No polling.
    private func assertUnplayedBreakLeavesReady(_ reason: HandedOutBreakSkip, afterTrack: Int) async {
        let r = await rig()
        r.dj.send(.breakReady(afterTrack: afterTrack, includesBriefing: false, seconds: 6))
        XCTAssertEqual(r.dj.studioState, .ready(includesBriefing: false, seconds: 6))

        let effect = HandedOutBreakReport.skipped(reason, afterTrack: afterTrack, mayAutoResume: true)
        XCTAssertEqual(effect.event, .playbackFailed(afterTrack: afterTrack))
        XCTAssertTrue(effect.resume.resumeMusic)
        XCTAssertEqual(effect.resume.audioEvent, .noInterlude)

        r.session.playbackFailed(afterTrack: afterTrack)
        if case .ready = r.dj.studioState {
            XCTFail("\(reason) leaves the handed-out break ready")
        }
        XCTAssertEqual(r.dj.studioState, .failed(.voiceFailed))

        var audio = AudioStateMachine(state: .transition)
        guard let back = effect.resume.audioEvent else {
            XCTFail("\(reason) returns to music")
            return
        }
        XCTAssertEqual(audio.apply(back), .music)
    }

    func testBreakIsPreparedDuringTheSongAndHandedOverAtTheBoundary() async throws {
        let r = await rig()
        await r.session.queueStarted(djTracks(8))
        XCTAssertEqual(r.session.plannedBoundaries.first, 0)
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ if case .ready = r.dj.studioState { true } else { false } }, "ready before the boundary")
        XCTAssertFalse(r.dj.studioState.isOnAir, "ready is not On Air")

        let handed = await r.session.naturalBoundary(afterTrack: 0)
        let prepared = try XCTUnwrap(handed)
        XCTAssertNil(r.session.lastNoBreak, "a handed-out break leaves no skip reason")
        XCTAssertFalse(prepared.clips.isEmpty)
        XCTAssertLessThanOrEqual(prepared.measuredSeconds, 12, "routine cap")
        XCTAssertTrue(prepared.clips.allSatisfy { $0.audio.providerID == "device" }, "$0 on-device voice")
        r.session.playbackStarted(afterTrack: 0)
        XCTAssertTrue(r.dj.studioState.isOnAir, "On Air only after the player confirms audio")
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertEqual(r.dj.studioState, .idle)

        let nothing = await r.session.naturalBoundary(afterTrack: 1)
        XCTAssertNil(nothing, "no break planned: music continues at once")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .notPlanned)
        XCTAssertEqual(r.session.lastNoBreak?.cadencePlanned, false, "the cadence chose silence here")
    }

    func testLateOrCutBreaksAreSkippedAndNeverWait() async {
        let r = await rig()
        await r.session.queueStarted(djTracks(8))
        await r.session.songStarted(index: 0, remaining: .seconds(2))     // inside the 3 s margin
        let late = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(late, "too late to render: skipped, not delayed")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .notPlanned)
        XCTAssertEqual(r.session.lastNoBreak?.cadencePlanned, true, "planned, but never prepared: the trace tells this apart")

        await r.session.songStarted(index: 3, remaining: .seconds(180))
        await until { if case .ready = r.dj.studioState { true } else { false } }
        await r.session.songCut(afterTrack: 3)
        let afterCut = await r.session.naturalBoundary(afterTrack: 3)
        XCTAssertNil(afterCut, "never talk after a cut song")
        XCTAssertEqual(r.session.lastNoBreak?.reason, .notNaturalBoundary)
    }

    func testRoutineBreakOverTwelveSecondsIsSkipped() async {
        let r = await rig(voice: PacedVoice(secondsPerWord: 3))
        await r.session.queueStarted(djTracks(8))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .failed = r.dj.studioState { true } else { false } }
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome)
        XCTAssertEqual(r.dj.studioState, .failed(.voiceFailed))
    }

    func testBriefingBreakMayUseFortyFiveSecondsButNotMore() async throws {
        func handoff(_ itemID: UUID) -> NarrationHandoff {
            let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent,
                                   text: "Coming up: Standup at ten in room four. From your calendar.",
                                   estimatedSeconds: 5, maxSeconds: 30, sourceItemID: itemID, source: .calendar, provenance: "fixture:1")
            return NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600)
        }
        let ok = await rig(voice: PacedVoice(secondsPerWord: 0.8))
        let okBriefing = handoff(UUID())
        await ok.session.queueStarted(djTracks(8), briefing: okBriefing, sources: approvedSources(okBriefing))
        await ok.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = ok.dj.studioState { true } else { false } }
        let handed = await ok.session.naturalBoundary(afterTrack: 0)
        let briefing = try XCTUnwrap(handed)
        XCTAssertTrue(briefing.includesBriefing)
        XCTAssertGreaterThan(briefing.measuredSeconds, 12, "longer than a routine break is fine for a briefing")
        XCTAssertLessThanOrEqual(briefing.measuredSeconds, 45)

        let long = await rig(voice: PacedVoice(secondsPerWord: 2.5))
        let longBriefing = handoff(UUID())
        await long.session.queueStarted(djTracks(8), briefing: longBriefing, sources: approvedSources(longBriefing))
        await long.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .failed = long.dj.studioState { true } else { false } }
        let skipped = await long.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(skipped, "over 45 s: skipped, music continues")
    }

    func testTunerChangesApplyAtTheBoundaryAndNeverToThePlayingSong() async {
        let r = await rig()
        await r.session.queueStarted(djTracks(12))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = r.dj.studioState { true } else { false } }
        let before = r.session.plannedBoundaries

        await r.station.setPlaybackActivity(.holdingSong)
        await r.station.setCommentary(.rare)       // a cadence change: future breaks, after this song
        await r.station.saveChanges()
        XCTAssertEqual(r.station.active.commentary, .frequent, "pending until the boundary")
        XCTAssertEqual(r.session.plannedBoundaries, before, "nothing re-planned mid-song")

        let played = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNotNil(played, "the break prepared for the playing song is untouched")
        XCTAssertEqual(r.station.active.commentary, .rare, "applied at the song boundary")
        XCTAssertEqual(r.station.active.cadence().talkFraction, 0.15)
    }

    func testTurningCommentaryOffDropsPreparedSpeechImmediately() async {
        let r = await rig()
        await r.session.queueStarted(djTracks(12))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = r.dj.studioState { true } else { false } }
        await r.station.setCommentary(.off)
        await r.station.saveChanges()
        await until { r.session.plannedBoundaries.isEmpty }
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome, "off applies now: nothing prepared plays")
        XCTAssertEqual(r.dj.studioState, .idle)
    }

    func testCommentaryOffWithoutSaveDropsPreparedBreakBeforeBoundary() async {
        let r = await rig()
        await r.session.queueStarted(djTracks(12))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = r.dj.studioState { true } else { false } }
        await r.station.setCommentary(.off)
        XCTAssertFalse(r.station.hasUnsavedChanges, "an immediate off leaves nothing to Save")
        await until { r.session.plannedBoundaries.isEmpty }
        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome, "commentary off with no Save: the prepared break never airs")
        XCTAssertEqual(r.dj.studioState, .idle)
    }

    func testRevokeStopsThePlayingBreakWithinOneTick() {
        let clip = ActiveBreakController()
        clip.play()
        let player = clip.currentPlayer
        let onBreakMustStop: (@MainActor (InterludeStopReason, Int?) -> Void) = { reason, _ in
            clip.stopActiveBreak(reason: reason, mayAutoResume: true)
        }
        onBreakMustStop(.sourceRevoked, nil)

        XCTAssertEqual(clip.playerStops, 1, "the player stops before the hook returns, inside one tick")
        XCTAssertTrue(clip.delegateCleared)
        XCTAssertEqual(clip.end, .revoked, "a revoke stop is not a natural end")
        XCTAssertEqual(clip.naturalEnds, 0)
        XCTAssertEqual(clip.resumes, 1, "music resumes once when playback is still allowed")
        if let player { clip.lateDelegate(from: player) }
        XCTAssertEqual(clip.delivered, 0, "a late callback from the stopped player is ignored")
        XCTAssertEqual(clip.resumes, 1, "the late callback must not resume music again")
        XCTAssertEqual(clip.naturalEnds, 0)
    }

    /// `purge` calling the hook is Fry's call site (#73, now fry/consent-purge-v2). The player
    /// behavior above is what that call runs. Unskipped: the call site exists. The setup puts a
    /// break about one item on air, with the hook routed to the player as AppDependencies does;
    /// the assertion is unchanged.
    func testPurgeCallsOnBreakMustStopForThePlayingBreak() async throws {
        let r = await rig()
        let clip = ActiveBreakController()
        r.session.onBreakMustStop = { reason, _ in clip.stopActiveBreak(reason: reason, mayAutoResume: true) }
        let item = UUID()
        let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "From your notes: water the plants.",
                               estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .obsidian, provenance: "fixture:n1")
        let briefing = NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600)
        await r.session.queueStarted(djTracks(8), briefing: briefing, sources: approvedSources(briefing))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ if case .ready(true, _) = r.dj.studioState { true } else { false } }, "the item is in the prepared break")
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNotNil(handed)
        clip.play()
        r.session.playbackStarted(afterTrack: 0)
        r.session.purge(sourceItemIDs: [item])
        XCTAssertEqual(clip.playerStops, 1, "purge stops the playing break once Fry wires onBreakMustStop")
    }

    func testRevokingAnItemRemovesItFromPlannedPreparedAndCachedNarration() async throws {
        let item = UUID()
        let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "From your notes: water the plants.",
                               estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .obsidian, provenance: "fixture:n1")
        let r = await rig()
        let briefing = NarrationHandoff(cues: [cue], maxSpokenSeconds: 60, experienceSeconds: 600)
        await r.session.queueStarted(djTracks(12), briefing: briefing, sources: approvedSources(briefing))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ if case .ready(true, _) = r.dj.studioState { true } else { false } }, "the item is in the prepared break")

        // The path ConnectionsModel uses for revoke/delete.
        let provider = InMemoryConnectionItemProvider(integration: .obsidian, items: [
            ConnectionItem(id: item, integration: .obsidian, title: "[TEST] note", state: .approved)])
        let connections = ConnectionsModel(station: r.station, sourceReader: StaticConnectionSourceReader(),
                                           providers: [provider],
                                           purger: NarrationPurger(cache: r.cache, preparer: r.preparer, session: r.session))
        await connections.refresh()
        _ = await connections.perform(.revoke, on: item)

        let outcome = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome, "the prepared break built from the item never plays")
        for k in 1..<11 {
            await r.session.songStarted(index: k, remaining: .seconds(180))
            if let b = await r.session.naturalBoundary(afterTrack: k) {
                XCTAssertFalse(b.cues.contains { $0.sourceItemID == item }, "never re-planned")
            }
        }
        let stored = await r.cache.keys
        XCTAssertFalse(stored.isEmpty)
        let cached = await r.cache.remaining()
        XCTAssertFalse(cached.contains { $0.sourceItemIDs.contains(item) }, "cached narration purged")
    }

    /// Approved morning briefing passed through `ApprovedShowHandoff.forQueue()` airs once,
    /// at the first eligible boundary. Revoked and unapproved input airs no personal text.
    /// A later show is given only `carryForward.eligibleNextShow`.
    func testApprovedBriefingAirsOnceAndRevokedBriefingNeverAirs() async throws {
        let reviewID = UUID()
        let review = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent,
                                  text: "You've got Design review at 9 AM. From your calendar.",
                                  estimatedSeconds: 6, maxSeconds: 20, sourceItemID: reviewID,
                                  source: .calendar, provenance: "cal:design")
        let noteID = UUID()
        let note = NarrationCue(id: UUID(), order: 2, group: 1, kind: .note,
                                text: "You've also got Grocery list. From your notes.",
                                estimatedSeconds: 5, maxSeconds: 20, sourceItemID: noteID,
                                source: .obsidian, provenance: "note:groceries")
        let morning = NarrationHandoff(cues: [review, note], maxSpokenSeconds: 60, experienceSeconds: 300)
        let rows = [
            ConnectionItem(id: reviewID, integration: .calendar, title: "Design review", state: .approved, sensitivity: .low),
            ConnectionItem(id: noteID, integration: .obsidian, title: "Grocery list", state: .approved, sensitivity: .low),
        ]
        let carry = EditorialCarryForward(report: NarrationScheduleReport(entries: [
            NarrationScheduleEntry(cue: review, outcome: .dropped(.notCarriedForward)),
            NarrationScheduleEntry(cue: note, outcome: .deferred(.noTrackBoundary)),
        ]))

        let approved = ApprovedShowHandoff(isMorningShow: true, approved: morning, revokedOrUnapproved: false,
                                           carryForward: carry, connectionItems: rows)
        XCTAssertEqual(approved.forQueue(), morning)

        let revoked = ApprovedShowHandoff(isMorningShow: true, approved: morning, revokedOrUnapproved: true,
                                          carryForward: carry, connectionItems: rows)
        XCTAssertNil(revoked.forQueue())
        let unapproved = ApprovedShowHandoff(isMorningShow: true, approved: nil, revokedOrUnapproved: false)
        XCTAssertNil(unapproved.forQueue())
        XCTAssertNil(ApprovedShowHandoff.unapproved.forQueue())

        let later = ApprovedShowHandoff(isMorningShow: false, approved: morning, revokedOrUnapproved: false,
                                        carryForward: carry, connectionItems: rows)
        let laterHandoff = try XCTUnwrap(later.forQueue())
        XCTAssertEqual(laterHandoff.cues.map(\.id), [note.id])
        XCTAssertFalse(laterHandoff.cues.contains { $0.id == review.id })

        let show = await rig()
        await show.session.queueStarted(djTracks(8), briefing: approved.forQueue(), sources: approved.connectionItems)
        XCTAssertEqual(show.session.plannedBoundaries.first, 0, "first eligible boundary")
        let firstIDs = try await airedContentIDs(show, after: 0)
        XCTAssertEqual(firstIDs.filter { $0 == review.id }.count, 1)
        XCTAssertEqual(firstIDs.filter { $0 == note.id }.count, 1)
        var laterIDs: [UUID] = []
        for boundary in show.session.plannedBoundaries where boundary != 0 {
            laterIDs += try await airedContentIDs(show, after: boundary)
        }
        XCTAssertFalse(laterIDs.contains(review.id))
        XCTAssertFalse(laterIDs.contains(note.id))

        for blocked in [revoked.forQueue(), unapproved.forQueue()] {
            let quiet = await rig()
            await quiet.session.queueStarted(djTracks(8), briefing: blocked, sources: rows)
            await quiet.session.songStarted(index: 0, remaining: .seconds(180))
            await until { quiet.dj.studioState != .idle }
            let handed = await quiet.session.naturalBoundary(afterTrack: 0)
            let spoken = handed?.cues.map(\.text).joined(separator: " ") ?? ""
            XCTAssertFalse(spoken.contains("Design review"), spoken)
            XCTAssertFalse(spoken.contains("Grocery list"), spoken)
            XCTAssertNotEqual(handed?.includesBriefing, true)
        }

        let nextShow = await rig()
        await nextShow.session.queueStarted(djTracks(8), briefing: later.forQueue(), sources: later.connectionItems)
        let nextIDs = try await airedContentIDs(nextShow, after: 0)
        XCTAssertEqual(nextIDs, [note.id])
        XCTAssertFalse(nextIDs.contains(review.id))
    }

    /// Connections still lists every row. Only `ConnectionItemState.approved`
    /// (`mayBeNarrated`) may be spoken. Each enum case is seeded directly.
    /// `ConsentState.notRequested` is not a case: `resolve` maps it to `.pendingApproval`.
    func testOnlyApprovedConsentStateIsNarrated() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            ConnectionItemState.resolve(consent: .notRequested, expiresAt: nil, now: now, flagged: false, reconfirmed: false),
            .pendingApproval,
            "there is no ConnectionItemState for not-requested consent")
        let approvedID = UUID()
        let pendingID = UUID()
        let flaggedID = UUID()
        let expiredID = UUID()
        let revokedID = UUID()
        let unavailableID = UUID()
        let rows = [
            ConnectionItem(id: pendingID, integration: .calendar, title: "Pending sync", state: .pendingApproval),
            ConnectionItem(id: flaggedID, integration: .obsidian, title: "Flagged memo", state: .flaggedForReview),
            ConnectionItem(id: approvedID, integration: .calendar, title: "Design review", state: .approved, sensitivity: .low),
            ConnectionItem(id: expiredID, integration: .shareInbox, title: "Expired reminder", state: .expired),
            ConnectionItem(id: revokedID, integration: .obsidian, title: "Revoked note", state: .revoked),
            ConnectionItem(id: unavailableID, integration: .calendar, title: "Unavailable calendar",
                           state: .unavailable(.calendarAccess(.denied))),
        ]
        XCTAssertEqual(Set(rows.map { Self.connectionStateCase($0.state) }), Set(Self.everyConnectionStateCase),
                       "the seeded rows cover every ConnectionItemState case")
        for row in rows {
            XCTAssertEqual(row.state.mayBeNarrated, Self.narrationClass(of: row.state) == .spoken)
        }
        XCTAssertEqual(rows.filter { $0.state.mayBeNarrated }.map(\.id), [approvedID])
        XCTAssertEqual(rows.map(\.title),
                       ["Pending sync", "Flagged memo", "Design review", "Expired reminder", "Revoked note", "Unavailable calendar"],
                       "every item state still appears in Connections")

        func cue(_ id: UUID, _ order: Int, _ title: String, _ source: ContextSourceKind) -> NarrationCue {
            NarrationCue(id: UUID(), order: order, group: order, kind: .note,
                         text: "Item \(title) stays in the script.",
                         estimatedSeconds: 4, maxSeconds: 16, sourceItemID: id, source: source, provenance: "row:\(order)")
        }
        let handoff = NarrationHandoff(cues: [
            cue(pendingID, 1, "Pending sync", .calendar),
            cue(flaggedID, 2, "Flagged memo", .obsidian),
            cue(approvedID, 3, "Design review", .calendar),
            cue(expiredID, 4, "Expired reminder", .userShared),
            cue(revokedID, 5, "Revoked note", .obsidian),
            cue(unavailableID, 6, "Unavailable calendar", .calendar),
        ], maxSpokenSeconds: 60, experienceSeconds: 300)
        let show = ApprovedShowHandoff(isMorningShow: true, approved: handoff, revokedOrUnapproved: false, connectionItems: rows)
        let queued = try XCTUnwrap(show.forQueue())
        XCTAssertEqual(queued.cues.compactMap(\.sourceItemID), [approvedID])

        let session = await rig()
        await session.session.queueStarted(djTracks(8), briefing: queued, sources: show.connectionItems)
        await session.session.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = session.dj.studioState { true } else { false } }
        let handedBreak = await session.session.naturalBoundary(afterTrack: 0)
        let handed = try XCTUnwrap(handedBreak)
        let spoken = handed.cues.map(\.text).joined(separator: " ")
        XCTAssertEqual(handed.cues.filter(\.isContent).compactMap(\.sourceItemID), [approvedID])
        XCTAssertTrue(spoken.contains("Design review"), spoken)
        for hidden in ["Pending sync", "Flagged memo", "Expired reminder", "Revoked note", "Unavailable calendar"] {
            XCTAssertFalse(spoken.contains(hidden), spoken)
        }
    }

    /// A new `ConnectionItemState` case fails this switch until it is named here and seeded above.
    private static let everyConnectionStateCase = [
        "pendingApproval", "flaggedForReview", "approved", "expired", "revoked", "unavailable",
    ]

    private static func connectionStateCase(_ state: ConnectionItemState) -> String {
        switch state {
        case .pendingApproval: "pendingApproval"
        case .flaggedForReview: "flaggedForReview"
        case .approved: "approved"
        case .expired: "expired"
        case .revoked: "revoked"
        case .unavailable: "unavailable"
        }
    }

    private enum NarrationClass { case spoken, withheld }

    /// Same exhaustiveness rule: a new case does not compile until it is spoken or withheld.
    private static func narrationClass(of state: ConnectionItemState) -> NarrationClass {
        switch state {
        case .approved: .spoken
        case .pendingApproval, .flaggedForReview, .expired, .revoked, .unavailable: .withheld
        }
    }

    private func airedContentIDs(_ rig: Rig, after boundary: Int) async throws -> [UUID] {
        await rig.session.songStarted(index: boundary, remaining: .seconds(180))
        await until { if case .ready = rig.dj.studioState { true } else { false } }
        let handedBreak = await rig.session.naturalBoundary(afterTrack: boundary)
        let handed = try XCTUnwrap(handedBreak)
        XCTAssertFalse(handed.clips.isEmpty, "the boundary airs prepared audio")
        rig.session.playbackStarted(afterTrack: boundary)
        rig.session.playbackFinished(afterTrack: boundary)
        return handed.cues.filter(\.isContent).map(\.id)
    }
}
