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
