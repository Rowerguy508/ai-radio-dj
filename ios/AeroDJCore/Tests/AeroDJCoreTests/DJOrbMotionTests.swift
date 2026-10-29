import XCTest
@testable import AeroDJCore

/// The on-air orb's motion: render-mode policy, easing over Fry's `speechLevel`, and the
/// rule that a drift-rate change never jumps the blobs. -Nova
final class DJOrbMotionTests: XCTestCase {
    private let frame = 1.0 / 60

    // MARK: Policy

    func testReduceMotionAlwaysGetsTheStillOrb() {
        XCTAssertEqual(DJOrbPolicy.mode(reduceMotion: true, shaderAvailable: true), .still)
        XCTAssertEqual(DJOrbPolicy.mode(reduceMotion: true, shaderAvailable: false), .still)
    }

    func testShaderPicksMetaballsElseGradient() {
        XCTAssertEqual(DJOrbPolicy.mode(reduceMotion: false, shaderAvailable: true), .metaballs)
        XCTAssertEqual(DJOrbPolicy.mode(reduceMotion: false, shaderAvailable: false), .gradient)
    }

    func testReduceTransparencyDropsTheGlow() {
        XCTAssertEqual(DJOrbPolicy.glowOpacity(reduceTransparency: true), 0)
        XCTAssertGreaterThan(DJOrbPolicy.glowOpacity(reduceTransparency: false), 0)
    }

    // MARK: Easing

    func testLevelEasesInNeverSnaps() {
        var m = DJOrbMotion()
        let first = m.advance(speechLevel: 1, dt: frame, mode: .metaballs)
        XCTAssertGreaterThan(first.level, 0)
        XCTAssertLessThan(first.level, 0.5, "one frame never snaps to full voice")
        var last = first.level
        for _ in 0..<120 {
            let f = m.advance(speechLevel: 1, dt: frame, mode: .metaballs)
            XCTAssertGreaterThanOrEqual(f.level, last)
            last = f.level
        }
        XCTAssertEqual(last, 1, accuracy: 1e-2)
    }

    func testABriefDipBetweenClipsBarelyMovesTheOrb() {
        var m = DJOrbMotion()
        for _ in 0..<120 { m.advance(speechLevel: 0.8, dt: frame, mode: .metaballs) }
        let before = m.level
        // Fry's meter drops to 0 for about 100 ms between back-to-back clips.
        for _ in 0..<6 { m.advance(speechLevel: 0, dt: frame, mode: .metaballs) }
        XCTAssertGreaterThan(m.level, before * 0.7, "the release rides over the dip")
        for _ in 0..<6 { m.advance(speechLevel: 0.8, dt: frame, mode: .metaballs) }
        XCTAssertGreaterThan(m.level, before * 0.8)
    }

    func testSilenceSettlesToIdle() {
        var m = DJOrbMotion()
        for _ in 0..<120 { m.advance(speechLevel: 1, dt: frame, mode: .metaballs) }
        var f = m.advance(speechLevel: 0, dt: frame, mode: .metaballs)
        for _ in 0..<300 { f = m.advance(speechLevel: 0, dt: frame, mode: .metaballs) }
        XCTAssertEqual(f.level, 0, accuracy: 1e-3)
        XCTAssertEqual(f.blobSize, DJOrbMotion.idleBlobSize, accuracy: 1e-3)
        XCTAssertEqual(f.blobCount, DJOrbMotion.idleBlobCount, accuracy: 1e-3)
        XCTAssertEqual(f.scale, DJOrbMotion.idleScale, accuracy: 1e-3)
    }

    func testBadInputsStayInRange() {
        var m = DJOrbMotion()
        for level: Float in [.nan, -3, 7, .infinity] {
            for dt in [Double.nan, -1, 0, 1e9, .infinity] {
                let f = m.advance(speechLevel: level, dt: dt, mode: .metaballs)
                XCTAssert((0...1).contains(f.level))
                XCTAssert(f.phase.isFinite)
                XCTAssert((0...1).contains(f.blobSize))
                XCTAssert((1...8).contains(f.blobCount))
            }
        }
    }

    // MARK: Drift

    func testIdleDriftIsSlowAndContinuous() {
        var m = DJOrbMotion()
        var last = m.phase
        for _ in 0..<600 {
            let f = m.advance(speechLevel: 0, dt: frame, mode: .metaballs)
            XCTAssertGreaterThan(f.phase, last, "idle still drifts")
            XCTAssertLessThanOrEqual(f.phase - last, DJOrbMotion.idleRate * frame + 1e-9)
            last = f.phase
        }
        XCTAssertEqual(last, DJOrbMotion.idleRate * 10, accuracy: 1e-6)
    }

    func testRateChangeNeverJumpsThePhase() {
        var m = DJOrbMotion()
        var last = m.phase
        for i in 0..<240 {
            let target: Float = i % 40 < 20 ? 1 : 0
            let f = m.advance(speechLevel: target, dt: frame, mode: .metaballs)
            XCTAssertLessThanOrEqual(f.phase - last, DJOrbMotion.speakingRate * frame + 1e-9)
            last = f.phase
        }
    }

    func testALongFrameGapIsCapped() {
        var m = DJOrbMotion()
        let f = m.advance(speechLevel: 0, dt: 30, mode: .metaballs)
        XCTAssertEqual(f.phase, DJOrbMotion.idleRate * DJOrbMotion.maxFrameGap, accuracy: 1e-9)
    }

    func testVoiceGrowsTheBlobs() {
        var m = DJOrbMotion()
        let idle = m.advance(speechLevel: 0, dt: frame, mode: .metaballs)
        for _ in 0..<120 { m.advance(speechLevel: 1, dt: frame, mode: .metaballs) }
        let loud = m.advance(speechLevel: 1, dt: frame, mode: .metaballs)
        XCTAssertGreaterThan(loud.blobSize, idle.blobSize)
        XCTAssertGreaterThan(loud.blobCount, idle.blobCount)
        XCTAssertGreaterThan(loud.scale, idle.scale)
    }

    // MARK: Reduce Motion and fallback

    func testStillOrbNeverDriftsAndOnlyBreathes() {
        var m = DJOrbMotion()
        var f = m.advance(speechLevel: 0, dt: frame, mode: .still)
        XCTAssertEqual(f.phase, 0)
        XCTAssertEqual(f.scale, 1, accuracy: 1e-9)
        for _ in 0..<240 {
            f = m.advance(speechLevel: 1, dt: frame, mode: .still)
            XCTAssertEqual(f.phase, 0, "no metaball churn under Reduce Motion")
            XCTAssertEqual(f.blobSize, DJOrbMotion.idleBlobSize)
            XCTAssertLessThanOrEqual(f.scale, 1 + DJOrbMotion.stillScaleRange + 1e-9)
        }
        XCTAssertGreaterThan(f.scale, 1.03, "it still scales slightly with the voice")
    }

    func testGradientFallbackScalesWithVoiceWithoutDrift() {
        var m = DJOrbMotion()
        let quiet = m.advance(speechLevel: 0, dt: frame, mode: .gradient)
        for _ in 0..<240 { m.advance(speechLevel: 1, dt: frame, mode: .gradient) }
        let loud = m.advance(speechLevel: 1, dt: frame, mode: .gradient)
        XCTAssertEqual(loud.phase, 0)
        XCTAssertEqual(loud.scale - quiet.scale, DJOrbMotion.gradientScaleRange, accuracy: 1e-2)
    }

    func testSwitchingToReduceMotionMidBreakFreezesTheDrift() {
        var m = DJOrbMotion()
        for _ in 0..<60 { m.advance(speechLevel: 0.6, dt: frame, mode: .metaballs) }
        let frozen = m.phase
        for _ in 0..<60 {
            XCTAssertEqual(m.advance(speechLevel: 0.6, dt: frame, mode: .still).phase, frozen)
        }
    }
}
