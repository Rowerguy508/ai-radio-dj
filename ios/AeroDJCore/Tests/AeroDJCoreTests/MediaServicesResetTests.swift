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
