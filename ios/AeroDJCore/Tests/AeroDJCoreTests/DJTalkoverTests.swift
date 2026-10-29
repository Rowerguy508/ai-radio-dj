import XCTest
@testable import AeroDJCore

/// DJ talk-over planner and run (owner request on #195, -Fry). Pure: no player, no session.
/// No class-level @MainActor (Linux XCTest discovery).
final class DJTalkoverTests: XCTestCase {
    private let cfg = TalkoverConfig()
    /// Echo's radio-style shape: MAIN 15 s, 0.3 s gap, closing line 3 s.
    private let echoVoice = TalkoverVoice(totalSeconds: 18.3, talkOverStartSeconds: 15.3, talkOverSeconds: 3)

    private func plan(duration: Double? = 210, position: Double = 190, voice: TalkoverVoice? = nil,
                      next: Double? = 200, intro: Double? = nil, flag: Bool = true,
                      config: TalkoverConfig = TalkoverConfig()) -> TalkoverDecision {
        TalkoverPlanner.decide(flag: flag, track: TalkoverTrack(duration: duration, position: position),
                               voice: voice ?? echoVoice, nextTrackDuration: next, introLength: intro, config: config)
    }

    // MARK: Flag

    func testFlagDefaultsOffOutsideOwnerAB() {
        let defaults = UserDefaults(suiteName: "talkover-flag-\(UUID().uuidString)")!
        XCTAssertFalse(DJTalkoverFlag.buildDefault, "swift test is not an owner A/B build")
        XCTAssertFalse(DJTalkoverFlag.isEnabled(defaults: defaults))
        XCTAssertTrue(DJTalkoverFlag.isEnabled(defaults: defaults, buildDefault: true), "owner A/B turns it on")
    }

    func testDefaultsOverrideRollsBackEitherWay() {
        let defaults = UserDefaults(suiteName: "talkover-flag-\(UUID().uuidString)")!
        defaults.set(false, forKey: DJTalkoverFlag.defaultsKey)
        XCTAssertFalse(DJTalkoverFlag.isEnabled(defaults: defaults, buildDefault: true), "rollback on an owner A/B build")
        defaults.set(true, forKey: DJTalkoverFlag.defaultsKey)
        XCTAssertTrue(DJTalkoverFlag.isEnabled(defaults: defaults, buildDefault: false))
    }

    func testFlagOffIsAlwaysAHardBreak() {
        XCTAssertEqual(plan(flag: false), .hardBreak(.flagOff))
    }

    // MARK: Full talk-over

    func testEchoShapedBreakTalksOverOutroAndIntro() throws {
        let p = try XCTUnwrap(plan().plan)
        XCTAssertEqual(p.mode, .outroAndIntro)
        XCTAssertNil(p.introSkip)
        XCTAssertEqual(p.outroOverlap, 6, accuracy: 0.001)
        XCTAssertEqual(p.voiceStartAt, 204, accuracy: 0.001)
        // play() goes early by the latency so the song is audible as the closing line starts.
        XCTAssertEqual(try XCTUnwrap(p.nextPlayAfterVoice), 15.3 - 0.8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(p.nextAudibleAfterVoice), 15.3, accuracy: 0.001)
        XCTAssertEqual(p.unduckAfterVoice, 18.3, accuracy: 0.001, "the swell starts as the closing line ends")
    }

    func testNextSongNeverStartsBeforeTheCurrentOneEnds() throws {
        // One ApplicationMusicPlayer: play() for the next song must come after the outro is over.
        for main in stride(from: 3.0, through: 15.0, by: 0.5) {
            let v = TalkoverVoice(totalSeconds: main + 0.3 + 3, talkOverStartSeconds: main + 0.3, talkOverSeconds: 3)
            guard let p = plan(voice: v).plan else { continue }
            if let play = p.nextPlayAfterVoice {
                XCTAssertGreaterThanOrEqual(play + 1e-9, p.outroOverlap, "main=\(main)")
            }
            XCTAssertLessThanOrEqual(p.outroOverlap, v.totalSeconds)
        }
    }

    func testShortMainDropsTheIntroHalfButKeepsTheOutro() throws {
        // MAIN 2 s: start − latency = 1.5 s < minOutro, so MAIN can't cover the outro with
        // the next song waiting. Keep the outro, play the closing line in the gap.
        let v = TalkoverVoice(totalSeconds: 5.3, talkOverStartSeconds: 2.3, talkOverSeconds: 3)
        let p = try XCTUnwrap(plan(voice: v).plan)
        XCTAssertEqual(p.mode, .outroOnly)
        XCTAssertEqual(p.introSkip, .closingTooLong)
        XCTAssertNil(p.nextPlayAfterVoice)
    }

    func testOutroIsClampedByTheShareOfTheSong() throws {
        let p = try XCTUnwrap(plan(duration: 70, position: 50).plan)
        XCTAssertEqual(p.outroOverlap, 7 * 0 + 6, accuracy: 0.001) // 10% of 70 = 7, capped at 6
        let q = try XCTUnwrap(plan(duration: 62, position: 40).plan)
        XCTAssertEqual(q.outroOverlap, 6.2 > 6 ? 6 : 6.2, accuracy: 0.001)
        var c = TalkoverConfig(); c.maxOutroShare = 0.05
        let r = try XCTUnwrap(plan(duration: 80, position: 60, config: c).plan)
        XCTAssertEqual(r.outroOverlap, 4, accuracy: 0.001)
    }

    func testOutroIsClampedByTimeLeftToArm() throws {
        // 5 s left: arm needs 1.5 s, so at most 3.5 s of outro.
        let p = try XCTUnwrap(plan(position: 205).plan)
        XCTAssertEqual(p.outroOverlap, 3.5, accuracy: 0.001)
        XCTAssertEqual(p.voiceStartAt, 206.5, accuracy: 0.001)
    }

    func testOutroNeverLongerThanTheVoice() throws {
        let v = TalkoverVoice(totalSeconds: 3)
        let p = try XCTUnwrap(plan(voice: v).plan)
        XCTAssertEqual(p.outroOverlap, 3, accuracy: 0.001)
        XCTAssertEqual(p.mode, .outroOnly)
    }

    func testLatencyIsClampedToItsRange() throws {
        var c = TalkoverConfig(); c.startLatency = 9
        let p = try XCTUnwrap(plan(config: c).plan)
        XCTAssertEqual(p.startLatency, 2.0, accuracy: 0.001)
        c.startLatency = 0
        XCTAssertEqual(try XCTUnwrap(plan(config: c).plan).startLatency, 0.3, accuracy: 0.001)
    }

    func testMeasuredLatencyIsSmoothedAndClamped() {
        XCTAssertEqual(cfg.updatedLatency(current: 0.8, measured: 1.8), 1.1, accuracy: 0.001)
        XCTAssertEqual(cfg.updatedLatency(current: 1.9, measured: 30), 2.0, accuracy: 0.001)
        XCTAssertEqual(cfg.updatedLatency(current: 0.8, measured: .nan), 0.8)
        XCTAssertEqual(cfg.updatedLatency(current: 0.8, measured: -1), 0.8)
    }

    // MARK: Outro only (no usable closing line)

    func testNoMarkerPlaysEverythingAfterTheOutroInTheGap() throws {
        let p = try XCTUnwrap(plan(voice: TalkoverVoice(totalSeconds: 14)).plan)
        XCTAssertEqual(p.mode, .outroOnly)
        XCTAssertEqual(p.introSkip, .noClosingLine)
        XCTAssertNil(p.nextPlayAfterVoice)
        XCTAssertEqual(p.outroOverlap, 6, accuracy: 0.001)
    }

    func testClosingLineThatFailedToRenderFallsBackToOutroOnly() throws {
        // Echo recomputes the hook to nil when the closing line is dropped; a closing clip that
        // fails to decode is reported the same way by the app (hook fields nil).
        let main = TalkoverVoice(totalSeconds: 15, talkOverStartSeconds: nil, talkOverSeconds: nil)
        let p = try XCTUnwrap(plan(voice: main).plan)
        XCTAssertEqual(p.mode, .outroOnly)
        XCTAssertEqual(p.introSkip, .noClosingLine)
    }

    func testInconsistentHookIsIgnored() {
        XCTAssertNil(TalkoverVoice(totalSeconds: 10, talkOverStartSeconds: 9, talkOverSeconds: 3).closing, "ends after the voice")
        XCTAssertNil(TalkoverVoice(totalSeconds: 10, talkOverStartSeconds: .nan, talkOverSeconds: 3).closing)
        XCTAssertNil(TalkoverVoice(totalSeconds: 10, talkOverStartSeconds: 7, talkOverSeconds: 0).closing)
        XCTAssertNil(TalkoverVoice(totalSeconds: 10, talkOverStartSeconds: 7, talkOverSeconds: nil).closing)
        XCTAssertNotNil(TalkoverVoice(totalSeconds: 10, talkOverStartSeconds: 7.1, talkOverSeconds: 3).closing, "rounding slack")
    }

    func testLongClosingLineDoesNotRideAnUnknownIntro() throws {
        let v = TalkoverVoice(totalSeconds: 20, talkOverStartSeconds: 15, talkOverSeconds: 5)
        XCTAssertEqual(try XCTUnwrap(plan(voice: v).plan).introSkip, .closingTooLong)
    }

    func testShortOrUnknownNextSongGetsNoClosingLineOverIt() throws {
        XCTAssertEqual(try XCTUnwrap(plan(next: 40).plan).introSkip, .nextTrackTooShort)
        XCTAssertEqual(try XCTUnwrap(plan(next: .nan).plan).introSkip, .nextTrackTooShort)
        XCTAssertEqual(try XCTUnwrap(plan(next: nil).plan).introSkip, .nextTrackUnknown)
    }

    func testKnownShortIntroSkipsTheIntroHalf() throws {
        XCTAssertEqual(try XCTUnwrap(plan(intro: 2).plan).introSkip, .introTooShort)
        XCTAssertEqual(try XCTUnwrap(plan(intro: 8).plan).mode, .outroAndIntro)
    }

    // MARK: Hard breaks

    func testUnknownDurationIsAHardBreak() {
        XCTAssertEqual(plan(duration: nil), .hardBreak(.durationUnknown))
        XCTAssertEqual(plan(duration: .infinity), .hardBreak(.durationUnknown))
        XCTAssertEqual(plan(duration: 0, position: 0), .hardBreak(.durationUnknown))
        XCTAssertEqual(plan(position: .nan), .hardBreak(.durationUnknown))
    }

    func testShortTrackIsAHardBreak() {
        XCTAssertEqual(plan(duration: 59, position: 40), .hardBreak(.trackTooShort))
    }

    func testVoiceLongerThanTheBudgetIsAHardBreak() {
        XCTAssertEqual(plan(voice: TalkoverVoice(totalSeconds: 25)), .hardBreak(.voiceTooLong))
        XCTAssertEqual(plan(voice: TalkoverVoice(totalSeconds: 0)), .hardBreak(.voiceInvalid))
        XCTAssertEqual(plan(voice: TalkoverVoice(totalSeconds: .nan)), .hardBreak(.voiceInvalid))
    }

    func testSeekNearTheEndIsTooLateToArm() {
        XCTAssertEqual(plan(position: 207), .hardBreak(.tooLateToArm)) // 3 s left − 1.5 arm < 2
        XCTAssertEqual(plan(position: 210), .hardBreak(.endedBeforeVoice))
        XCTAssertEqual(plan(position: 215), .hardBreak(.endedBeforeVoice))
    }

    func testVeryShortVoiceIsAHardBreak() {
        XCTAssertEqual(plan(voice: TalkoverVoice(totalSeconds: 1.5)), .hardBreak(.outroTooShort))
    }

    func testArmTime() {
        XCTAssertEqual(TalkoverPlanner.armAt(duration: 210), 202.5)
        XCTAssertNil(TalkoverPlanner.armAt(duration: nil))
    }

    // MARK: Run: timing

    private func makeRun(_ d: TalkoverDecision? = nil) throws -> TalkoverRun {
        TalkoverRun(afterTrack: 3, plan: try XCTUnwrap((d ?? plan()).plan))
    }

    func testOnTimeRunHasNoMisses() throws {
        var r = try makeRun()
        r.voiceStarted(at: 100, songPosition: 204.1)
        let end = r.naturalEnd(at: 106)
        XCTAssertFalse(end.abandoned)
        XCTAssertEqual(end.waitSeconds, 100 + 14.5 - 106, accuracy: 0.001, "wait for the play cue")
        r.nextPlayCalled(at: 114.5)
        let latency = r.nextAudible(at: 115.4)
        XCTAssertEqual(try XCTUnwrap(latency), 0.9, accuracy: 0.001)
        r.voiceFinished(at: 118.3)
        XCTAssertEqual(r.misses, [])
        XCTAssertEqual(r.phase, .done)
    }

    func testLateVoiceStartIsAMiss() throws {
        var r = try makeRun()
        r.voiceStarted(at: 100, songPosition: 205)
        XCTAssertEqual(r.misses, [.voiceStartLate])
    }

    func testSongEndingBeforeTheVoiceAbandonsToAHardBreak() throws {
        var r = try makeRun()
        let end = r.naturalEnd(at: 50)
        XCTAssertTrue(end.abandoned)
        XCTAssertEqual(end.waitSeconds, 0)
        XCTAssertEqual(r.misses, [.endedBeforeVoice])
        r.voiceStarted(at: 51, songPosition: 0)
        XCTAssertFalse(r.isSpeaking, "a voice start after the end is not a talk-over")
    }

    func testEndAfterThePlayCueStartsTheNextSongAtOnce() throws {
        var r = try makeRun()
        r.voiceStarted(at: 100, songPosition: 204)
        let end = r.naturalEnd(at: 116) // catalog duration was 10 s short
        XCTAssertEqual(end.waitSeconds, 0)
        XCTAssertEqual(r.misses, [.endAfterPlayCue])
    }

    func testOutroOnlyWaitsForTheVoice() throws {
        var r = try makeRun(plan(voice: TalkoverVoice(totalSeconds: 14)))
        r.voiceStarted(at: 100, songPosition: 204)
        XCTAssertEqual(r.naturalEnd(at: 106).waitSeconds, 8, accuracy: 0.001)
        r.voiceFinished(at: 114)
        XCTAssertEqual(r.misses, [], "outro-only has no next-start target")
    }

    func testLateAndEarlyNextStartsAreMisses() throws {
        var late = try makeRun()
        late.voiceStarted(at: 100, songPosition: 204)
        late.nextPlayCalled(at: 114.5)
        late.nextAudible(at: 117)
        XCTAssertEqual(late.misses, [.nextStartLate])
        late.voiceFinished(at: 118.3)
        XCTAssertEqual(late.misses, [.nextStartLate], "audible before the voice ended")

        var early = try makeRun()
        early.voiceStarted(at: 100, songPosition: 204)
        early.nextAudible(at: 113)
        XCTAssertEqual(early.misses, [.nextStartEarly])
        XCTAssertNil(early.nextAudible(at: 114), "first audible only")
    }

    func testVoiceEndingBeforeTheNextSongIsAMiss() throws {
        var r = try makeRun()
        r.voiceStarted(at: 100, songPosition: 204)
        r.voiceFinished(at: 118.3)
        XCTAssertEqual(r.misses, [.voiceEndedFirst])
    }

    // MARK: Run: seek and skip

    func testSeekBackOutOfTheWindowAbortsThePendingTalkover() throws {
        var r = try makeRun()
        XCTAssertEqual(r.userSeeked(to: 120), .abandon(.seekOutOfWindow))
        XCTAssertEqual(r.cancelled, .seekOutOfWindow)
        XCTAssertEqual(r.phase, .done)
    }

    func testSeekInsideTheArmWindowKeepsThePlan() throws {
        var r = try makeRun()
        XCTAssertEqual(r.userSeeked(to: 203), .none)
        XCTAssertEqual(r.phase, .armed)
    }

    func testSeekWhileSpeakingFadesTheVoiceAndDropsTheBreak() throws {
        var r = try makeRun()
        r.voiceStarted(at: 100, songPosition: 204)
        XCTAssertEqual(r.userSeeked(to: 60), .stopVoice(fade: true))
        XCTAssertEqual(r.cancelled, .seekWhileSpeaking)
        // The song ends later on its own: nothing to wait for, no break replay.
        let end = r.naturalEnd(at: 300)
        XCTAssertEqual(end.waitSeconds, 0)
        XCTAssertFalse(end.abandoned)
    }

    func testSeekAfterTheSongEndedDoesNotCancelTheIntroHalf() throws {
        var r = try makeRun()
        r.voiceStarted(at: 100, songPosition: 204)
        _ = r.naturalEnd(at: 106)
        XCTAssertEqual(r.userSeeked(to: 1), .none)
        XCTAssertTrue(r.isSpeaking)
    }

    func testSkipPauseInterruptionRouteAndRevokeStopTheVoice() throws {
        for reason in [TalkoverCancel.skip, .userStop, .interruption, .routeRemoved, .revoked] {
            var speaking = try makeRun()
            speaking.voiceStarted(at: 100, songPosition: 204)
            XCTAssertEqual(speaking.stopped(reason), .stopVoice(fade: false), "\(reason)")
            XCTAssertEqual(speaking.cancelled, reason)
            XCTAssertEqual(speaking.stopped(.skip), .none, "a second stop is a no-op")

            var armed = try makeRun()
            XCTAssertEqual(armed.stopped(reason), .abandon(reason))
        }
    }

    func testSkipDuringTheIntroOverlapStopsTheVoice() throws {
        var r = try makeRun()
        r.voiceStarted(at: 100, songPosition: 204)
        _ = r.naturalEnd(at: 106)
        r.nextPlayCalled(at: 114.5)
        r.nextAudible(at: 115.3)
        XCTAssertEqual(r.stopped(.skip), .stopVoice(fade: false))
        r.voiceFinished(at: 116)
        XCTAssertEqual(r.misses, [], "a cancelled voice has no finish miss")
    }

    func testVoiceFailureAbandonsCleanly() throws {
        var r = try makeRun()
        XCTAssertEqual(r.stopped(.voiceFailed), .abandon(.voiceFailed))
        let end = r.naturalEnd(at: 120)
        XCTAssertEqual(end.waitSeconds, 0)
    }

    // MARK: Loudness

    func testMixedVoicesAreBroughtToOneLevelByAttenuationOnly() {
        // Cloud MAIN at -14 dBFS, on-device closing line at -22: MAIN comes down 8 dB.
        let g = TalkoverLoudness.gains(rmsDBFS: [-14, -22])
        XCTAssertEqual(g[0], powf(10, -8 / 20), accuracy: 0.001)
        XCTAssertEqual(g[1], 1, accuracy: 0.001)
        XCTAssertTrue(g.allSatisfy { $0 <= 1 })
    }

    func testLoudnessCutIsCappedAndUnknownClipsStayAtUnity() {
        let g = TalkoverLoudness.gains(rmsDBFS: [-5, -30])
        XCTAssertEqual(g[0], powf(10, -9 / 20), accuracy: 0.001, "max cut 9 dB")
        let unknown = TalkoverLoudness.gains(rmsDBFS: [nil, -18])
        XCTAssertEqual(unknown[0], 1, "no reading: unity")
        XCTAssertEqual(unknown[1], powf(10, -2 / 20), accuracy: 0.001, "-18 comes down to the -20 target")
        XCTAssertEqual(TalkoverLoudness.gains(rmsDBFS: [-.infinity, nil]), [1, 1])
        let both = TalkoverLoudness.gains(rmsDBFS: [-12, -12])
        XCTAssertEqual(both[0], powf(10, -8 / 20), accuracy: 0.001, "both down to the -20 target")
    }

    func testRMS() {
        XCTAssertEqual(TalkoverLoudness.rmsDBFS([1, -1, 1, -1]), 0, accuracy: 0.001)
        XCTAssertEqual(TalkoverLoudness.rmsDBFS([0.1, -0.1]), -20, accuracy: 0.001)
        XCTAssertEqual(TalkoverLoudness.rmsDBFS([]), -.infinity)
        XCTAssertEqual(TalkoverLoudness.rmsDBFS([0, 0]), -.infinity)
    }

    // MARK: Logs

    func testLogLinesCarryCodesAndNumbersOnly() throws {
        let line = TalkoverLog.decision(afterTrack: 2, plan())
        XCTAssertEqual(line, "talkover plan after=2 result=outroAndIntro intro=used outro=6.0 voice=18.3 play=14.5 unduck=18.3 lat=800")
        XCTAssertEqual(TalkoverLog.decision(afterTrack: 2, .hardBreak(.tooLateToArm)),
                       "talkover plan after=2 result=hardBreak reason=tooLateToArm")
        XCTAssertEqual(TalkoverLog.miss(afterTrack: 2, .nextStartLate, ms: 1240), "talkover miss after=2 code=nextStartLate ms=1240")
        XCTAssertEqual(TalkoverLog.cancel(afterTrack: 2, .seekWhileSpeaking), "talkover cancel after=2 reason=seekWhileSpeaking")
        XCTAssertEqual(TalkoverLog.latency(afterTrack: 2, measuredMs: 910, nextMs: 830), "talkover latency after=2 measured=910 next=830")
    }
}

// MARK: - Clips (mixed renderers, closing-line failure)

final class DJTalkoverClipsTests: XCTestCase {
    private let echo = TalkoverVoice(totalSeconds: 18.3, talkOverStartSeconds: 15.3, talkOverSeconds: 3)

    func testBothClipsDecodedKeepsTheClosingLineAndEchosGap() throws {
        let r = try XCTUnwrap(TalkoverClips.resolve(decoded: [15, 3], voice: echo))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.closingGap, 0.3, accuracy: 0.001, "the gap is inserted when the clips don't carry it")
        XCTAssertEqual(try XCTUnwrap(r.voice.talkOverStartSeconds), 15.3, accuracy: 0.001)
        XCTAssertEqual(r.voice.totalSeconds, 18.3, accuracy: 0.001)
        XCTAssertFalse(r.droppedClosing)
    }

    func testGapAlreadyInTheAudioIsNotDoubled() throws {
        let r = try XCTUnwrap(TalkoverClips.resolve(decoded: [15.3, 3], voice: echo))
        XCTAssertEqual(r.closingGap, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(r.voice.talkOverStartSeconds), 15.3, accuracy: 0.001)
    }

    func testMeasuredLengthsWinOverTheHook() throws {
        // The closing clip decoded 3.4 s, not 3: the unduck follows the real clip.
        let r = try XCTUnwrap(TalkoverClips.resolve(decoded: [10, 5, 3.4], voice: echo))
        XCTAssertEqual(r.voice.talkOverSeconds ?? 0, 3.4, accuracy: 0.001)
        XCTAssertEqual(r.voice.totalSeconds, 18.7, accuracy: 0.001)
        XCTAssertEqual(r.closingGap, 0.3, accuracy: 0.001)
    }

    func testClosingLineThatFailsToDecodeFallsBackToMainInTheGap() throws {
        let r = try XCTUnwrap(TalkoverClips.resolve(decoded: [15, nil], voice: echo))
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(r.droppedClosing)
        XCTAssertNil(r.voice.closing)
        XCTAssertEqual(r.voice.totalSeconds, 15, accuracy: 0.001)
        let plan = TalkoverPlanner.decide(flag: true, track: TalkoverTrack(duration: 200, position: 185),
                                          voice: r.voice, nextTrackDuration: 200)
        XCTAssertEqual(plan.plan?.mode, .outroOnly)
        XCTAssertNil(plan.plan?.nextPlayAfterVoice, "the next song waits for MAIN")
        XCTAssertNil(TalkoverClips.resolve(decoded: [15, 0], voice: echo)?.voice.closing, "empty closing clip")
    }

    func testFailedMainSkipsTheBreak() {
        XCTAssertNil(TalkoverClips.resolve(decoded: [nil, 3], voice: echo))
        XCTAssertNil(TalkoverClips.resolve(decoded: [5, nil, 3], voice: echo))
        XCTAssertNil(TalkoverClips.resolve(decoded: [], voice: echo))
        XCTAssertNil(TalkoverClips.resolve(decoded: [nil], voice: TalkoverVoice(totalSeconds: 5)))
    }

    func testNoHookPlaysEveryClipAsMain() throws {
        let r = try XCTUnwrap(TalkoverClips.resolve(decoded: [6, 4], voice: TalkoverVoice(totalSeconds: 10)))
        XCTAssertEqual(r.count, 2)
        XCTAssertNil(r.voice.closing)
        XCTAssertFalse(r.droppedClosing)
    }

    func testOneClipWithAHookHasNoSeparateClosingLine() throws {
        let r = try XCTUnwrap(TalkoverClips.resolve(decoded: [18.3], voice: echo))
        XCTAssertEqual(r.count, 1)
        XCTAssertNil(r.voice.closing)
    }

    private func cue(_ text: String) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 2, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
    }

    private func clip(_ cue: NarrationCue, _ seconds: Double, provider: String = "device") -> RenderedClip {
        RenderedClip(cueID: cue.id, audio: CachedAudio(data: Data([1]), seconds: seconds, providerID: provider, voiceID: "v"),
                     cacheKey: "k", attempts: [])
    }

    func testSeamReadsEchosHookAndAddsTheGap() throws {
        let a = cue("main"), b = cue("more main"), c = cue("closing")
        let prepared = PreparedDJBreak(afterTrack: 0, cues: [a, b, c],
                                       clips: [clip(a, 9, provider: "cloud"), clip(b, 5, provider: "cloud"), clip(c, 3)],
                                       attributions: [c.id: .trackMetadata(trackIDs: ["t1"])], talkOverCueID: c.id)
        let v = prepared.talkoverVoice
        XCTAssertEqual(try XCTUnwrap(v.talkOverStartSeconds), 14.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(v.talkOverSeconds), 3, accuracy: 1e-9)
        XCTAssertEqual(v.totalSeconds, 17.3, accuracy: 1e-9, "gap counted once, clips don't carry it")
        XCTAssertNotNil(v.closing)
        // Decoded as rendered: the player inserts Echo's gap before the closing clip.
        let r = try XCTUnwrap(TalkoverClips.resolve(decoded: [9, 5, 3], voice: v))
        XCTAssertEqual(r.closingGap, 0.3, accuracy: 1e-9)
        XCTAssertEqual(r.count, 3)
        let plan = TalkoverPlanner.decide(flag: true, track: TalkoverTrack(duration: 200, position: 185),
                                          voice: r.voice, nextTrackDuration: 200)
        XCTAssertEqual(plan.plan?.mode, .outroAndIntro)
        XCTAssertEqual(try XCTUnwrap(plan.plan?.nextPlayAfterVoice), 14.3 - 0.8, accuracy: 1e-9)
    }

    func testSeamWithoutAClosingCueIsTheGapBreakFallback() {
        let a = cue("main")
        let prepared = PreparedDJBreak(afterTrack: 0, cues: [a], clips: [clip(a, 12)], attributions: [:])
        XCTAssertNil(prepared.talkoverVoice.closing)
        XCTAssertEqual(prepared.talkoverVoice.totalSeconds, 12)
        var dropped = PreparedDJBreak(afterTrack: 0, cues: [a], clips: [clip(a, 12)], attributions: [:], talkOverCueID: UUID())
        XCTAssertNil(dropped.talkoverVoice.closing, "closing cue dropped by a stale-next or consent filter")
        dropped.talkOverCueID = nil
        XCTAssertEqual(TalkoverPlanner.decide(flag: true, track: TalkoverTrack(duration: 200, position: 185),
                                              voice: dropped.talkoverVoice, nextTrackDuration: 200).plan?.mode, .outroOnly)
    }

    func testEchosCapsFitTheTalkoverBudget() {
        // Echo: MAIN up to 15 s, closing up to 4 s, 0.3 s gap.
        let v = TalkoverVoice(totalSeconds: 19.3, talkOverStartSeconds: 15.3, talkOverSeconds: 4)
        XCTAssertEqual(TalkoverPlanner.decide(flag: true, track: TalkoverTrack(duration: 200, position: 185),
                                              voice: v, nextTrackDuration: 200).plan?.mode, .outroAndIntro)
    }
}
