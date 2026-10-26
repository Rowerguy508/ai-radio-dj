import Foundation
import XCTest
@testable import AeroDJCore

/// The stop entry the interlude adapter calls. The clip tokens stand in for `AVAudioPlayer`.
@MainActor
private final class SpeakingBreak {
    private var state = InterludeStopState()
    /// Retained so a later clip cannot reuse this object's address.
    private var token: NSObject?
    private var clip = ObjectIdentifier(NSObject())
    private(set) var audioStops = 0
    private(set) var delivered = 0

    func play() {
        state.begin()
        let object = NSObject()
        token = object
        clip = ObjectIdentifier(object)
        state.adopt(player: clip)
    }

    /// Same shape as `InterludePlaybackAdapter.stopCurrentInterlude(reason:)`.
    nonisolated func stopCurrentInterlude(reason: InterludeStopReason) {
        MainActorImmediate.run { self.apply(reason) }
    }

    private func apply(_ reason: InterludeStopReason) {
        guard state.stop(reason: reason) else { return }
        audioStops += 1
    }

    func lateDelegate(from clip: ObjectIdentifier) {
        guard state.acceptsDelegate(player: clip) else { return }
        delivered += 1
    }

    var currentClip: ObjectIdentifier { clip }
    var isPlaying: Bool { state.isPlaying }
    var reason: InterludeStopReason? { state.reason }
}

@MainActor
private final class StopReasons {
    var reasons: [InterludeStopReason] = []
}

final class InterludeStopTests: XCTestCase {
    func testStopDuringPlayRetiresTheBreak() async {
        let speaker = await MainActor.run { SpeakingBreak() }
        await speaker.play()
        let clip = await speaker.currentClip
        speaker.stopCurrentInterlude(reason: .sourceRevoked)

        let stopped = await speaker.audioStops
        let playing = await speaker.isPlaying
        let reason = await speaker.reason
        XCTAssertEqual(stopped, 1)
        XCTAssertFalse(playing)
        XCTAssertEqual(reason, .sourceRevoked)
        await speaker.lateDelegate(from: clip)
        let delivered = await speaker.delivered
        XCTAssertEqual(delivered, 0)
    }

    func testStopFromANonMainContextStopsBeforeReturning() async {
        let speaker = await MainActor.run { SpeakingBreak() }
        await speaker.play()
        let clip = await speaker.currentClip
        let stopped = expectation(description: "stop returned")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            speaker.stopCurrentInterlude(reason: .sourceRevoked)
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 2)

        let audioStops = await speaker.audioStops
        let playing = await speaker.isPlaying
        XCTAssertEqual(audioStops, 1, "audio stops before the non-main call returns")
        XCTAssertFalse(playing)
        await speaker.lateDelegate(from: clip)
        let delivered = await speaker.delivered
        XCTAssertEqual(delivered, 0)
    }

    func testStopWhenIdleIsANoOp() async {
        let speaker = await MainActor.run { SpeakingBreak() }
        speaker.stopCurrentInterlude(reason: .sourceRevoked)
        speaker.stopCurrentInterlude(reason: .sourceRevoked)

        let audioStops = await speaker.audioStops
        let playing = await speaker.isPlaying
        let reason = await speaker.reason
        let delivered = await speaker.delivered
        XCTAssertEqual(audioStops, 0)
        XCTAssertFalse(playing)
        XCTAssertNil(reason)
        XCTAssertEqual(delivered, 0)
    }

    /// A purge can run while PlayerView is gone. The stop hook has to be installed
    /// before a clip is allowed to start, and stay installed for as long as it can play.
    func testStopHookIsNonNilWheneverAudioCanPlay() async {
        await MainActor.run {
            let gate = SpeechStopGate()
            XCTAssertFalse(gate.canPlay)
            XCTAssertNil(gate.onBreakMustStop, "nothing can speak yet, so a missing hook drops no audio")

            let box = StopReasons()
            gate.arm { reason, _ in box.reasons.append(reason) }

            XCTAssertTrue(gate.canPlay)
            XCTAssertNotNil(
                gate.onBreakMustStop,
                "the stop hook is non-nil whenever a clip can be playing"
            )
            gate.onBreakMustStop?(.sourceRevoked, nil)
            XCTAssertEqual(box.reasons, [.sourceRevoked])
        }
    }

    /// After hand-out, before a clip player exists. `begin` is the pending play
    /// (`stopState` begun, decode not finished). The revoke cancels it.
    func testRevokeWhilePlayIsPendingStartsNoAudioAndResumesOnce() {
        var play = PendingPlayStop()
        let opened = play.begin(mayAutoResume: true)
        XCTAssertTrue(opened.startAudio)

        let duringDecode = play.stop(reason: .sourceRevoked, mayAutoResume: true)
        XCTAssertFalse(duringDecode.startAudio)
        XCTAssertFalse(duringDecode.resumeMusic, "the in-flight play resumes from admit, once")

        let admitted = play.admit(mayAutoResume: true)
        XCTAssertFalse(admitted.startAudio, "no clip player starts")
        XCTAssertTrue(admitted.resumeMusic)

        let repeatStop = play.stop(reason: .sourceRevoked, mayAutoResume: true)
        XCTAssertFalse(repeatStop.resumeMusic, "a second revoke does not resume again")
    }

    func testRevokeWhilePendingDoesNotResumeWhenAutoResumeIsOff() {
        var play = PendingPlayStop()
        XCTAssertTrue(play.begin(mayAutoResume: false).startAudio)
        _ = play.stop(reason: .sourceRevoked, mayAutoResume: false)
        let admitted = play.admit(mayAutoResume: false)
        XCTAssertFalse(admitted.startAudio)
        XCTAssertFalse(admitted.resumeMusic)
    }

    /// A revoke while nothing is playing, and no play is pending, must not cancel the next break.
    func testRevokeWhileIdleDoesNotCancelTheNextBreak() {
        var play = PendingPlayStop()
        let idle = play.stop(reason: .sourceRevoked, mayAutoResume: true)
        XCTAssertFalse(idle.startAudio)
        XCTAssertFalse(idle.resumeMusic)

        let next = play.begin(mayAutoResume: true)
        XCTAssertTrue(next.startAudio, "an idle revoke does not cancel the next unrelated break")
        XCTAssertFalse(next.resumeMusic)
    }

    /// `skip()` sends a nil tag. Between hand-out and `begin`, that stop cancels the break.
    func testNilTagBetweenHandoutAndBeginNeverStarts() {
        var play = PendingPlayStop()
        play.handOut(afterTrack: 4)
        let idle = play.stop(reason: .sourceRevoked, afterTrack: nil, mayAutoResume: true)
        XCTAssertFalse(idle.startAudio)
        XCTAssertFalse(idle.resumeMusic)

        let opened = play.begin(afterTrack: 4, mayAutoResume: true)
        XCTAssertFalse(opened.startAudio, "an untagged stop cancels the handed-out break")
        XCTAssertTrue(opened.resumeMusic)
    }

    /// A stop tagged for this break, landing after hand-out and before `begin`, cancels it.
    func testMatchingTagBetweenHandoutAndBeginCancelsThatBreak() {
        var play = PendingPlayStop()
        play.handOut(afterTrack: 4)
        _ = play.stop(reason: .sourceRevoked, afterTrack: 4, mayAutoResume: true)

        let opened = play.begin(afterTrack: 4, mayAutoResume: true)
        XCTAssertFalse(opened.startAudio, "the matching tag cancels this break")
        XCTAssertTrue(opened.resumeMusic)
    }

    /// A stop tagged for a different break does not cancel the one that is beginning.
    func testDifferentTagBetweenHandoutAndBeginDoesNotCancel() {
        var play = PendingPlayStop()
        play.handOut(afterTrack: 4)
        _ = play.stop(reason: .sourceRevoked, afterTrack: 9, mayAutoResume: true)

        let opened = play.begin(afterTrack: 4, mayAutoResume: true)
        XCTAssertTrue(opened.startAudio, "a tag for another afterTrack does not cancel this break")
        XCTAssertFalse(opened.resumeMusic)
    }

    /// A mismatched tag is not kept. After this break finishes, and after a station change
    /// hands out a new break at that same index, the later break still starts.
    func testMismatchedTagDoesNotCancelALaterBreakWithThatIndex() {
        var finished = PendingPlayStop()
        finished.handOut(afterTrack: 4)
        _ = finished.stop(reason: .sourceRevoked, afterTrack: 9, mayAutoResume: true)
        let current = finished.begin(afterTrack: 4, mayAutoResume: true)
        XCTAssertTrue(current.startAudio, "a tag for another afterTrack does not cancel this break")
        XCTAssertFalse(current.resumeMusic)
        let admitted = finished.admit(mayAutoResume: true)
        XCTAssertTrue(admitted.startAudio)

        finished.handOut(afterTrack: 9)
        let later = finished.begin(afterTrack: 9, mayAutoResume: true)
        XCTAssertTrue(later.startAudio, "the stale tag does not cancel a later break with that index")
        XCTAssertFalse(later.resumeMusic)

        var stationChange = PendingPlayStop()
        stationChange.handOut(afterTrack: 4)
        _ = stationChange.stop(reason: .sourceRevoked, afterTrack: 9, mayAutoResume: true)
        stationChange.handOut(afterTrack: 9)
        let changed = stationChange.begin(afterTrack: 9, mayAutoResume: true)
        XCTAssertTrue(changed.startAudio, "a station change is not cancelled by the previous break's tag")
        XCTAssertFalse(changed.resumeMusic)
    }

    /// Headphone unplug between hand-out and begin. The break must not start on the speaker.
    func testUnplugBetweenHandoutAndBeginCancelsTheBreak() {
        assertBoundaryStopCancelsHandout(.routeRemoved, "an unplug cancels the handed-out break")
    }

    /// A phone call between hand-out and begin. The break must not start on the speaker.
    func testInterruptionBetweenHandoutAndBeginCancelsTheBreak() {
        assertBoundaryStopCancelsHandout(.interruption, "an interruption cancels the handed-out break")
    }

    private func assertBoundaryStopCancelsHandout(_ reason: InterludeStopReason, _ message: String) {
        var play = PendingPlayStop()
        play.handOut(afterTrack: 4)
        let action = InterludeBoundaryStop.action(
            reason: reason, afterTrack: nil, isPlaying: false, playingTrack: 4)
        guard case .cancelPending(let tag) = action else {
            XCTFail(message)
            return
        }
        XCTAssertNil(tag, "the session stop is untagged and fails closed")
        _ = play.stop(reason: reason, afterTrack: tag, mayAutoResume: true)
        let opened = play.begin(afterTrack: 4, mayAutoResume: true)
        XCTAssertFalse(opened.startAudio, message)
        XCTAssertTrue(opened.resumeMusic)

        var pending = PendingPlayStop()
        pending.handOut(afterTrack: 1)
        XCTAssertTrue(pending.begin(afterTrack: 1, mayAutoResume: true).startAudio)
        let duringPending = InterludeBoundaryStop.action(
            reason: reason, afterTrack: nil, isPlaying: false, playingTrack: 1)
        guard case .cancelPending(let pendingTag) = duringPending else {
            XCTFail("\(message) while the play is pending")
            return
        }
        _ = pending.stop(reason: reason, afterTrack: pendingTag, mayAutoResume: true)
        let admitted = pending.admit(mayAutoResume: true)
        XCTAssertFalse(admitted.startAudio, "\(message) before a clip player exists")
        XCTAssertTrue(admitted.resumeMusic)

        XCTAssertEqual(
            InterludeBoundaryStop.action(reason: reason, afterTrack: nil, isPlaying: true, playingTrack: 4),
            .stopPlaying,
            "a playing break still stops"
        )
        XCTAssertEqual(
            InterludeBoundaryStop.action(reason: reason, afterTrack: 3, isPlaying: true, playingTrack: 4),
            .ignore,
            "a tag for a different playing break is ignored"
        )
    }

    /// A nil tag still cancels the break that is handed out or pending. A foreign tag
    /// does not take its place.
    func testNilTagFailsClosedWhileHandedOutAndWhilePending() {
        var handed = PendingPlayStop()
        handed.handOut(afterTrack: 4)
        _ = handed.stop(reason: .sourceRevoked, afterTrack: 9, mayAutoResume: true)
        _ = handed.stop(reason: .sourceRevoked, afterTrack: nil, mayAutoResume: true)
        let opened = handed.begin(afterTrack: 4, mayAutoResume: true)
        XCTAssertFalse(opened.startAudio, "a nil tag still cancels the handed-out break")
        XCTAssertTrue(opened.resumeMusic)

        var pending = PendingPlayStop()
        pending.handOut(afterTrack: 2)
        XCTAssertTrue(pending.begin(afterTrack: 2, mayAutoResume: true).startAudio)
        _ = pending.stop(reason: .sourceRevoked, afterTrack: nil, mayAutoResume: true)
        let admitted = pending.admit(mayAutoResume: true)
        XCTAssertFalse(admitted.startAudio, "a nil tag still cancels the pending break")
        XCTAssertTrue(admitted.resumeMusic)
    }

    /// A revoke that reaches the adapter after `begin` and before a clip player exists
    /// cancels that play. An idle revoke is covered by `testRevokeWhileIdleDoesNotCancelTheNextBreak`.
    /// A stop that never reaches the adapter (session hook still nil) is not something this
    /// type can see. Production arms the hook before a clip can play.
    func testStopBeforeTheClipPlayerIsSetCancelsTheNextPlay() {
        var play = PendingPlayStop()
        XCTAssertTrue(play.begin(mayAutoResume: true).startAudio)
        let early = play.stop(reason: .sourceRevoked, mayAutoResume: true)
        XCTAssertFalse(early.resumeMusic, "nothing is paused until play begins")

        let opened = play.admit(mayAutoResume: true)
        XCTAssertFalse(opened.startAudio, "the stop is not lost")
        XCTAssertTrue(opened.resumeMusic)

        let later = play.begin(mayAutoResume: true)
        XCTAssertTrue(later.startAudio, "only the play that was waiting is cancelled")
        XCTAssertFalse(later.resumeMusic)
    }

    func testLateDelegateAfterStopIsIgnored() async {
        let speaker = await MainActor.run { SpeakingBreak() }
        await speaker.play()
        let first = await speaker.currentClip
        speaker.stopCurrentInterlude(reason: .sourceRevoked)
        await speaker.lateDelegate(from: first)

        await speaker.play()
        let second = await speaker.currentClip
        await speaker.lateDelegate(from: first)
        await speaker.lateDelegate(from: second)

        let delivered = await speaker.delivered
        let playing = await speaker.isPlaying
        XCTAssertEqual(delivered, 1, "only the player that is still current may finish the break")
        XCTAssertTrue(playing)
        XCTAssertNotEqual(first, second)
    }
}
