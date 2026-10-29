import XCTest
@testable import AeroDJCore

/// The on-air orb's voice level (-Fry): mapping, smoothing, and the store's rule that the
/// level is exactly 0 unless the DJ is really speaking.
final class DJSpeechLevelTests: XCTestCase {

    // MARK: Mapping

    func testMappingEndpoints() {
        XCTAssertEqual(DJSpeechLevelMapping.level(dBFS: -50), 0)
        XCTAssertEqual(DJSpeechLevelMapping.level(dBFS: 0), 1)
        XCTAssertEqual(DJSpeechLevelMapping.level(dBFS: -25), 0.5, accuracy: 1e-6)
        XCTAssertEqual(DJSpeechLevelMapping.level(rms: 1), 1)
        XCTAssertEqual(DJSpeechLevelMapping.level(rms: 0), 0)
        XCTAssertEqual(DJSpeechLevelMapping.level(rms: 0.1), 0.6, accuracy: 1e-5, "-20 dBFS")
    }

    func testMappingClamps() {
        XCTAssertEqual(DJSpeechLevelMapping.level(dBFS: -160), 0, "AVAudioPlayer's silence reading")
        XCTAssertEqual(DJSpeechLevelMapping.level(dBFS: -.infinity), 0)
        XCTAssertEqual(DJSpeechLevelMapping.level(dBFS: 6), 1)
        XCTAssertEqual(DJSpeechLevelMapping.level(dBFS: .infinity), 1)
        XCTAssertEqual(DJSpeechLevelMapping.level(dBFS: .nan), 0)
        XCTAssertEqual(DJSpeechLevelMapping.level(rms: -1), 0)
        XCTAssertEqual(DJSpeechLevelMapping.level(rms: 4), 1)
        XCTAssertEqual(DJSpeechLevelMapping.level(rms: .nan), 0)
        for dB in stride(from: Float(-80), through: 10, by: 0.5) {
            let level = DJSpeechLevelMapping.level(dBFS: dB)
            XCTAssert((0...1).contains(level))
        }
    }

    func testRMSOfABuffer() {
        let square: [Float] = [0.5, -0.5, 0.5, -0.5]
        square.withUnsafeBufferPointer { XCTAssertEqual(DJSpeechLevelMapping.rms($0), 0.5, accuracy: 1e-6) }
        [Float]().withUnsafeBufferPointer { XCTAssertEqual(DJSpeechLevelMapping.rms($0), 0) }
    }

    // MARK: Smoothing

    func testAttackIsFastAndReleaseIsSlower() {
        var up = DJSpeechLevelSmoother()
        let rise = up.step(toward: 1, dt: DJSpeechLevelMeter.interval)
        var down = DJSpeechLevelSmoother()
        down.step(toward: 1, dt: 10)
        XCTAssertEqual(down.value, 1, accuracy: 1e-6)
        let fall = 1 - down.step(toward: 0, dt: DJSpeechLevelMeter.interval)
        XCTAssertGreaterThan(rise, 0.5, "one tick covers most of a rise")
        XCTAssertGreaterThan(rise, fall, "a fall moves less per tick than a rise")
        XCTAssertGreaterThan(down.value, 0, "release eases off, not a cliff")
    }

    func testSmoothingConvergesMonotonicallyAndStaysInRange() {
        var s = DJSpeechLevelSmoother()
        var last: Float = 0
        for _ in 0..<60 { let v = s.step(toward: 0.8, dt: 1.0 / 30); XCTAssertGreaterThanOrEqual(v, last); last = v }
        XCTAssertEqual(last, 0.8, accuracy: 1e-3)
        for _ in 0..<90 { let v = s.step(toward: 0, dt: 1.0 / 30); XCTAssertLessThanOrEqual(v, last); last = v }
        XCTAssertEqual(last, 0, accuracy: 1e-3)
        s.step(toward: 5, dt: 1); XCTAssertEqual(s.value, 1)
        s.step(toward: .nan, dt: 1); XCTAssertEqual(s.value, 0, accuracy: 1e-2)
        s.step(toward: 1, dt: -1); XCTAssert((0...1).contains(s.value))
        s.reset(); XCTAssertEqual(s.value, 0)
    }

    func testMeterCombinesMappingAndSmoothing() {
        var m = DJSpeechLevelMeter()
        for _ in 0..<30 { m.sample(dBFS: -25) }
        XCTAssertEqual(m.level, 0.5, accuracy: 1e-3)
        for _ in 0..<60 { m.sample(dBFS: -160) }
        XCTAssertEqual(m.level, 0, accuracy: 1e-3)
        m.sample(rms: 1); XCTAssertGreaterThan(m.level, 0.5)
        m.reset(); XCTAssertEqual(m.level, 0)
    }

    // MARK: Store gating

    @MainActor
    func testLevelIsZeroInEveryNonSpeakingState() {
        let store = DJPresentationStore()
        func push() { store.updateSpeechLevel(0.9, afterTrack: 0) }
        push()
        XCTAssertEqual(store.state, .idle); XCTAssertEqual(store.speechLevel, 0)
        store.send(.breakPreparing(afterTrack: 0, includesBriefing: false)); push()
        XCTAssertEqual(store.speechLevel, 0, "preparing")
        store.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 4)); push()
        XCTAssertEqual(store.speechLevel, 0, "ready")
        store.send(.breakSkipped(afterTrack: 0, .renderFailed)); push()
        XCTAssertEqual(store.state, .unavailable(.voiceFailed)); XCTAssertEqual(store.speechLevel, 0, "failed")
        store.send(.consentReviewPending(count: 2)); push()
        XCTAssertEqual(store.state, .unavailable(.consentReviewRequired(pendingCount: 2)))
        XCTAssertEqual(store.speechLevel, 0, "consent review")
        store.send(.consentReviewPending(count: 0))
        store.send(.playbackStarted(afterTrack: 0)); push()
        XCTAssertEqual(store.speechLevel, 0.9, "speaking shows the real level")
    }

    @MainActor
    func testLevelDropsToZeroOnEveryWayOutOfSpeakingAndStaleSamplesAreIgnored() {
        let exits: [(String, DJPresentationEvent)] = [
            ("finished", .playbackFinished(afterTrack: 3)),
            ("failed", .playbackFailed(afterTrack: 3)),
            ("stopped", .sessionStopped),
        ]
        for (name, exit) in exits {
            let store = DJPresentationStore()
            store.send(.playbackStarted(afterTrack: 3))
            store.updateSpeechLevel(0.7, afterTrack: 3)
            XCTAssertEqual(store.speechLevel, 0.7, name)
            store.send(exit)
            XCTAssertFalse(store.state.isLive, name)
            XCTAssertEqual(store.speechLevel, 0, "\(name): 0 in the same update that leaves speaking")
            store.updateSpeechLevel(0.8, afterTrack: 3)   // late tick from the ended break
            XCTAssertEqual(store.speechLevel, 0, "\(name): stale sample after the transition is ignored")
        }
    }

    @MainActor
    func testSampleForAnotherBreakIsIgnoredAndNewBreakStartsAtZero() {
        let store = DJPresentationStore()
        store.send(.playbackStarted(afterTrack: 1))
        store.updateSpeechLevel(0.6, afterTrack: 0)
        XCTAssertEqual(store.speechLevel, 0, "a sample tagged for a different break")
        store.updateSpeechLevel(0.6, afterTrack: 1)
        XCTAssertEqual(store.speechLevel, 0.6)
        // A later break goes on air without the earlier one reporting its end.
        store.send(.playbackStarted(afterTrack: 2))
        XCTAssertEqual(store.speechLevel, 0, "a new break starts from silence")
        store.updateSpeechLevel(0.4, afterTrack: 1)
        XCTAssertEqual(store.speechLevel, 0)
    }

    @MainActor
    func testPlayerCanClearAtOnceAndValuesAreClamped() {
        let store = DJPresentationStore()
        store.send(.playbackStarted(afterTrack: 0))
        store.updateSpeechLevel(3, afterTrack: 0)
        XCTAssertEqual(store.speechLevel, 1)
        store.updateSpeechLevel(0, afterTrack: 99)   // a stop clears before the state event
        XCTAssertEqual(store.speechLevel, 0)
        store.updateSpeechLevel(.nan, afterTrack: 0)
        XCTAssertEqual(store.speechLevel, 0)
        store.updateSpeechLevel(-1, afterTrack: 0)
        XCTAssertEqual(store.speechLevel, 0)
    }
}
