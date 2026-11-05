import Foundation
import XCTest
@testable import AeroDJCore

/// #379 N1 (Echo): a break resumed after an interruption re-checks its time-sensitive lines at
/// the moment each would air, with the take-time rule (`DJBreakPreparer.timeCheckStillTrue`):
/// a time check past its window is dropped rather than spoken. N2: what was dropped, by kind.
/// Linux green is not device evidence.
final class BreakResumePlanTests: XCTestCase {
    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int, _ seconds: TimeInterval = 0) -> Date {
        eastern.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: hour, minute: minute))!
            .addingTimeInterval(seconds)
    }

    private lazy var check = DJPlannedTimeCheck(
        cueID: UUID(), plannedAt: at(9, 30),
        templates: [.on: "It's {time}.", .comingUp: "Coming up on {time}.", .justAfter: "Just after {time}."],
        calendar: eastern, style: .twelveHour)

    /// The time-check line as rendered for `air`.
    private func timeCheck(air: Date, seconds: Double = 2) -> BreakResumeLine {
        BreakResumeLine(seconds: seconds, sensitivity: .timeCheck(check, text: check.text(at: air)!, airTime: air))
    }

    private func line(_ seconds: Double) -> BreakResumeLine { BreakResumeLine(seconds: seconds) }

    func testAnInWindowResumeKeepsTheTimeCheck() {
        let air = at(9, 45)   // "It's 9:45."
        XCTAssertEqual(check.text(at: air), "It's 9:45.")
        let script = [line(3), timeCheck(air: air), line(4)]
        let plan = BreakResumePlan.plan(from: 0, lines: script, now: air.addingTimeInterval(30))
        XCTAssertEqual(plan.lines, [0, 1, 2])
        XCTAssertNil(plan.drop)
    }

    func testAPastWindowResumeDropsTheTimeCheckAndKeepsTheRest() {
        let air = at(9, 45)
        let script = [line(3), timeCheck(air: air), line(4)]
        // Interrupted on the time check and held near the 45 s limit, then resumed late.
        let plan = BreakResumePlan.plan(from: 1, lines: script, now: air.addingTimeInterval(95))
        XCTAssertEqual(plan.lines, [2], "the closing line still airs")
        XCTAssertEqual(plan.drop, BreakResumeDrop(reason: .stale, line: 1, timeChecks: 1, other: 0))
        XCTAssertEqual(plan.drop?.count, 1)
        XCTAssertEqual(plan.drop?.breakDropped, false)
    }

    /// Echo's case: ~49 s late a "Coming up on" line would name a minute that has passed.
    func testAComingUpLineResumedPastItsMinuteIsDropped() {
        let air = at(9, 44, 20)
        XCTAssertEqual(check.text(at: air), "Coming up on 9:45.")
        let script = [timeCheck(air: air), line(4)]
        XCTAssertEqual(BreakResumePlan.plan(from: 0, lines: script, now: air.addingTimeInterval(30)).lines, [0, 1],
                       "still before 9:45")
        let late = BreakResumePlan.plan(from: 0, lines: script, now: air.addingTimeInterval(49))
        XCTAssertEqual(late.lines, [1], "at 9:45:09 it would be wrong")
        XCTAssertEqual(late.drop?.timeChecks, 1)
    }

    /// The boundary is `DJBreakPreparer.timeCheckTolerance` (90 s) after the air time, measured
    /// when the line would START: now, plus the acknowledgement lead, plus kept lines before it.
    func testTheBoundaryIsMeasuredWhenTheLineWouldAir() {
        let air = at(9, 45)
        XCTAssertEqual(DJBreakPreparer.timeCheckTolerance, 90)
        let script = [line(4), timeCheck(air: air), line(4)]
        XCTAssertEqual(BreakResumePlan.plan(from: 0, lines: script, now: air.addingTimeInterval(86)).lines, [0, 1, 2],
                       "airs exactly 90 s after its air time: kept")
        XCTAssertEqual(BreakResumePlan.plan(from: 0, lines: script, now: air.addingTimeInterval(86.01)).lines, [0, 2],
                       "airs 90.01 s after: dropped")
        XCTAssertEqual(BreakResumePlan.plan(from: 0, lines: script, now: air.addingTimeInterval(84), leadSeconds: 2).lines,
                       [0, 1, 2], "the acknowledgement counts: still 90 s")
        XCTAssertEqual(BreakResumePlan.plan(from: 0, lines: script, now: air.addingTimeInterval(84), leadSeconds: 2.01).lines,
                       [0, 2], "the acknowledgement pushes it past")
    }

    func testOnlyKeptLinesDelayTheNextOne() {
        let air = at(9, 45)
        // Two time checks (a test-only shape): the first is dropped, so it does not delay the second.
        let script = [timeCheck(air: at(9, 40)), timeCheck(air: air)]
        let plan = BreakResumePlan.plan(from: 0, lines: script, now: air.addingTimeInterval(89))
        XCTAssertEqual(plan.lines, [1])
        XCTAssertEqual(plan.drop, BreakResumeDrop(reason: .stale, line: 0, timeChecks: 1, other: 0))
    }

    func testWhenNothingIsLeftTheBreakIsDropped() {
        let air = at(9, 45)
        let plan = BreakResumePlan.plan(from: 1, lines: [line(3), timeCheck(air: air)], now: air.addingTimeInterval(120))
        XCTAssertEqual(plan.lines, [])
        XCTAssertEqual(plan.drop, BreakResumeDrop(reason: .allStale, line: 1, timeChecks: 1, other: 0))
        XCTAssertEqual(plan.drop?.breakDropped, true)
    }

    func testLinesThatAreNotTimedAlwaysAir() {
        let plan = BreakResumePlan.plan(from: 1, lines: [line(3), line(5), line(2)], now: at(23, 59).addingTimeInterval(9_999))
        XCTAssertEqual(plan.lines, [1, 2])
        XCTAssertNil(plan.drop)
        XCTAssertEqual(BreakResumePlan.plan(from: 3, lines: [line(3)], now: at(9, 0)), BreakResumePlan(lines: [], drop: nil))
    }

    func testATimeCheckWithoutItsAirTimeOrWithOtherWordsFailsClosed() {
        let air = at(9, 45)
        let noAir = BreakResumeLine(seconds: 2, sensitivity: .timeCheck(check, text: "It's 9:45.", airTime: nil))
        let otherWords = BreakResumeLine(seconds: 2, sensitivity: .timeCheck(check, text: "It's 9:40.", airTime: air))
        XCTAssertEqual(BreakResumePlan.plan(from: 0, lines: [noAir, line(2)], now: air).lines, [1])
        XCTAssertEqual(BreakResumePlan.plan(from: 0, lines: [otherWords, line(2)], now: air).lines, [1])
    }

    func testLinesForAPreparedBreakMarkOnlyTheTimeCheckClip() {
        let air = at(9, 45)
        let cues = ["That was Song 0.", "It's 9:45.", "Up next, Song 1."].enumerated().map { i, text in
            NarrationCue(id: i == 1 ? check.cueID : UUID(), order: i, group: 0, kind: .transition, text: text,
                         estimatedSeconds: 2, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        }
        let clips = zip(cues, [3.0, 2.0, 4.0]).map { cue, seconds in
            RenderedClip(cueID: cue.id, audio: CachedAudio(data: Data([1]), seconds: seconds, providerID: "device", voiceID: "v"),
                         cacheKey: "k", attempts: [])
        }
        var prepared = PreparedDJBreak(afterTrack: 0, cues: cues, clips: clips, attributions: [:])
        XCTAssertEqual(BreakResumeLine.lines(for: prepared), [line(3), line(2), line(4)], "no time check in the break")
        prepared.timeCheck = check
        prepared.timeCheckAirTime = air
        let lines = BreakResumeLine.lines(for: prepared)
        XCTAssertEqual(lines, [line(3), timeCheck(air: air, seconds: 2), line(4)])
    }

    func testDroppedRemainderCountsByKind() {
        let air = at(9, 45)
        let script = [line(3), timeCheck(air: air), line(4)]
        XCTAssertEqual(BreakResumeDrop.remaining(script, from: 1, reason: .noResume),
                       BreakResumeDrop(reason: .noResume, line: 1, timeChecks: 1, other: 1))
        XCTAssertEqual(BreakResumeDrop.remaining(script, from: 2, reason: .pauseExpired).count, 1)
        XCTAssertEqual(BreakResumeDrop.remaining(script, from: 5, reason: .musicPlaying).count, 0)
    }
}
