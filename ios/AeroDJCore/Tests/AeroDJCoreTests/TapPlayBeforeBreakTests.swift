import XCTest
@testable import AeroDJCore

/// P0 build 8: a song tap must reach play without waiting on DJ break preparation.
@MainActor
final class TapPlayBeforeBreakTests: XCTestCase {

    /// Voice provider that never finishes — models the Release OnDeviceSpeechProvider hang
    /// (Fry #77) without touching that file. Prep must not gate the play request.
    private struct NeverCompletingVoice: VoiceProvider {
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    private struct PacedVoice: VoiceProvider {
        var secondsPerWord: Double = 0.01
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            let words = max(1, SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count)
            return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * secondsPerWord,
                                 billableUnits: 0, provider: "device", cacheKey: nil)
        }
    }

    /// Resume-able wait for mid-setup races (commentary off while queueStarted is held open).
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                if opened {
                    lock.unlock()
                    cont.resume()
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }
        func open() {
            lock.lock()
            opened = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    private func tracks(_ n: Int) -> [DJTrack] {
        (0..<n).map { DJTrack(id: "t\($0)", title: "T\($0)", artist: "A\($0)") }
    }

    private func session(voice: any VoiceProvider,
                         requestedIntegrations: Set<StationIntegration> = []) async
    -> (DJBreakSession, DJPresentationStore, StationConfigurationModel) {
        let config = StationConfiguration(commentary: .frequent,
                                          requestedIntegrations: requestedIntegrations)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: voice, voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await session.start()
        return (session, dj, station)
    }

    func testTapPlaySequenceRunsPlayBeforeBreakPrep() async throws {
        var order: [String] = []
        let started = expectation(description: "break prep scheduled after play")
        let hang = Gate()
        let prepTask = try await TapPlaySequence.run(
            play: { order.append("play") },
            scheduleBreakPrep: {
                order.append("breakPrep-start")
                started.fulfill()
                return Task { @MainActor in
                    await hang.wait()
                    order.append("breakPrep-done")
                }
            })
        await fulfillment(of: [started], timeout: 1.0)
        XCTAssertEqual(order, ["play", "breakPrep-start"],
                       "play must finish before break prep is scheduled; prep must not be awaited")
        XCTAssertFalse(order.contains("breakPrep-done"), "must not await hung prep")
        hang.open()
        await prepTask.value
        XCTAssertEqual(order, ["play", "breakPrep-start", "breakPrep-done"])
    }

    func testBeginQueueInBackgroundDoesNotBlockAndSongStartsWhilePrepHangs() async throws {
        let (session, dj, _) = await session(voice: NeverCompletingVoice())
        var playReached = false

        // Hold planning open so the tap path can prove it does not await it.
        session.testBeforeQueueStarted = {
            try? await Task.sleep(for: .seconds(30))
        }

        // Mirror PlaybackActions: play first, then schedule break prep via TapPlaySequence.
        let setup = try await TapPlaySequence.run(
            play: { playReached = true },
            scheduleBreakPrep: {
                session.beginQueueInBackground(tracks(8))
            })
        XCTAssertTrue(playReached, "play path finished without awaiting break prep")
        for _ in 0..<100 where !session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests,
                      "setup is in flight; song path must not wait on it")

        // Song start is reported while prep is still hung — stash + replay later.
        await session.songStarted(index: 0, remaining: .seconds(180))
        XCTAssertTrue(session.queueSetupIsPendingForTests, "still must not block on prep")

        // Cancel the hung planning; a real voice hang is Fry #77 / Echo's beat.
        setup.cancel()
        session.cancelBackgroundQueueSetup()
        XCTAssertFalse(session.queueSetupIsPendingForTests)

        // With a never-completing preparer after a completed plan: boundary skips, never waits.
        session.testBeforeQueueStarted = nil
        await session.queueStarted(tracks(8))
        await session.songStarted(index: 0, remaining: .seconds(180))
        let outcome = await session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome, "slow/hung intro break is deferred/skipped, never awaited")
        await session.stop()
        _ = dj
    }

    func testSlowIntroBreakIsSkippedAtBoundaryNotAwaited() async throws {
        let (session, _, _) = await session(voice: NeverCompletingVoice())
        await session.queueStarted(tracks(8))
        await session.songStarted(index: 0, remaining: .seconds(180))
        // Boundary arrives while render is still in flight: skip, do not wait.
        let outcome = await session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(outcome, "not ready at boundary → music continues")
        await session.stop()
    }

    func testBackgroundQueueSetupCancelledOnStop() async throws {
        let (session, _, _) = await session(voice: NeverCompletingVoice())
        session.testBeforeQueueStarted = {
            try? await Task.sleep(for: .seconds(30))
        }
        let setup = session.beginQueueInBackground(tracks(8))
        for _ in 0..<100 where !session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests)
        await session.stop()
        XCTAssertFalse(session.queueSetupIsPendingForTests)
        XCTAssertTrue(setup.isCancelled)
    }

    func testBackgroundQueueSetupCancelledOnDetach() async throws {
        let (session, _, _) = await session(voice: NeverCompletingVoice())
        session.testBeforeQueueStarted = {
            try? await Task.sleep(for: .seconds(30))
        }
        let setup = session.beginQueueInBackground(tracks(8))
        for _ in 0..<100 where !session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests)
        session.detach()
        XCTAssertFalse(session.queueSetupIsPendingForTests)
        XCTAssertTrue(setup.isCancelled)
    }

    func testNewerTapCancelsPriorBackgroundQueueSetup() async throws {
        let (session, _, _) = await session(voice: PacedVoice())
        let firstGate = Gate()
        session.testBeforeQueueStarted = { await firstGate.wait() }
        let firstTracks = tracks(4)
        let first = session.beginQueueInBackground(firstTracks)
        for _ in 0..<100 where !session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests)
        session.testBeforeQueueStarted = nil
        let secondTracks = tracks(6)
        let second = session.beginQueueInBackground(secondTracks)
        // First task was cancelled by the newer begin; opening the gate is harmless.
        firstGate.open()
        await first.value
        await second.value
        XCTAssertEqual(session.testQueueTrackIDs, secondTracks.map(\.id),
                       "newer tap's queue must win")
        XCTAssertFalse(session.plannedBoundaries.isEmpty,
                       "second tap plans breaks under frequent commentary")
        await session.stop()
    }

    /// Sentinel P2: commentary off mid-setup must not drop the new queue. Setup finishes
    /// with current settings → new tracks planned, no speech.
    func testCommentaryOffMidSetupPlansNewQueueWithNoSpeech() async throws {
        let (session, _, station) = await session(voice: PacedVoice())
        let newTracks = tracks(8)
        let gate = Gate()
        session.testBeforeQueueStarted = { await gate.wait() }
        let setup = session.beginQueueInBackground(newTracks)
        for _ in 0..<100 where !session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests)

        await station.setCommentary(.off)
        // Give the change stream a turn to reach stationChanged.
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests,
                      "commentary off must not cancel in-flight tap queue setup")
        XCTAssertFalse(setup.isCancelled)

        gate.open()
        await setup.value
        XCTAssertFalse(session.queueSetupIsPendingForTests)
        XCTAssertEqual(session.testQueueTrackIDs, newTracks.map(\.id),
                       "new queue tracks must be applied after commentary-off mid-setup")
        XCTAssertTrue(session.plannedBoundaries.isEmpty,
                      "commentary off → talkFraction 0 → no speech planned")
        await session.stop()
    }

    /// After setup finished, commentary off still cancels voice and replans with no speech.
    func testCommentaryOffAfterSetupReplansWithNoSpeech() async throws {
        let (session, _, station) = await session(voice: PacedVoice())
        let newTracks = tracks(8)
        await session.beginQueueInBackground(newTracks).value
        XCTAssertEqual(session.testQueueTrackIDs, newTracks.map(\.id))
        XCTAssertFalse(session.plannedBoundaries.isEmpty,
                       "frequent commentary plans breaks before turn-off")
        await station.setCommentary(.off)
        for _ in 0..<200 where !session.plannedBoundaries.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.testQueueTrackIDs, newTracks.map(\.id))
        XCTAssertTrue(session.plannedBoundaries.isEmpty,
                      "commentary off after setup replans with no speech")
        await session.stop()
    }


    /// Sentinel P1: withdrawing an integration while tap setup is pending must not let
    /// tap-time ConnectionItem snapshots plan or speak that source. Early return skips
    /// replan only — withdrawal still clears briefing and is applied when setup finishes.
    func testWithdrawnIntegrationMidSetupDropsBriefingAndSourceCues() async throws {
        let itemID = UUID()
        let cue = NarrationCue(
            id: UUID(), order: 0, group: 0, kind: .upcomingEvent, text: "Standup at 10",
            estimatedSeconds: 2, maxSeconds: 4, sourceItemID: itemID, source: .calendar,
            provenance: "cal")
        let handoff = NarrationHandoff(cues: [cue], maxSpokenSeconds: 150, experienceSeconds: 300)
        let item = ConnectionItem(id: itemID, integration: .calendar, title: "Standup",
                                  state: .approved, sensitivity: .medium)

        let (session, _, station) = await session(voice: PacedVoice(),
                                                  requestedIntegrations: [.calendar])
        let gate = Gate()
        session.testBeforeQueueStarted = { await gate.wait() }
        let setup = session.beginQueueInBackground(tracks(8), briefing: handoff, sources: [item])
        for _ in 0..<100 where !session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests)

        await station.setIntegration(.calendar, requested: false)
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests,
                      "withdrawal must not cancel in-flight tap queue setup")
        XCTAssertTrue(session.testBriefingIsNil,
                      "withdrawal must clear briefing immediately, even while setup is pending")

        gate.open()
        await setup.value
        XCTAssertFalse(session.queueSetupIsPendingForTests)
        XCTAssertTrue(session.testBriefingIsNil,
                      "deferred setup must not re-introduce the tap-time briefing after withdrawal")
        XCTAssertFalse(session.testPlannedSourceItemIDs.contains(itemID),
                       "no cue from the withdrawn integration may be planned")
        await session.stop()
    }

    func testConsentFilterStillRunsBeforePersonalCuesReachSession() async throws {
        // ApprovedShowHandoff.forQueue drops non-narratable rows before queueStarted.
        let approvedID = UUID()
        let blockedID = UUID()
        let approved = NarrationCue(
            id: UUID(), order: 0, group: 0, kind: .upcomingEvent, text: "Standup at 10",
            estimatedSeconds: 2, maxSeconds: 4, sourceItemID: approvedID, source: .calendar,
            provenance: "cal")
        let blocked = NarrationCue(
            id: UUID(), order: 1, group: 1, kind: .note, text: "Secret note",
            estimatedSeconds: 2, maxSeconds: 4, sourceItemID: blockedID, source: .obsidian,
            provenance: "note")
        let handoff = ApprovedShowHandoff(
            isMorningShow: true,
            approved: NarrationHandoff(cues: [approved, blocked], maxSpokenSeconds: 150, experienceSeconds: 300),
            revokedOrUnapproved: false,
            connectionItems: [
                ConnectionItem(id: approvedID, integration: .calendar, title: "Standup", state: .approved),
                ConnectionItem(id: blockedID, integration: .obsidian, title: "Secret", state: .revoked),
            ])
        let filtered = try XCTUnwrap(handoff.forQueue())
        XCTAssertEqual(filtered.cues.filter(\.isContent).map(\.sourceItemID), [approvedID])
        XCTAssertFalse(filtered.cues.contains { $0.sourceItemID == blockedID })
    }

    func testRemotePlayGateMatchesPlayIfStillAllowedHoldRule() {
        XCTAssertEqual(
            RemotePlayGate.admit(mayAutoResume: true, userWantsPlayback: true),
            .keepPlaying)
        XCTAssertEqual(
            RemotePlayGate.admit(mayAutoResume: false, userWantsPlayback: true),
            .pauseBecauseHeld,
            "lock-screen play while held must not keep audio running")
        XCTAssertEqual(
            RemotePlayGate.admit(mayAutoResume: false, userWantsPlayback: false),
            .pauseBecauseHeld)
    }
}

extension DJBreakSession {
    var queueSetupIsPendingForTests: Bool { testQueueSetupPending }
}
