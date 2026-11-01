import XCTest
@testable import AeroDJCore

/// #149 (-Atlas): a genuine interruption that is still ongoing at song end must keep holding
/// song 2 (and its break) even when `isOtherAudioPlaying` and the secondary hint are both false.
/// Neither hint proves the interruption ended. A never-ended interruption is released only on an
/// OS end with `shouldResume`, or on MusicKit's own queue finish observed after it began (the
/// queue cleared, the entry changed, or the playhead rewound to the start). Uses the
/// `SongEndInterruptionTests` harness (boundary hook -> armNext -> startNextTrack's gate).
final class SongEndOngoingInterruptionTests: XCTestCase {
    typealias Harness = SongEndInterruptionTests.Harness

    private func breakAdmission(_ h: Harness) -> BreakPlayAdmission {
        BreakPlayAdmissionPolicy.decide(pausedBySystem: h.policy.pausedBySystem,
                                        mayAutoResume: h.policy.mayAutoResume,
                                        phase: .transition, afterTrack: 0)
    }

    private func assertHeld(_ h: inout Harness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(h.policy.interruptionOngoing, file: file, line: line)
        XCTAssertTrue(h.policy.pausedBySystem, file: file, line: line)
        XCTAssertFalse(h.policy.mayAutoResume, file: file, line: line)
        XCTAssertFalse(breakAdmission(h).startAudio, "no DJ break airs", file: file, line: line)
        XCTAssertEqual(breakAdmission(h).skipReason, .interrupted, file: file, line: line)
        XCTAssertEqual(h.startNext(), .held(.deferSilently), "song 2 is not started", file: file, line: line)
    }

    // MARK: - Negative: a real interruption, still ongoing, both hints false

    /// The issue's path: the interruption pauses the song inside its last 1.5 s and never ends.
    /// The stop is reported once as the end, but nothing has proven the interruption is over.
    func testOngoingInterruptionPausingInEndWindowWithBothHintsFalseHoldsSong2() {
        var h = Harness()
        h.play(through: 198)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 198.9)
        h.poll("s1", playing: false, at: 198.9)
        XCTAssertEqual(h.steps.count, 1, "\(h.steps)")
        XCTAssertEqual(h.handoffs, 1)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        assertHeld(&h)
    }

    /// Siri (or an alarm) begins during the break, after the end was reported and the queue was
    /// already cleared. The queue finish came before it, so it is not evidence about it.
    func testInterruptionBeginningAfterTheQueueAlreadyClearedHoldsSong2() {
        var h = Harness()
        h.play(through: 199)
        h.poll("s1", playing: false, at: 0)
        h.poll(nil, playing: false, at: nil)
        XCTAssertEqual(h.handoffs, 1)
        h.notice(.interruptionBegan)
        h.poll(nil, playing: false, at: nil)
        XCTAssertTrue(h.interpreter.interruptionBeganNearEnd)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        assertHeld(&h)
    }

    /// A first interruption at the end is released by MusicKit's rewind. A second one then begins
    /// during the break and never ends: the earlier finish is not evidence about it.
    func testSecondInterruptionAfterAnEvidencedQueueEndHoldsSong2() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        XCTAssertEqual(h.handoffs, 1)
        XCTAssertTrue(h.policy.mayAutoResume, "the first one is released at the boundary")
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        assertHeld(&h)
    }

    /// The app cleared the queue itself (stop) while the interruption was ongoing: that clear is
    /// the app's, not MusicKit's finish.
    func testAppRequestedClearIsNotQueueFinishEvidence() {
        var h = Harness()
        h.play(through: 198)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 198.9)
        h.interpreter.userRequestedChange()
        h.poll(nil, playing: false, at: nil)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        assertHeld(&h)
    }

    /// A user pause during the interruption, then a rewind to 0: never evidence, never released.
    func testUserPauseDuringInterruptionThenRewindIsNotEvidence() {
        var h = Harness()
        h.play(through: 198)
        h.notice(.interruptionBegan)
        h.userPause()
        h.poll("s1", playing: false, at: 198.9)
        h.poll("s1", playing: false, at: 0)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        XCTAssertTrue(h.steps.isEmpty, "\(h.steps)")
        XCTAssertFalse(h.policy.mayAutoResume)
    }

    /// A mid-song interruption after which MusicKit reads 0 has not played through: no evidence.
    func testMidSongInterruptionThenZeroIsNotEvidence() {
        var h = Harness()
        h.play(through: 100)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        XCTAssertTrue(h.policy.pausedBySystem)
    }

    /// Route loss at the end, then a rewind: route holds are never released at song end.
    func testRouteLossThenRewindIsNotEvidenceAndStaysHeld() {
        var h = Harness()
        h.play(through: 198)
        h.notice(.interruptionBegan)
        h.notice(.routeChanged(.oldDeviceUnavailable))
        h.poll("s1", playing: false, at: 198.9)
        h.poll("s1", playing: false, at: 0)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        XCTAssertFalse(h.policy.mayAutoResume)
    }

    /// The OS ended it with shouldResume:false: held even after MusicKit's finish (not regressed).
    func testEndedWithoutShouldResumeHoldsEvenAfterQueueFinish() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 0)
        h.notice(.interruptionEnded(shouldResume: false))
        XCTAssertTrue(h.interpreter.queueFinishedSinceInterruption)
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
        XCTAssertTrue(h.policy.pausedBySystem)
    }

    /// A call at the end still holds even with MusicKit's finish (not regressed).
    func testCallActiveHoldsEvenAfterQueueFinish() {
        var h = Harness()
        h.world.callActive = true
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll(nil, playing: false, at: nil)
        XCTAssertTrue(h.interpreter.queueFinishedSinceInterruption)
        XCTAssertEqual(h.startNext(), .held(.deferSilently))
    }

    // MARK: - Positive: safe queue-end recovery on MusicKit's own finish

    /// The ongoing interruption was first held at the stop; MusicKit then rewound the entry to 0.
    /// The rewind comes after the interruption, so the startNextTrack hook releases song 2 once.
    func testStopInEndWindowThenMusicKitRewindReleasesAtStartNext() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll("s1", playing: false, at: 199.6)
        XCTAssertFalse(h.policy.mayAutoResume, "held at the boundary: only the hints so far")
        h.poll("s1", playing: false, at: 0)
        XCTAssertTrue(h.interpreter.queueFinishedSinceInterruption)
        XCTAssertEqual(h.handoffs, 1, "still reported once")
        XCTAssertEqual(h.startNext(), .plays)
        XCTAssertNil(h.startNext(), "song 2 loads once")
    }

    /// The interruption began, then MusicKit cleared the one-song queue: released at the boundary.
    func testQueueClearedAfterInterruptionReleasesAtTheBoundary() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll(nil, playing: false, at: nil)
        XCTAssertTrue(h.interpreter.queueFinishedSinceInterruption)
        XCTAssertTrue(h.policy.mayAutoResume)
        XCTAssertEqual(h.startNext(), .plays)
    }

    /// A multi-entry queue: the entry changed after the interruption began. MusicKit advanced on
    /// its own, so that is a finish too, and the boundary hook may release.
    func testEntryChangeAfterInterruptionIsQueueFinishEvidence() {
        var i = BoundaryInterpreter()
        var p = AudioSessionPolicy()
        p.userPlay()
        i.userRequestedChange()
        for t in 0...199 {
            _ = i.interpret(PlaybackObservation(entryID: "s1", isPlaying: true, position: Double(t), duration: 200,
                                                uptime: 1_000 + Double(t)), queueIndex: 0, queueCount: 3)
        }
        _ = p.handle(.interruptionBegan, breakIsActive: false)
        i.pausedByApp(.systemInterruption)
        let step = i.interpret(PlaybackObservation(entryID: "s2", isPlaying: false, position: 0, duration: 180,
                                                   uptime: 1_201), queueIndex: 0, queueCount: 3)
        XCTAssertEqual(step, .advancedEntry(finishedIndex: 0, boundary: .naturalEnd(finishedEntryID: "s1")))
        XCTAssertTrue(i.queueFinishedSinceInterruption)
        XCTAssertTrue(p.naturalEndReached(interruptionBeganNearEnd: i.interruptionBeganNearEnd,
                                          queueFinishedSinceInterruption: i.queueFinishedSinceInterruption,
                                          otherAudioPlaying: false, secondaryHint: false, callActive: false))
        XCTAssertTrue(p.mayAutoResume)
    }

    /// An OS end with shouldResume releases without any MusicKit finish (not regressed).
    func testEndedWithShouldResumeNeedsNoQueueFinish() {
        var h = Harness()
        h.play(through: 198)
        h.notice(.interruptionBegan)
        h.notice(.interruptionEnded(shouldResume: true))
        h.poll("s1", playing: false, at: 198.9)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        XCTAssertEqual(h.startNext(), .plays)
    }

    /// The song kept playing after the interruption began (no end notice), then MusicKit rewound
    /// it. The finish is not linked to that interruption: a playing sample came in between.
    func testFinishAfterMusicPlayedOnPastTheInterruptionIsNotEvidence() {
        var h = Harness()
        h.play(through: 190)
        h.notice(.interruptionBegan)
        for t in 191...199 {
            h.poll("s1", playing: true, at: Double(t))
            h.uptime += 1
        }
        h.poll("s1", playing: false, at: 0)
        XCTAssertEqual(h.handoffs, 1)
        XCTAssertTrue(h.interpreter.interruptionBeganNearEnd)
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
        assertHeld(&h)
    }

    /// The app's own skip or new queue resets the evidence.
    func testAppRequestedChangeClearsQueueFinishEvidence() {
        var h = Harness()
        h.play(through: 199)
        h.notice(.interruptionBegan)
        h.poll(nil, playing: false, at: nil)
        XCTAssertTrue(h.interpreter.queueFinishedSinceInterruption)
        h.interpreter.userRequestedChange()
        XCTAssertFalse(h.interpreter.queueFinishedSinceInterruption)
    }

    /// A seek resets the evidence: it is a fact about the entry's last play, not about the seek.
    func testSeekClearsQueueFinishEvidence() {
        var d = PlaybackBoundaryDetector()
        for t in 0...199 {
            _ = d.consume(PlaybackObservation(entryID: "s1", isPlaying: true, position: Double(t), duration: 200,
                                              uptime: 1_000 + Double(t)))
        }
        d.pausedByApp(.systemInterruption)
        _ = d.consume(PlaybackObservation(entryID: "s1", isPlaying: false, position: 0, duration: 200, uptime: 1_200))
        XCTAssertTrue(d.queueFinishedSinceInterruption)
        d.userSeeked(to: 30, uptime: 1_201)
        XCTAssertFalse(d.queueFinishedSinceInterruption)
    }
}
