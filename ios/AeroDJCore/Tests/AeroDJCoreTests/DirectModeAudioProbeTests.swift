#if DEBUG || AERODJ_P0_DIAG
import XCTest
@testable import AeroDJCore

/// P0 Experiment A follow-up (-Fry): the read-only audio-session probe in Direct Mode.
final class DirectModeAudioProbeTests: XCTestCase {

    private func sample(volume: Double = 0.5, category: DirectModeSessionCategory = .soloAmbient,
                        other: Bool = false) -> DirectModeAudioSample {
        DirectModeAudioSample(outputVolume: volume, route: .speaker, category: category, mode: .default,
                              otherAudioPlaying: other, secondaryAudioShouldBeSilenced: false,
                              outputLatencySeconds: 0.0123)
    }

    private func playing(at t: Double) -> DirectModeMachine {
        var m = DirectModeMachine(songCount: 2)
        m.request(.load, at: 0)
        m.finished(.load, error: nil, at: 0.1)
        XCTAssertTrue(m.request(.play, at: t))
        return m
    }

    private func audioEntries(_ m: DirectModeMachine) -> [(sample: DirectModeAudioSample, since: Double?)] {
        m.log.compactMap { if case let .audio(s, since) = $0.kind { (s, since) } else { nil } }
    }

    func testSamplesOncePerSecondForFortySecondsAfterPlayFromA250msPoll() {
        var m = playing(at: 10)
        var t = 10.0
        while t <= 60 {
            m.observeAudio(sample(), at: t)
            t += 0.25
        }
        let timed = audioEntries(m).compactMap(\.since)
        XCTAssertEqual(timed.count, 41, "0 s through 40 s, one per second")
        XCTAssertEqual(timed.first ?? -1, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(timed.last ?? 99, DirectModeMachine.audioWindow)
        for (a, b) in zip(timed, timed.dropFirst()) {
            XCTAssertEqual(b - a, 1, accuracy: 0.26)
        }
    }

    func testOutsideTheWindowOnlyChangesAreLogged() {
        var m = DirectModeMachine(songCount: 2)
        m.observeAudio(sample(), at: 1)
        m.observeAudio(sample(), at: 2)
        m.observeAudio(sample(volume: 0.8), at: 3)
        let entries = audioEntries(m)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.since == nil })
    }

    func testResumeRestartsTheWindowAndHeardLatchesFirstTapAfterPlay() {
        var m = playing(at: 10)
        m.finished(.play, error: nil, at: 10.5)
        m.markHeard(at: 37)
        m.markHeard(at: 38)
        XCTAssertEqual(m.heardAfterPlay ?? -1, 27, accuracy: 0.001)
        m.observe(status: .paused, position: 30, entryIndex: 0, at: 39)
        XCTAssertTrue(m.request(.resume, at: 100))
        XCTAssertNil(m.heardAfterPlay)
        XCTAssertTrue(m.audioSampleDue(at: 100))
        XCTAssertFalse(m.audioSampleDue(at: 141))
    }

    func testValuesAreRoundedAndTheLineIsSanitized() {
        let s = DirectModeAudioSample(outputVolume: 0.437, route: .bluetoothA2DP, category: .playback,
                                      mode: .default, otherAudioPlaying: true,
                                      secondaryAudioShouldBeSilenced: true, outputLatencySeconds: .nan)
        XCTAssertEqual(s.outputVolume, 0.45, accuracy: 0.0001)
        XCTAssertEqual(s.outputLatencyMs, 0)
        XCTAssertEqual(s.description,
                       "vol=0.45 route=bluetoothA2DP cat=playback mode=default otherAudio=true silenceHint=true latMs=0")
        XCTAssertEqual(DirectModeAudioSample(outputVolume: 7, route: .speaker, category: .other, mode: .other,
                                             otherAudioPlaying: false, secondaryAudioShouldBeSilenced: false,
                                             outputLatencySeconds: -1).outputVolume, 1)
    }

    func testAudioEventsAreAlwaysLogged() {
        var m = DirectModeMachine(songCount: 2)
        m.observeAudioEvent(.interruptionBegan(.appWasSuspended), at: 1)
        m.observeAudioEvent(.routeChange(.categoryChange), at: 2)
        m.observeAudioEvent(.silenceSecondaryAudioHint(begin: true), at: 3)
        let lines = m.log.map(\.description)
        XCTAssertTrue(lines[0].hasSuffix("audio.event interruption.began reason=appWasSuspended"))
        XCTAssertTrue(lines[1].hasSuffix("audio.event routeChange reason=categoryChange"))
        XCTAssertTrue(lines[2].hasSuffix("audio.event silenceHint.begin"))
    }
}
#endif
