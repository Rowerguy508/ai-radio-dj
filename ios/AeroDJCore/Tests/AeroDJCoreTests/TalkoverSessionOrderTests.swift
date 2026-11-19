import Foundation
import XCTest
@testable import AeroDJCore

/// Talk-over session order, duck lead and voice fades (-Fry). Pure: what the app executes.
/// NOT device evidence: whether `.duckOthers` reaches `ApplicationMusicPlayer` is unproven.
final class TalkoverSessionOrderTests: XCTestCase {

    // MARK: Session order

    func testDuckDeactivatesQuietlySetsTheOptionThenActivates() {
        XCTAssertEqual(TalkoverSessionSequence.duck, [.deactivate(notifyOthers: false), .setDuckCategory, .activate])
        XCTAssertTrue(TalkoverSessionSequence.ducksOnActivation(TalkoverSessionSequence.duck))
    }

    func testTheOptionAfterTheActivationIsNotADuck() {
        XCTAssertFalse(TalkoverSessionSequence.ducksOnActivation([.deactivate(notifyOthers: false), .activate, .setDuckCategory]))
        XCTAssertFalse(TalkoverSessionSequence.ducksOnActivation([.setDuckCategory, .activate]), "no fresh activation")
        XCTAssertFalse(TalkoverSessionSequence.ducksOnActivation([.setDuckCategory, .deactivate(notifyOthers: false), .activate]))
        XCTAssertFalse(TalkoverSessionSequence.ducksOnActivation([]))
    }

    func testReleaseNotifiesOthersAndNeverActivates() {
        XCTAssertEqual(TalkoverSessionSequence.release, [.deactivate(notifyOthers: true), .restoreCategory])
        XCTAssertFalse(TalkoverSessionSequence.release.contains(.activate))
        XCTAssertFalse(TalkoverSessionSequence.release.contains(.setDuckCategory))
    }

    // MARK: Duck lead

    func testDefaultDuckLeadIsAboutSixTenthsAndFitsTheArmWindow() {
        let config = TalkoverConfig()
        XCTAssertEqual(config.duckLead, 0.6, accuracy: 0.001)
        XCTAssertTrue(TalkoverSessionTiming.isCoherent(config))
    }

    func testAZeroOrOversizedDuckLeadIsIncoherent() {
        var config = TalkoverConfig()
        config.duckLead = 0
        XCTAssertFalse(TalkoverSessionTiming.isCoherent(config))
        config.duckLead = config.armLead
        XCTAssertFalse(TalkoverSessionTiming.isCoherent(config), "no time left to decide")
        config.duckLead = .nan
        XCTAssertFalse(TalkoverSessionTiming.isCoherent(config))
    }

    func testTheDuckRunsDuckLeadBeforeTheVoice() {
        let config = TalkoverConfig()
        XCTAssertEqual(TalkoverSessionTiming.duckAt(voiceStartAt: 194, config: config), 193.4, accuracy: 0.0001)
        var negative = config
        negative.duckLead = -1
        XCTAssertEqual(TalkoverSessionTiming.duckAt(voiceStartAt: 194, config: negative), 194, "never after the voice")
    }

    /// Every plan the planner makes leaves time to decide and then duck before the voice: the duck
    /// point is after the decision by at least `decideMargin`, and before the voice by `duckLead`.
    func testEveryPlannedTalkoverHasTimeToDuckBeforeItSpeaks() {
        let config = TalkoverConfig()
        var plans = 0
        for duration in stride(from: 60.0, through: 400.0, by: 17.0) {
            guard let arm = TalkoverPlanner.armAt(duration: duration, config: config) else { return XCTFail() }
            for offset in stride(from: 0.0, through: 5.0, by: 0.25) {
                let position = arm + offset
                for total in [3.0, 8.0, 15.0, 18.5] {
                    for voice in [TalkoverVoice(totalSeconds: total),
                                  TalkoverVoice(totalSeconds: total, talkOverStartSeconds: max(0.5, total - 3), talkOverSeconds: min(3, total - 0.5))] {
                        let d = TalkoverPlanner.decide(flag: true, track: TalkoverTrack(duration: duration, position: position),
                                                       voice: voice, nextTrackDuration: 200, config: config)
                        guard let plan = d.plan else { continue }
                        plans += 1
                        let duckAt = TalkoverSessionTiming.duckAt(voiceStartAt: plan.voiceStartAt, config: config)
                        XCTAssertLessThan(duckAt, plan.voiceStartAt)
                        XCTAssertEqual(plan.voiceStartAt - duckAt, config.duckLead, accuracy: 0.0001)
                        XCTAssertGreaterThanOrEqual(duckAt - position, TalkoverSessionTiming.decideMargin - 0.0001,
                                                    "duration \(duration) position \(position) voice \(total)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(plans, 100)
    }

    func testDuckToVoiceDelay() {
        XCTAssertEqual(TalkoverSessionTiming.duckToVoiceMs(duckedAt: 100, voiceAt: 100.6), 600)
        XCTAssertNil(TalkoverSessionTiming.duckToVoiceMs(duckedAt: nil, voiceAt: 100))
        XCTAssertNil(TalkoverSessionTiming.duckToVoiceMs(duckedAt: 1, voiceAt: .infinity))
    }

    // MARK: Voice fades (our clip only)

    func testTheVoiceFadesInAndOutOverTwoTenths() {
        XCTAssertEqual(TalkoverVoiceRamp.fadeSeconds, 0.2, accuracy: 0.0001)
        let r = TalkoverVoiceRamp.plan(duration: 5, gain: 0.8)
        XCTAssertEqual(r.startVolume, 0)
        XCTAssertEqual(r.gain, 0.8)
        XCTAssertEqual(r.fadeIn, 0.2, accuracy: 0.0001)
        XCTAssertEqual(r.fadeOut, 0.2, accuracy: 0.0001)
        XCTAssertEqual(r.fadeOutAt, 4.8, accuracy: 0.0001)
        XCTAssertEqual(r.level(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(r.level(at: 0.1), 0.4, accuracy: 0.0001)
        XCTAssertEqual(r.level(at: 2.5), 0.8, accuracy: 0.0001)
        XCTAssertEqual(r.level(at: 4.9), 0.4, accuracy: 0.0001)
        XCTAssertEqual(r.level(at: 5), 0, accuracy: 0.0001)
    }

    func testAShortClipFadesNeverOverlap() {
        let r = TalkoverVoiceRamp.plan(duration: 0.3, gain: 1)
        XCTAssertEqual(r.fadeIn, 0.15, accuracy: 0.0001)
        XCTAssertEqual(r.fadeOut, 0.15, accuracy: 0.0001)
        XCTAssertEqual(r.fadeOutAt, 0.15, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(r.fadeIn, r.fadeOutAt)
    }

    func testAnUnusableClipPlaysFlatAndTheGainIsClamped() {
        let flat = TalkoverVoiceRamp.plan(duration: .nan, gain: 0.5)
        XCTAssertEqual(flat.startVolume, 0.5)
        XCTAssertEqual(flat.fadeIn, 0)
        XCTAssertEqual(flat.fadeOut, 0)
        XCTAssertEqual(TalkoverVoiceRamp.plan(duration: 3, gain: 1.7).gain, 1, "attenuate only")
        XCTAssertEqual(TalkoverVoiceRamp.plan(duration: 3, gain: .nan).gain, 1)
    }

    // MARK: Source scans (the app executes the pure plan)

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The body of the first `marker` declaration, up to its closing brace at 4-space indent.
    private func body(_ source: String, _ marker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker), "missing \(marker)")
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), "no end for \(marker)")
        return String(rest[..<end.upperBound])
    }

    func testDecodeTalkoverNeverPreparesAClip() throws {
        let decode = try body(appSource("InterludePlaybackAdapter.swift"), "func decodeTalkover(")
        XCTAssertFalse(decode.contains("prepareToPlay"), "preparing activates the session before the duck")
    }

    func testTheTalkoverPathPreparesNothingBeforeTheDuck() throws {
        let coordinator = try appSource("TalkoverCoordinator.swift")
        let take = try body(coordinator, "private func take(")
        XCTAssertFalse(take.contains("prepareToPlay"))
        let duckCall = try XCTUnwrap(take.range(of: "interlude.duckForTalkover(afterTrack: k)"))
        let duckWait = try XCTUnwrap(take.range(of: "TalkoverSessionTiming.duckAt(voiceStartAt: plan.voiceStartAt, config: config)"))
        let voice = try XCTUnwrap(take.range(of: "interlude.playTalkover("))
        XCTAssertLessThan(duckWait.lowerBound, duckCall.lowerBound)
        XCTAssertLessThan(duckCall.lowerBound, voice.lowerBound)
        XCTAssertTrue(take.contains("interlude.releaseTalkoverDuck()"), "a duck whose voice never spoke is released")
    }

    func testTheDuckExecutesTheCoreSequence() throws {
        let duck = try body(appSource("TalkoverCoordinator.swift"), "@MainActor static func duck(afterTrack")
        XCTAssertTrue(duck.contains("for step in TalkoverSessionSequence.duck"))
        XCTAssertEqual(duck.components(separatedBy: "setActive(true)").count - 1, 1)
        XCTAssertEqual(duck.components(separatedBy: "options: [.duckOthers]").count - 1, 1)
        let release = try body(appSource("TalkoverCoordinator.swift"), "static func release(afterTrack")
        XCTAssertTrue(release.contains("for step in TalkoverSessionSequence.release"))
        XCTAssertFalse(release.contains("setActive(true)"))
    }

    func testPlayTalkoverFadesTheVoiceAndUnducksBeforeCompletion() throws {
        let adapter = try appSource("InterludePlaybackAdapter.swift")
        let play = try body(adapter, "func playTalkover(")
        XCTAssertFalse(play.contains("TalkoverAudioSession.duck("), "the duck runs duckLead earlier")
        XCTAssertTrue(play.contains("guard duckedFor == afterTrack"))
        XCTAssertTrue(play.contains("TalkoverVoiceRamp.plan(duration: player.duration, gain: gain)"))
        XCTAssertFalse(play.contains("player.volume = gain"), "no flat start at full level")
        let unduck = try XCTUnwrap(play.range(of: "TalkoverAudioSession.release(afterTrack: afterTrack, spoken: true)"))
        let complete = try XCTUnwrap(play.range(of: "music.completeNarration(decision)"))
        XCTAssertLessThan(unduck.lowerBound, complete.lowerBound)
        let ramp = try body(adapter, "private func runRamp(")
        XCTAssertTrue(ramp.contains("setVolume(ramp.gain, fadeDuration: ramp.fadeIn)"))
        XCTAssertTrue(ramp.contains("setVolume(0, fadeDuration: ramp.fadeOut)"))
        let start = try body(adapter, "private func startNextClip(")
        XCTAssertTrue(start.contains("player.volume = ramp.startVolume"))
        XCTAssertEqual(start.components(separatedBy: "runRamp(").count - 1, 2, "both the MAIN and the scheduled closing clip")
    }
}
