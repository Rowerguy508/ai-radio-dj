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
            gate.arm { box.reasons.append($0) }

            XCTAssertTrue(gate.canPlay)
            XCTAssertNotNil(
                gate.onBreakMustStop,
                "the stop hook is non-nil whenever a clip can be playing"
            )
            gate.onBreakMustStop?(.sourceRevoked)
            XCTAssertEqual(box.reasons, [.sourceRevoked])
        }
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
