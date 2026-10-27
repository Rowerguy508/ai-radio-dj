import XCTest
@testable import AeroDJCore

// atlas/commentary-off-stops-speech (privacy P1, Sentinel): turning commentary to `.off` (no
// Save, #110's `.immediate` path) stops a DJ break that is handed out or speaking right away,
// through the same `onBreakMustStop` hook a purge uses, and music is handed back. Turning
// commentary on never starts a break. Real station, session and preparer; $0 on-device voice.
// The adapter side is modelled with Core's `ActiveBreakController` (speaking) and
// `PendingPlayStop` (handed out), the same types `InterludePlaybackAdapter` uses. -Atlas

private struct OffTestVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(text.utf8), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class CommentaryOffStopsSpeakingTests: XCTestCase {
    @MainActor final class Adapter {
        var reasons: [InterludeStopReason] = []
        var tags: [Int?] = []
        let clip = ActiveBreakController()
        var pending = PendingPlayStop()
        var speaking = false
        /// What `stopCurrentInterlude` does: a playing clip halts (revoke path, resumes music
        /// once); a handed-out play is held so `begin` starts no audio and resumes music.
        func stop(_ reason: InterludeStopReason, _ tag: Int?) {
            reasons.append(reason)
            tags.append(tag)
            if speaking { clip.stopActiveBreak(reason: reason, mayAutoResume: true) }
            else { _ = pending.stop(reason: reason, afterTrack: tag, mayAutoResume: true) }
        }
    }

    private struct Rig {
        let session: DJBreakSession
        let station: StationConfigurationModel
        let dj: DJPresentationStore
        let adapter: Adapter
    }

    private func rig(_ config: StationConfiguration = .init(commentary: .frequent)) async -> Rig {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: OffTestVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        let adapter = Adapter()
        session.onBreakMustStop = { [adapter] reason, tag in adapter.stop(reason, tag) }
        await session.start()
        return Rig(session: session, station: station, dj: dj, adapter: adapter)
    }

    private func until(_ condition: @MainActor () -> Bool, _ message: String) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func breakZeroReady(_ r: Rig) -> Bool {
        if case .ready(0, _, _) = r.dj.state { true } else { false }
    }

    /// Queue started, song 0 playing, break 0 rendered and handed out at the natural end.
    private func handedOut(_ r: Rig) async throws -> PreparedDJBreak {
        await r.session.queueStarted(djTracks(12))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ breakZeroReady(r) }, "precondition: break 0 is prepared")
        r.adapter.pending.handOut(afterTrack: 0)       // PlayerView hands out before awaiting
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        return try XCTUnwrap(handed, "precondition: break 0 handed out")
    }

    /// Nothing later is handed out: commentary is off, so nothing more is spoken.
    private func assertNothingMoreSpoken(_ r: Rig) async {
        // The stop is synchronous; the replan runs after `await preparer.cancelAll()`, so wait
        // for it rather than racing it (failed on the macOS simulator at 8176236). -Atlas
        await until({ r.session.plannedBoundaries.isEmpty }, "replan with commentary off has finished")
        XCTAssertEqual(r.session.plannedBoundaries, [], "no break planned with commentary off")
        for k in 1..<11 {
            await r.session.songStarted(index: k, remaining: .seconds(180))
            let b = await r.session.naturalBoundary(afterTrack: k)
            XCTAssertNil(b, "nothing is spoken after song \(k)")
        }
    }

    func testCommentaryOffWithoutSaveStopsTheSpeakingBreakAndHandsBackToMusic() async throws {
        let r = await rig()
        _ = try await handedOut(r)
        _ = r.adapter.pending.begin(afterTrack: 0, mayAutoResume: true)
        r.adapter.clip.play()
        r.adapter.speaking = true
        r.session.playbackStarted(afterTrack: 0)
        guard case .speaking = r.dj.state else { return XCTFail("precondition: the line is on air") }

        await r.station.setCommentary(.off)
        XCTAssertFalse(r.station.hasUnsavedChanges, "commentary off commits without Save")
        await until({ r.adapter.clip.playerStops == 1 }, "the speaking line stops without Save")
        XCTAssertEqual(r.adapter.reasons, [.sourceRevoked], "same stop path as a purge, exactly once")
        XCTAssertEqual(r.adapter.tags, [nil], "untagged, as in purge")
        XCTAssertEqual(r.adapter.clip.end, .revoked)
        XCTAssertEqual(r.adapter.clip.resumes, 1, "music hand-back is requested once")

        r.session.playbackFinished(afterTrack: 0)       // the adapter reports the stopped end
        await assertNothingMoreSpoken(r)
        XCTAssertEqual(r.adapter.reasons.count, 1, "no further stops")
    }

    func testCommentaryOffWhileHandedOutButNotSpeakingCancelsThePlayAndResumesMusic() async throws {
        let r = await rig()
        _ = try await handedOut(r)
        XCTAssertFalse(r.dj.state.isLive, "precondition: handed out, no audio yet")

        await r.station.setCommentary(.off)
        XCTAssertFalse(r.station.hasUnsavedChanges)
        await until({ r.adapter.reasons.count == 1 }, "the handed-out break is stopped without Save")
        XCTAssertEqual(r.adapter.reasons, [.sourceRevoked])
        let effect = r.adapter.pending.begin(afterTrack: 0, mayAutoResume: true)
        XCTAssertFalse(effect.startAudio, "the handed-out break never starts audio")
        XCTAssertTrue(effect.resumeMusic, "music is handed back")

        r.session.playbackFinished(afterTrack: 0)
        await assertNothingMoreSpoken(r)
        XCTAssertEqual(r.adapter.reasons.count, 1)
    }

    /// Commentary goes off while `naturalBoundary` is suspended, before the on-air marker
    /// exists: the change stream has nothing to stop, so the boundary must not hand it out.
    /// (The change stream is detached so the prepared break is still there at the boundary.)
    func testCommentaryOffBeforeHandOutIsNotHandedOut() async throws {
        let r = await rig()
        await r.session.queueStarted(djTracks(12))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await until({ breakZeroReady(r) }, "precondition: break 0 is prepared")
        r.session.detach()
        await r.station.setCommentary(.off)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(handed, "commentary is off at hand-out: music plays at once")
        XCTAssertEqual(r.adapter.reasons, [], "nothing was on air")
    }

    func testBriefingOffDoesNotStopANonBriefingBreak() async throws {
        let r = await rig()
        _ = try await handedOut(r)
        r.session.playbackStarted(afterTrack: 0)
        guard case .speaking(0, false) = r.dj.state else { return XCTFail("precondition: generic line on air") }
        var changes = r.station.changes().makeAsyncIterator()
        await r.station.setBriefing { $0.enabled = false }
        let next = await changes.next()
        let change = try XCTUnwrap(next)
        await r.session.stationChanged(change)
        XCTAssertEqual(r.adapter.reasons, [], "a line with no briefing content keeps playing")
    }

    func testTurningCommentaryOnNeverStartsABreak() async throws {
        let r = await rig(.init(commentary: .off))
        await r.session.queueStarted(djTracks(12))
        await r.session.songStarted(index: 0, remaining: .seconds(180))
        await r.station.setCommentary(.frequent)
        await r.station.saveChanges()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(r.adapter.reasons, [], "no stop and no start")
        XCTAssertFalse(r.dj.state.isLive)
        let handed = await r.session.naturalBoundary(afterTrack: 0)
        XCTAssertNil(handed, "turning commentary on does not create a break for the playing song")
    }
}
