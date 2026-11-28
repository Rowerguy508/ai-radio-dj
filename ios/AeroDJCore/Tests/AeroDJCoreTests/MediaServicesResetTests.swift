import Foundation
import XCTest
@testable import AeroDJCore

/// #195 (-Fry): `AVAudioSession.mediaServicesWereResetNotification`. Apple's guidance: every audio
/// object is invalid after a reset, so rebuild players and engines first, then re-apply the session.
final class MediaServicesResetTests: XCTestCase {
    func testResetWhilePlayingRebuildsThenReappliesThenResumes() {
        let plan = MediaServicesResetPlan.plan(break: .none, mayAutoResume: true)
        XCTAssertEqual(plan.steps, [.rebuildVoicePlayers, .releaseAppActivation, .reapplyCategory, .resumeMusicIfAllowed],
                       "objects first, then the category, then music; the app never calls setActive(true) itself")
        XCTAssertFalse(plan.dropsBreak)
    }

    func testResetWhilePausedDoesNotResume() {
        let plan = MediaServicesResetPlan.plan(break: .none, mayAutoResume: false)
        XCTAssertEqual(plan.steps, [.rebuildVoicePlayers, .releaseAppActivation, .reapplyCategory])
        XCTAssertFalse(plan.steps.contains(.resumeMusicIfAllowed), "a paused listener stays paused")
    }

    func testResetMidBreakDropsTheClipAndLeavesTheResumeToTheBreakStop() {
        for state in [MediaServicesResetBreak.speaking, .pending] {
            let plan = MediaServicesResetPlan.plan(break: state, mayAutoResume: true)
            XCTAssertEqual(plan.steps.first, .stopBreak, "\(state): the dead clip player goes first")
            XCTAssertTrue(plan.dropsBreak, "\(state): the clip is dropped, not replayed")
            XCTAssertFalse(plan.steps.contains(.resumeMusicIfAllowed),
                           "\(state): the break stop owns the one resume, so no second resume here")
            XCTAssertEqual(Array(plan.steps.dropFirst()), [.rebuildVoicePlayers, .releaseAppActivation, .reapplyCategory])
        }
    }

    /// Atlas's M2: a talk-over speaks over playing music and its tail never resumes it ("Music was
    /// never paused"). If the reset paused MusicKit, nobody resumes it, so the reset owns the resume
    /// here, after the stop, exactly as in the no-break case.
    func testResetDuringASpeakingTalkoverStopsItThenResumesMusic() {
        let plan = MediaServicesResetPlan.plan(break: .speaking, talkoverSpeaking: true, mayAutoResume: true)
        XCTAssertEqual(plan.steps, [.stopBreak, .rebuildVoicePlayers, .releaseAppActivation,
                                    .reapplyCategory, .resumeMusicIfAllowed],
                       "the dead clip stops first; music resumes last, since the talk-over tail never does")
        XCTAssertTrue(plan.dropsBreak)
    }

    func testTalkoverResumeStillNeedsMayAutoResumeAndOnlyAppliesWhileSpeaking() {
        XCTAssertFalse(MediaServicesResetPlan.plan(break: .speaking, talkoverSpeaking: true, mayAutoResume: false)
                        .steps.contains(.resumeMusicIfAllowed), "a paused listener stays paused")
        XCTAssertFalse(MediaServicesResetPlan.plan(break: .pending, talkoverSpeaking: true, mayAutoResume: true)
                        .steps.contains(.resumeMusicIfAllowed), "only a speaking talk-over; a pending gap break owns its resume")
        XCTAssertFalse(MediaServicesResetPlan.plan(break: .speaking, talkoverSpeaking: false, mayAutoResume: true)
                        .steps.contains(.resumeMusicIfAllowed), "a gap break's stop still owns the one resume")
    }

    /// Sentinel's N14/N15: the getter is a Core pure function, so it is unit-tested here.
    func testTalkoverSpeakingNeedsASpeakingClipAndADuckForThisBreaksTrack() {
        XCTAssertTrue(MediaServicesResetPlan.isTalkoverSpeaking(clipSpeaking: true, breakTrack: 4, duckedFor: 4))
        XCTAssertFalse(MediaServicesResetPlan.isTalkoverSpeaking(clipSpeaking: false, breakTrack: 4, duckedFor: 4),
                       "armed or ducked but not speaking is cancelArmedTalkover's case, not this one")
        XCTAssertFalse(MediaServicesResetPlan.isTalkoverSpeaking(clipSpeaking: true, breakTrack: 4, duckedFor: nil),
                       "a speaking gap break holds no duck; its stop owns the resume")
        XCTAssertFalse(MediaServicesResetPlan.isTalkoverSpeaking(clipSpeaking: true, breakTrack: 4, duckedFor: 5),
                       "N15: a duck for another track is not this break's talk-over")
        XCTAssertFalse(MediaServicesResetPlan.isTalkoverSpeaking(clipSpeaking: true, breakTrack: 0, duckedFor: nil))
    }

    func testObserverPassesTheTalkoverFlag() throws {
        let observer = try appSource("MediaServicesResetObserver.swift")
        XCTAssertTrue(observer.contains("talkoverSpeaking: interlude.mediaServicesResetTalkoverSpeaking"),
                      "the observer reads it before the stop clears duckedFor")
    }

    func testRebuildAlwaysComesBeforeTheCategory() throws {
        for state in [MediaServicesResetBreak.none, .speaking, .pending] {
            for armed in [true, false] {
                for resume in [true, false] {
                    let steps = MediaServicesResetPlan.plan(break: state, talkoverArmed: armed, mayAutoResume: resume).steps
                    let rebuild = try XCTUnwrap(steps.firstIndex(of: .rebuildVoicePlayers))
                    let category = try XCTUnwrap(steps.firstIndex(of: .reapplyCategory))
                    XCTAssertLessThan(rebuild, category)
                    XCTAssertEqual(steps.filter { $0 == .reapplyCategory }.count, 1)
                }
            }
        }
    }

    /// Sentinel's N1: a reset in the talk-over arm/duck window. Nothing speaks and nothing is handed
    /// out, but the coordinator holds predecoded players and the adapter may hold a duck.
    func testResetWhileTalkoverArmedCancelsTheRunAndReleasesTheDuckFirst() {
        let plan = MediaServicesResetPlan.plan(break: .none, talkoverArmed: true, mayAutoResume: true)
        XCTAssertEqual(plan.steps, [.cancelArmedTalkover, .rebuildVoicePlayers, .releaseAppActivation,
                                    .reapplyCategory, .resumeMusicIfAllowed],
                       "the armed run and its duck go before the players are dropped and the category is set")
        XCTAssertFalse(plan.dropsBreak, "an armed talk-over has not spoken: its held break still airs once in the gap")
    }

    func testCancelArmedTalkoverOnlyWhenArmedAndAlwaysBeforeTheRebuild() throws {
        for state in [MediaServicesResetBreak.none, .speaking, .pending] {
            for armed in [true, false] {
                let steps = MediaServicesResetPlan.plan(break: state, talkoverArmed: armed, mayAutoResume: true).steps
                XCTAssertEqual(steps.contains(.cancelArmedTalkover), armed, "\(state) armed=\(armed)")
                if armed {
                    let cancel = try XCTUnwrap(steps.firstIndex(of: .cancelArmedTalkover))
                    let rebuild = try XCTUnwrap(steps.firstIndex(of: .rebuildVoicePlayers))
                    XCTAssertLessThan(cancel, rebuild)
                }
            }
        }
    }

    func testStopBreakNeverFollowsResumeAndResumeIsLastAndOnce() {
        for state in [MediaServicesResetBreak.none, .speaking, .pending] {
            for armed in [true, false] {
                for resume in [true, false] {
                    let steps = MediaServicesResetPlan.plan(break: state, talkoverArmed: armed, mayAutoResume: resume).steps
                    XCTAssertLessThanOrEqual(steps.filter { $0 == .resumeMusicIfAllowed }.count, 1)
                    if let r = steps.firstIndex(of: .resumeMusicIfAllowed) {
                        XCTAssertEqual(r, steps.count - 1, "resume is the last step")
                        XCTAssertFalse(steps.contains(.stopBreak))
                    }
                    let talkover = MediaServicesResetPlan.plan(break: state, talkoverSpeaking: true,
                                                               talkoverArmed: armed, mayAutoResume: resume).steps
                    XCTAssertLessThanOrEqual(talkover.filter { $0 == .resumeMusicIfAllowed }.count, 1)
                    if let r = talkover.firstIndex(of: .resumeMusicIfAllowed) {
                        XCTAssertEqual(r, talkover.count - 1, "resume is the last step")
                        if let stop = talkover.firstIndex(of: .stopBreak) { XCTAssertLessThan(stop, r) }
                    }
                }
            }
        }
    }

    // MARK: Sentinel's N5: app-target wiring, pinned from source (the app target does not build on Linux).

    private func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AeroDJCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AeroDJCore
            .deletingLastPathComponent() // ios
        return try String(contentsOf: root.appendingPathComponent("AeroDJ/\(name)"), encoding: .utf8)
    }

    func testObserverInstallsOnceAndRemovesItsToken() throws {
        let source = try appSource("MediaServicesResetObserver.swift")
        XCTAssertTrue(source.contains("guard token == nil else { return }"), "start() installs the observer once")
        XCTAssertEqual(source.components(separatedBy: "addObserver(").count - 1, 1, "one observer, one notification")
        XCTAssertTrue(source.contains("AVAudioSession.mediaServicesWereResetNotification"))
        XCTAssertEqual(source.components(separatedBy: "removeObserver(token)").count - 1, 2, "stop() and deinit")
        let coordinator = try appSource("TalkoverCoordinator.swift")
        XCTAssertEqual(coordinator.components(separatedBy: "mediaReset.start(").count - 1, 1)
        XCTAssertEqual(coordinator.components(separatedBy: "MediaServicesResetObserver()").count - 1, 1)
    }

    func testDiscardClearsEveryVoicePlayerCollection() throws {
        let source = try appSource("InterludePlaybackAdapter.swift")
        let start = try XCTUnwrap(source.range(of: "func discardPlayersAfterMediaServicesReset() {"))
        let body = String(source[start.upperBound...].prefix(900))
        for cleared in ["clipPlayer = nil", "ackPlayer = nil", "queue = []", "scriptPlayers = []",
                        "lineCueIDs = []", "resumeLines = []", "ramps = [:]", "rampTask = nil", "duckedFor = nil"] {
            XCTAssertTrue(body.contains(cleared), "discard must clear \(cleared)")
        }
        XCTAssertTrue(body.contains("delegate = nil"), "a late callback from a dead player finds no delegate")
    }

    func testTraceLineIsOneLogSafeLine() {
        XCTAssertEqual(PlaybackLog.mediaServicesReset(break: .speaking, resume: false),
                       "session media services reset break=speaking resume=false")
        XCTAssertEqual(PlaybackLog.mediaServicesReset(break: .none, resume: true),
                       "session media services reset break=none resume=true")
    }
}

/// Sentinel's N6/N7: a cancelled resume is silent and never reaches `play()` as a cancellation.
@MainActor
final class MediaResetResumeTests: XCTestCase {
    private final class FakeMusic {
        var calls = 0
        var sawCancellation = 0
        var refused = 0
        var release: CheckedContinuation<Void, Never>?
        var started = false

        /// Mirrors `resumeIfAllowed`'s catch: a thrown error, cancellation included, becomes a refusal.
        @MainActor func resume() async {
            calls += 1
            started = true
            await withCheckedContinuation { release = $0 }
            do {
                try Task.checkCancellation()
            } catch {
                sawCancellation += 1
                refused += 1
            }
        }
    }

    private func spin(until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    func testCancelBeforeStartIsSilentAndNeverCallsResume() async {
        let gate = MediaResetResume()
        let music = FakeMusic()
        gate.request(isPlaying: { false }, resume: { await music.resume() })
        gate.cancel()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(music.calls, 0)
        XCTAssertEqual(music.refused, 0, "a cancelled resume shows no refusal and no banner")
        XCTAssertFalse(gate.isInFlight)
    }

    func testCancelWhileInFlightNeverReachesPlayAsCancellation() async {
        let gate = MediaResetResume()
        let music = FakeMusic()
        gate.request(isPlaying: { false }, resume: { await music.resume() })
        await spin(until: { music.release != nil })
        XCTAssertTrue(gate.isInFlight)
        gate.cancel() // deinit or stop() while play() is in flight
        music.release?.resume()
        await spin(until: { !gate.isInFlight })
        XCTAssertEqual(music.calls, 1)
        XCTAssertEqual(music.sawCancellation, 0, "the started resume does not inherit the cancel")
        XCTAssertEqual(music.refused, 0)
    }

    func testSecondResetCoalesces() async {
        let gate = MediaResetResume()
        let music = FakeMusic()
        gate.request(isPlaying: { false }, resume: { await music.resume() })
        gate.request(isPlaying: { false }, resume: { await music.resume() }) // replaces the pending one
        await spin(until: { music.release != nil })
        music.release?.resume()
        await spin(until: { !gate.isInFlight && !gate.isPending })
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(music.calls, 1, "two resets before the start make one resume")
        XCTAssertEqual(music.refused, 0)
    }

    /// N11: a reset that lands while a resume is running queues exactly one more pass, so music is
    /// not left silent until Play. Several resets mid-resume still make one rerun.
    func testResetDuringARunningResumeQueuesOneMorePass() async {
        let gate = MediaResetResume()
        let music = FakeMusic()
        gate.request(isPlaying: { false }, resume: { await music.resume() })
        await spin(until: { music.release != nil })
        gate.request(isPlaying: { false }, resume: { await music.resume() })
        gate.request(isPlaying: { false }, resume: { await music.resume() })
        let first = music.release
        music.release = nil
        first?.resume()
        await spin(until: { music.release != nil }) // the rerun is running
        XCTAssertEqual(music.calls, 2)
        music.release?.resume()
        await spin(until: { !gate.isInFlight && !gate.isPending })
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(music.calls, 2, "one rerun, not one per reset")
        XCTAssertEqual(music.refused, 0)
    }

    func testRerunRechecksPlayingAndACancelDropsIt() async {
        var playing = false
        let gate = MediaResetResume()
        let music = FakeMusic()
        gate.request(isPlaying: { playing }, resume: { await music.resume() })
        await spin(until: { music.release != nil })
        gate.request(isPlaying: { playing }, resume: { await music.resume() })
        playing = true // the first pass got music going
        music.release?.resume()
        await spin(until: { !gate.isInFlight && !gate.isPending })
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(music.calls, 1, "the rerun skips while music plays")

        playing = false
        let gate2 = MediaResetResume()
        let music2 = FakeMusic()
        gate2.request(isPlaying: { playing }, resume: { await music2.resume() })
        await spin(until: { music2.release != nil })
        gate2.request(isPlaying: { playing }, resume: { await music2.resume() })
        gate2.cancel() // stop() or deinit: no rerun
        music2.release?.resume()
        await spin(until: { !gate2.isInFlight })
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(music2.calls, 1)
        XCTAssertEqual(music2.refused, 0)
    }

    func testSkipsWhileMusicStillPlays() async {
        let gate = MediaResetResume()
        let music = FakeMusic()
        gate.request(isPlaying: { true }, resume: { await music.resume() })
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(music.calls, 0)
        XCTAssertFalse(gate.isPending)
    }

    func testObserverDeinitAndStopCancelTheResume() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("AeroDJ/MediaServicesResetObserver.swift"), encoding: .utf8)
        let deinitBody = try XCTUnwrap(source.range(of: "deinit {")).upperBound
        XCTAssertTrue(source[deinitBody...].prefix(200).contains("resume.cancel()"), "N6: deinit cancels the resume")
        let stopBody = try XCTUnwrap(source.range(of: "func stop() {")).upperBound
        XCTAssertTrue(source[stopBody...].prefix(200).contains("resume.cancel()"))
        XCTAssertTrue(source.contains("resume.request("), "the observer goes through the coalescing gate")
        XCTAssertFalse(source.contains("Task { @MainActor [weak music]"), "no ad-hoc resume task left")
    }
}
