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

    func testRebuildAlwaysComesBeforeTheCategory() {
        for state in [MediaServicesResetBreak.none, .speaking, .pending] {
            for resume in [true, false] {
                let steps = MediaServicesResetPlan.plan(break: state, mayAutoResume: resume).steps
                let rebuild = try! XCTUnwrap(steps.firstIndex(of: .rebuildVoicePlayers))
                let category = try! XCTUnwrap(steps.firstIndex(of: .reapplyCategory))
                XCTAssertLessThan(rebuild, category)
                XCTAssertEqual(steps.filter { $0 == .reapplyCategory }.count, 1)
            }
        }
    }

    func testTraceLineIsOneLogSafeLine() {
        XCTAssertEqual(PlaybackLog.mediaServicesReset(break: .speaking, resume: false),
                       "session media services reset break=speaking resume=false")
        XCTAssertEqual(PlaybackLog.mediaServicesReset(break: .none, resume: true),
                       "session media services reset break=none resume=true")
    }
}
