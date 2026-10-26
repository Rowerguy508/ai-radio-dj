import XCTest
@testable import AeroDJCore

// fry/consent-purge-v2 (supersedes #73): a revoke or purge reaches a DJ line already on air
// through `DJBreakSession.purge` -> `onBreakMustStop` (untagged), and drops a break that is
// only prepared. Real session, preparer, Connections and purger; $0 on-device voice. -Fry

private struct PlainVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class ConsentPurgeOnAirTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let dj: DJPresentationStore
        let connections: ConnectionsModel
        let clip: ActiveBreakController
        let tags: () -> [Int?]
        let reasons: () -> [InterludeStopReason]
        let item: UUID
        let source: ConnectionItem
        /// Approved in Connections, but no break uses it.
        let other: UUID
    }

    /// Hook routed to the player as AppDependencies does; the purger is the one Connections uses.
    private func rig() async -> Rig {
        let item = UUID()
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let cache = InMemoryAudioCache()
        let revocations = NarrationRevocations()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: PlainVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: revocations)
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        let clip = ActiveBreakController()
        final class Tags { var all: [Int?] = []; var reasons: [InterludeStopReason] = [] }
        let tags = Tags()
        session.onBreakMustStop = { reason, tag in
            tags.all.append(tag)
            tags.reasons.append(reason)
            clip.stopActiveBreak(reason: reason, mayAutoResume: true)
        }
        let purger = NarrationPurger(cache: cache, preparer: preparer, session: session, revocations: revocations,
                                     feed: NarrationPurgeFeed())
        session.purger = purger
        await session.start()
        let source = ConnectionItem(id: item, integration: .obsidian, title: "[TEST] note", state: .approved, sensitivity: .low)
        let other = ConnectionItem(id: UUID(), integration: .obsidian, title: "[TEST] other note", state: .approved,
                                   sensitivity: .low)
        let connections = ConnectionsModel(station: station, sourceReader: StaticConnectionSourceReader(),
                                           providers: [InMemoryConnectionItemProvider(integration: .obsidian, items: [source, other])],
                                           purger: purger)
        await connections.refresh()
        return Rig(session: session, dj: dj, connections: connections, clip: clip, tags: { tags.all }, reasons: { tags.reasons }, item: item, source: source, other: other.id)
    }

    private func briefing(_ item: UUID) -> NarrationHandoff {
        NarrationHandoff(cues: [NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "From your notes: water the plants.",
                                             estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .obsidian,
                                             provenance: "fixture:n1")],
                         maxSpokenSeconds: 60, experienceSeconds: 600)
    }

    /// Bounded wait (as the other suites' `until`): fails with `message` instead of hanging.
    private func until(_ condition: @MainActor () -> Bool, _ message: String) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func breakZeroIsReady(_ r: Rig) -> Bool {
        if case .ready(0, true, _) = r.dj.state { true } else { false }
    }

    /// Queue started with the item's note in break 0; song 0 playing; break 0 rendered (`.ready`).
    private func ready(_ r: Rig) async {
        await r.session.queueStarted(djTracks(12), briefing: briefing(r.item), sources: [r.source])
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ breakZeroIsReady(r) }, "break 0 with the briefing is prepared")
    }

    /// Every later boundary: nothing handed out speaks about `item`.
    private func assertNoLaterCue(_ r: Rig, from first: Int) async {
        for k in first..<11 {
            await r.session.songStarted(index: k, remaining: .seconds(180))
            if let b = await r.session.naturalBoundary(afterTrack: k) {
                XCTAssertFalse(b.cues.contains { $0.sourceItemID == r.item }, "no later cue from the revoked source (after \(k))")
                r.session.playbackStarted(afterTrack: k)
                r.session.playbackFinished(afterTrack: k)
            }
        }
    }

    /// Echo (1): revoke while `.speaking` stops the line mid-line, exactly once, untagged.
    func testRevokeWhileSpeakingStopsTheLineOnceAndTheSourceNeverAirsAgain() async throws {
        let r = await rig()
        await ready(r)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertTrue(try XCTUnwrap(handed).cues.contains { $0.sourceItemID == r.item })
        r.clip.play()
        r.session.playbackStarted(afterTrack: 0)
        guard case .speaking = r.dj.state else { return XCTFail("precondition: the line is on air") }

        let result = await r.connections.perform(.revoke, on: r.item)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(r.clip.playerStops, 1, "the line on air is stopped in the revoke")
        XCTAssertEqual(r.clip.end, .revoked)
        XCTAssertEqual(r.tags(), [nil], "untagged stop (TODO atlas/interlude-stop-hardening)")

        r.session.purge(sourceItemIDs: [r.item])           // a second purge of the same source
        await r.connections.refresh()
        XCTAssertEqual(r.clip.playerStops, 1, "exactly once")
        XCTAssertEqual(r.tags().count, 1)
        r.session.playbackFinished(afterTrack: 0)          // the adapter reports the revoked end
        await assertNoLaterCue(r, from: 1)
        XCTAssertEqual(r.tags().count, 1, "no further stops")
    }

    /// Echo (2): revoke while the break is only `.ready` drops it: it never plays, nothing to stop.
    func testRevokeWhileReadyDropsThePreparedBreakSoItNeverPlays() async throws {
        let r = await rig()
        await ready(r)
        let result = await r.connections.perform(.revoke, on: r.item)
        XCTAssertNoThrow(try result.get())
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(handed, "the prepared break built from the revoked item never plays")
        XCTAssertEqual(r.clip.playerStops, 0)
        XCTAssertEqual(r.tags(), [], "nothing was on air, so no stop")
        await assertNoLaterCue(r, from: 1)
    }

    /// Sentinel (#91, non-blocking): purging or revoking an item the speaking break does not use
    /// leaves it alone: no stop, and the line keeps playing.
    func testRevokingAnUnrelatedItemWhileSpeakingDoesNotStopTheBreak() async throws {
        let r = await rig()
        await ready(r)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertFalse(try XCTUnwrap(handed).cues.contains { $0.sourceItemID == r.other }, "precondition: not used")
        r.clip.play()
        r.session.playbackStarted(afterTrack: 0)
        guard case .speaking = r.dj.state else { return XCTFail("precondition: the line is on air") }

        let result = await r.connections.perform(.revoke, on: r.other)
        XCTAssertNoThrow(try result.get())
        r.session.purge(sourceItemIDs: [UUID()])            // and a purge of an id no one uses
        XCTAssertEqual(r.tags(), [], "onBreakMustStop never fires")
        XCTAssertEqual(r.clip.playerStops, 0)
        guard case .speaking = r.dj.state else { return XCTFail("the break keeps playing") }
        r.session.playbackFinished(afterTrack: 0)
        XCTAssertEqual(r.tags(), [])
    }

    /// Same for a break handed out to the player but not yet audible: it still starts.
    func testRevokingAnUnrelatedItemAfterHandOutDoesNotStopTheBreak() async throws {
        let r = await rig()
        await ready(r)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertTrue(try XCTUnwrap(handed).cues.contains { $0.sourceItemID == r.item })

        let result = await r.connections.perform(.revoke, on: r.other)
        XCTAssertNoThrow(try result.get())
        r.session.purge(sourceItemIDs: [UUID()])
        XCTAssertEqual(r.tags(), [], "onBreakMustStop never fires")
        r.clip.play()
        r.session.playbackStarted(afterTrack: 0)
        guard case .speaking = r.dj.state else { return XCTFail("the handed-out break still plays") }
        XCTAssertEqual(r.clip.playerStops, 0)
    }

    /// Atlas (#91 review): queue 1's break for track k is handed out; queue 2 starts and hands
    /// out its own break for the same k. Purging queue 1's source never reaches queue 2's break,
    /// whether the purge lands before or after queue 2's hand-out.
    func testPurgingTheOldQueuesSourceDoesNotStopTheNewQueuesBreak() async throws {
        let r = await rig()
        await ready(r)
        let first = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertTrue(try XCTUnwrap(first).cues.contains { $0.sourceItemID == r.item })

        let other = ConnectionItem(id: r.other, integration: .obsidian, title: "[TEST] other note", state: .approved,
                                   sensitivity: .low)
        await r.session.queueStarted(djTracks(12), briefing: briefing(r.other), sources: [other])
        XCTAssertEqual(r.tags(), [nil], "the new queue stops queue 1's handed-out break once")
        XCTAssertNotEqual(r.reasons().first, .sourceRevoked, "a queue change is not logged as a revoke")
        r.session.purge(sourceItemIDs: [r.item])            // before queue 2's hand-out
        XCTAssertEqual(r.tags(), [nil], "the purge adds no stop: queue 1's break ended with its queue")
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        // songStarted moves the store off queue 1's stale `.ready` before this wait.
        await until({ breakZeroIsReady(r) }, "queue 2's break 0 is prepared")
        let second = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertTrue(try XCTUnwrap(second, "queue 2's break for the same k").cues.contains { $0.sourceItemID == r.other })
        r.clip.play()
        r.session.playbackStarted(afterTrack: 0)

        r.session.purge(sourceItemIDs: [r.item])            // after queue 2's hand-out
        XCTAssertEqual(r.tags(), [nil], "onBreakMustStop never fires for queue 2's break (only the queue-change stop)")
        XCTAssertEqual(r.clip.playerStops, 0)
        guard case .speaking = r.dj.state else { return XCTFail("queue 2's break keeps playing") }
    }

    /// Sentinel (#91, be81931): a new queue never talks over its new song. The speaking line is
    /// stopped by the time `queueStarted` returns, exactly once; revoking its source later adds no
    /// second stop, and the new queue never narrates it.
    func testANewQueueStopsTheSpeakingLineOnceAndARevokeAddsNoSecondStop() async throws {
        let r = await rig()
        await ready(r)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertTrue(try XCTUnwrap(handed).cues.contains { $0.sourceItemID == r.item })
        r.clip.play()
        r.session.playbackStarted(afterTrack: 0)
        guard case .speaking = r.dj.state else { return XCTFail("precondition: the line is on air") }

        await r.session.queueStarted(djTracks(12))
        XCTAssertEqual(r.tags(), [nil], "stopped once, untagged, by the time queueStarted returns")
        XCTAssertNotEqual(r.reasons().first, .sourceRevoked, "a queue change is not logged as a revoke")
        XCTAssertEqual(r.clip.playerStops, 1, "the line is not talking over the new queue")

        let result = await r.connections.perform(.revoke, on: r.item)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(r.tags(), [nil], "no second stop")
        XCTAssertEqual(r.clip.playerStops, 1)
        r.session.playbackFinished(afterTrack: 0)          // the adapter reports the stopped end
        await assertNoLaterCue(r, from: 1)
        XCTAssertEqual(r.tags(), [nil], "nothing else stops")
    }
}

/// Both app compositions must set the purger and the stop hook before playback. -Fry
@MainActor
final class DJSessionWiringTests: XCTestCase {
    func testIsWiredForPurgeNeedsBothThePurgerAndTheStopHook() async {
        let station = StationConfigurationModel(store: InMemoryStationConfigurationStore(), consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: PlainVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: DJCadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore())
        XCTAssertFalse(session.isWiredForPurge, "neither set")
        session.purger = NarrationPurger(cache: InMemoryAudioCache(), preparer: preparer, session: session)
        XCTAssertFalse(session.isWiredForPurge, "stop hook unset")
        session.onBreakMustStop = { _, _ in }
        XCTAssertTrue(session.isWiredForPurge)
        session.purger = nil
        XCTAssertFalse(session.isWiredForPurge, "purger unset")
    }

    /// AppDependencies is in the app target (not built on Linux): read its source and check that
    /// `live()` and `testStation()` each arm the stop hook (`makeInterlude`), set the purger and
    /// assert the wiring before returning.
    func testBothAppCompositionsSetThePurgerAndTheStopHook() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AeroDJ/AppDependencies.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        func body(_ signature: String) throws -> Substring {
            let start = try XCTUnwrap(text.range(of: signature), "\(signature) exists").upperBound
            let end = text.range(of: "\n    private static func", range: start..<text.endIndex)?.lowerBound ?? text.endIndex
            return text[start..<end]
        }
        for name in ["private static func live()", "private static func testStation()"] {
            let b = try body(name)
            XCTAssertTrue(b.contains("makeInterlude(session: djSession"), "\(name): stop hook armed")
            XCTAssertTrue(b.contains("djSession.purger = purger"), "\(name): purger set")
            XCTAssertTrue(b.contains("precondition(djSession.isWiredForPurge"), "\(name): wiring asserted")
            XCTAssertTrue(b.contains("purger: purger)"), "\(name): Connections uses the same purger")
        }
        XCTAssertTrue(text.contains("session.onBreakMustStop = hook"), "makeInterlude assigns the session hook")
    }
}
