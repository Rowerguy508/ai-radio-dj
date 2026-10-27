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

    private func tracks(_ n: Int) -> [DJTrack] {
        (0..<n).map { DJTrack(id: "t\($0)", title: "T\($0)", artist: "A\($0)") }
    }

    private func session(voice: any VoiceProvider) async -> (DJBreakSession, DJPresentationStore, StationConfigurationModel) {
        let config = StationConfiguration(commentary: .frequent)
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
        let started = expectation(description: "break prep started")
        let hang = Task<Void, Never>.detached {
            try? await Task.sleep(for: .seconds(30))
        }
        let prepTask = try await TapPlaySequence.run(
            policy: .playThenBackgroundBreakPrep,
            play: { order.append("play") },
            breakPrep: {
                order.append("breakPrep-start")
                started.fulfill()
                await hang.value
                order.append("breakPrep-done")
            })
        // Play already finished; give the background task one turn to start.
        await fulfillment(of: [started], timeout: 1.0)
        XCTAssertEqual(order, ["play", "breakPrep-start"],
                       "play must finish before break prep is scheduled; prep must not be awaited")
        XCTAssertFalse(order.contains("breakPrep-done"), "must not await hung prep")
        prepTask.cancel()
        hang.cancel()
    }

    func testLegacyBreakPrepThenPlayStillAwaitableForTests() async throws {
        var order: [String] = []
        _ = try await TapPlaySequence.run(
            policy: .breakPrepThenPlay,
            play: { order.append("play") },
            breakPrep: { order.append("breakPrep") })
        XCTAssertEqual(order, ["breakPrep", "play"])
    }

    func testBeginQueueInBackgroundDoesNotBlockAndSongStartsWhilePrepHangs() async throws {
        let (session, dj, _) = await session(voice: NeverCompletingVoice())
        var playReached = false

        // Hold planning open so the tap path can prove it does not await it.
        session.testBeforeQueueStarted = {
            try? await Task.sleep(for: .seconds(30))
        }

        // Mirror PlaybackActions: play first, then background queue setup.
        playReached = true
        let setup = session.beginQueueInBackground(tracks(8))
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
        // Hold queueStarted open so stop has something in-flight to cancel.
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

    func testBackgroundQueueSetupCancelledWhenCommentaryTurnsOff() async throws {
        let (session, _, station) = await session(voice: NeverCompletingVoice())
        session.testBeforeQueueStarted = {
            try? await Task.sleep(for: .seconds(30))
        }
        let setup = session.beginQueueInBackground(tracks(8))
        for _ in 0..<100 where !session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.queueSetupIsPendingForTests)
        // Immediate privacy reduction: commentary off invalidates prepared breaks and
        // cancels in-flight background tap setup (Sentinel: cancellable prep).
        await station.setCommentary(.off)
        for _ in 0..<200 where session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(session.queueSetupIsPendingForTests,
                       "commentary off must cancel in-flight background queue setup")
        XCTAssertTrue(setup.isCancelled)
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

    func testSongStartedBeforeQueueReadyIsReplayedAfterBackgroundSetup() async throws {
        let (session, dj, _) = await session(voice: PacedVoice())
        let setup = session.beginQueueInBackground(tracks(8))
        // Song reports start before planning finishes.
        await session.songStarted(index: 0, remaining: .seconds(180))
        for _ in 0..<200 where session.queueSetupIsPendingForTests {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await until({
            if case .preparing = dj.studioState { return true }
            if case .ready = dj.studioState { return true }
            return false
        }, "replayed songStarted should start preparing or finish ready")
        setup.cancel()
        await session.stop()
    }

    private func until(_ condition: @MainActor () -> Bool, _ message: String) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }
}

extension DJBreakSession {
    /// Test-only: whether background tap setup has not finished planning.
    var queueSetupIsPendingForTests: Bool { testQueueSetupPending }
}
