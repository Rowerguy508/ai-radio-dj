import Foundation
import XCTest
@testable import AeroDJCore

// Echo's #357 follow-ups (-Fry). (a) The spoken time follows the planned check's own calendar and
// time zone, with a non-Gregorian calendar in a zone that is neither New York nor UTC, so reading
// `Calendar.current` instead fails on any CI machine. (b) The DST fall-back hour: the repeated
// 1:30 is "It's 1:30." both times (true both times, no am/pm or zone claim), and a line that
// would name a time across the change ("Almost 2 o'clock." at 1:58 EDT, when the clock next reads
// 1:00 EST) is not written. Pure functions only; no clock, no render.
final class DJTimeCheckCalendarDSTTests: XCTestCase {
    private static let templates: [DJTimeCheckRelation: String] =
        [.on: "It's {time}.", .comingUp: "Almost {time}.", .justAfter: "Just after {time}."]

    private func check(_ calendar: Calendar, _ style: DJClockStyle) -> DJPlannedTimeCheck {
        DJPlannedTimeCheck(cueID: UUID(), plannedAt: Date(timeIntervalSince1970: 0), templates: Self.templates,
                           calendar: calendar, style: style)
    }

    private func calendar(_ id: Calendar.Identifier, _ zone: String) -> Calendar {
        var c = Calendar(identifier: id)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // (a) Buddhist (Bangkok, +7) and Japanese (Kolkata, +5:30) calendars, 24 h and 12 h.
    func testNonGregorianCalendarsSpeakTheirOwnZonesTime() {
        XCTAssertEqual(DJClockStyle(locale: Locale(identifier: "th_TH@calendar=buddhist")), .twentyFourHour)
        XCTAssertEqual(DJClockStyle(locale: Locale(identifier: "ja_JP@calendar=japanese")), .twentyFourHour)

        let buddhist = calendar(.buddhist, "Asia/Bangkok")
        let at = utc("2026-11-02T14:12:20Z")   // 21:12:20 in Bangkok, Buddhist year 2569
        XCTAssertEqual(buddhist.component(.year, from: at), 2569, "a non-Gregorian calendar")
        XCTAssertEqual(check(buddhist, .twentyFourHour).text(at: at), "Just after 21:10.")
        XCTAssertEqual(check(buddhist, .twelveHour).text(at: at), "Just after 9:10.")

        let japanese = calendar(.japanese, "Asia/Kolkata")
        let air = utc("2026-11-02T14:28:30Z")  // 19:58:30 in Kolkata (+5:30)
        XCTAssertNotEqual(japanese.component(.year, from: air), 2026, "a non-Gregorian calendar")
        let tc = check(japanese, .twentyFourHour)
        XCTAssertEqual(tc.text(at: air), "Almost 20:00.")
        XCTAssertEqual(check(japanese, .twelveHour).text(at: air), "Almost 8 o'clock.")
        XCTAssertEqual(tc.text(at: utc("2026-11-02T18:30:00Z")), "It's midnight.", "0:00 in Kolkata")
        // The backup check reads T in the same calendar: kept just before 20:00, dropped at it.
        XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(tc, saying: "Almost 20:00.", airTime: air,
                                                         now: utc("2026-11-02T14:30:00Z").addingTimeInterval(-0.1)))
        XCTAssertFalse(DJBreakPreparer.timeCheckStillTrue(tc, saying: "Almost 20:00.", airTime: air,
                                                          now: utc("2026-11-02T14:30:00Z")))
    }

    private var eastern: Calendar { calendar(.gregorian, "America/New_York") }

    // (b) America/New_York, Sunday Nov 1, 2026: 1:59:59 EDT is followed by 1:00:00 EST.
    func testTheRepeatedFallBackHalfHourIsTrueBothTimes() {
        let first = utc("2026-11-01T05:30:00Z")   // 1:30 EDT
        let second = utc("2026-11-01T06:30:00Z")  // 1:30 EST, an hour later
        XCTAssertEqual(eastern.dateComponents([.hour, .minute], from: first), eastern.dateComponents([.hour, .minute], from: second))
        for style in DJClockStyle.allCases {
            let tc = check(eastern, style)
            for (name, at) in [("EDT", first), ("EST", second)] {
                XCTAssertEqual(tc.text(at: at), "It's 1:30.", "\(name) \(style): the clock reads 1:30 both times")
                XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(tc, saying: "It's 1:30.", airTime: at, now: at.addingTimeInterval(60)),
                              "\(name) \(style)")
            }
        }
    }

    func testNoLineNamesATimeAcrossTheFallBack() {
        let tc = check(eastern, .twelveHour)
        let late = utc("2026-11-01T05:58:00Z")    // 1:58 EDT: next comes 1:00 EST, not 2:00
        XCTAssertNil(tc.text(at: late), "not \"Almost 2 o'clock.\"")
        XCTAssertNil(check(eastern, .twentyFourHour).text(at: late))
        XCTAssertFalse(DJBreakPreparer.timeCheckStillTrue(tc, saying: "Almost 2 o'clock.", airTime: late, now: late))
        // Either side of the change, and the second pass of the hour, read as usual.
        XCTAssertEqual(tc.text(at: utc("2026-11-01T05:57:00Z")), "Just after 1:55.", "1:57 EDT")
        XCTAssertEqual(tc.text(at: utc("2026-11-01T06:02:00Z")), "Just after 1 o'clock.", "1:02 EST")
        XCTAssertEqual(tc.text(at: utc("2026-11-01T06:58:00Z")), "Almost 2 o'clock.", "1:58 EST: 2:00 EST comes next")
        XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(tc, saying: "Just after 1 o'clock.", airTime: utc("2026-11-01T06:02:00Z"),
                                                         now: utc("2026-11-01T06:00:30Z")))
    }

    // The spring-forward night (Mar 8, 2026): 2:00 never shows, so 1:58 EST names nothing.
    func testNoLineNamesAnHourTheSpringForwardSkips() {
        let tc = check(eastern, .twelveHour)
        XCTAssertNil(tc.text(at: utc("2026-03-08T06:58:00Z")), "1:58 EST: next comes 3:00 EDT")
        XCTAssertEqual(tc.text(at: utc("2026-03-08T07:01:00Z")), "Just after 3 o'clock.", "3:01 EDT")
        XCTAssertEqual(tc.text(at: utc("2026-03-08T06:55:00Z")), "It's 1:55.", "1:55 EST")
    }

    // MARK: #360 — the rounded hour is the wall clock the listener will see

    /// Fall-back 2026-11-01 01:58 EDT, both folds, and the take 20 s later (#360).
    func testFallBackDoesNotNameTwoOClockAndTheTakeGuardAgrees() {
        let first = utc("2026-11-01T05:58:00Z")    // 1:58 EDT
        let firstTake = utc("2026-11-01T05:58:20Z")
        let second = utc("2026-11-01T06:58:00Z")   // 1:58 EST, the repeated hour
        for style in DJClockStyle.allCases {
            XCTAssertNil(DJTimeCheck.reading(first, calendar: eastern, style: style), "\(style): 1:58 EDT")
            XCTAssertNil(check(eastern, style).text(at: first), "\(style)")
            XCTAssertNil(DJTimeCheck.roundedInstant(at: first, calendar: eastern), "\(style)")
            let again = DJTimeCheck.reading(second, calendar: eastern, style: style)
            XCTAssertEqual(again?.relation, .comingUp, "\(style): 1:58 EST still rounds forward")
            XCTAssertEqual(again?.time, (style == .twelveHour ? "2 o'clock" : "2:00") as String?, "\(style): 2:00 EST does come next")
            XCTAssertEqual(check(eastern, style).text(at: second), style == .twelveHour ? "Almost 2 o'clock." : "Almost 2:00.")
        }
        XCTAssertFalse(DJBreakPreparer.timeCheckStillTrue(check(eastern, .twelveHour), saying: "Almost 2 o'clock.",
                                                          airTime: first, now: firstTake))
        XCTAssertFalse(DJBreakPreparer.timeCheckStillTrue(check(eastern, .twentyFourHour), saying: "Almost 2:00.",
                                                          airTime: first, now: firstTake))
        XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(check(eastern, .twelveHour), saying: "Almost 2 o'clock.",
                                                         airTime: second, now: second.addingTimeInterval(20)))
        XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(check(eastern, .twentyFourHour), saying: "Almost 2:00.",
                                                         airTime: second, now: second.addingTimeInterval(20)))
    }

    /// Spring-forward 2027-03-14 01:58 EST names 02:00, which never occurs (#360).
    func testSpringForward2027DoesNotNameTheSkippedHour() {
        let gap = utc("2027-03-14T06:58:00Z")      // 1:58 EST; 2:00 does not occur
        let after = utc("2027-03-14T07:01:00Z")    // 3:01 EDT
        for style in DJClockStyle.allCases {
            XCTAssertNil(DJTimeCheck.reading(gap, calendar: eastern, style: style), "\(style)")
            XCTAssertNil(check(eastern, style).text(at: gap), "\(style)")
            XCTAssertFalse(DJBreakPreparer.timeCheckStillTrue(
                check(eastern, style),
                saying: style == .twelveHour ? "Almost 2 o'clock." : "Almost 2:00.",
                airTime: gap, now: gap.addingTimeInterval(20)))
        }
        XCTAssertEqual(check(eastern, .twelveHour).text(at: after), "Just after 3 o'clock.")
        XCTAssertEqual(check(eastern, .twentyFourHour).text(at: after), "Just after 3:00.")
        XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(check(eastern, .twelveHour), saying: "Just after 3 o'clock.",
                                                         airTime: after, now: after.addingTimeInterval(20)))
    }

    /// The next night is a normal EST hour: 01:58 rounds to 02:00 and may air (#360 control).
    func testNovemberSecondIsAnOrdinaryEstHour() {
        let at = utc("2026-11-02T06:58:00Z")       // 1:58 EST
        XCTAssertEqual(DJTimeCheck.reading(at, calendar: eastern, style: .twelveHour)?.time, "2 o'clock" as String?)
        XCTAssertEqual(DJTimeCheck.reading(at, calendar: eastern, style: .twentyFourHour)?.time, "2:00" as String?)
        XCTAssertEqual(check(eastern, .twelveHour).text(at: at), "Almost 2 o'clock.")
        XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(check(eastern, .twelveHour), saying: "Almost 2 o'clock.",
                                                         airTime: at, now: at.addingTimeInterval(20)))
        XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(check(eastern, .twentyFourHour), saying: "Almost 2:00.",
                                                         airTime: at, now: at.addingTimeInterval(20)))
    }

    /// Noon, midnight, and both hour cycles on the control day. The DST rule must not move these.
    func testNoonMidnightAndBothHourCyclesOnTheControlDay() {
        // 2026-11-02 is EST (UTC−5) all day. 19:40 EST is 00:40 UTC on Nov 3.
        let cases: [(Date, DJClockStyle, String, DJTimeCheckRelation)] = [
            (utc("2026-11-02T16:58:00Z"), .twelveHour, "noon", .comingUp),          // 11:58 EST
            (utc("2026-11-02T17:00:00Z"), .twelveHour, "noon", .on),                // 12:00 EST
            (utc("2026-11-02T16:58:00Z"), .twentyFourHour, "noon", .comingUp),
            (utc("2026-11-03T04:58:00Z"), .twelveHour, "midnight", .comingUp),      // 23:58 EST
            (utc("2026-11-02T05:00:00Z"), .twelveHour, "midnight", .on),            // 00:00 EST
            (utc("2026-11-03T04:58:00Z"), .twentyFourHour, "midnight", .comingUp),
            (utc("2026-11-03T00:40:00Z"), .twelveHour, "7:40", .on),                // 19:40 EST
            (utc("2026-11-03T00:40:00Z"), .twentyFourHour, "19:40", .on),
            (utc("2026-11-03T00:58:00Z"), .twentyFourHour, "20:00", .comingUp),     // 19:58 EST
            (utc("2026-11-02T05:02:00Z"), .twelveHour, "midnight", .justAfter),     // 00:02 EST
            (utc("2026-11-02T17:04:00Z"), .twelveHour, "12:05", .comingUp),        // 12:04 EST
        ]
        for (at, style, time, relation) in cases {
            let reading = DJTimeCheck.reading(at, calendar: eastern, style: style)
            XCTAssertEqual(reading?.time, time as String?, "\(at) \(style) \(time)")
            XCTAssertEqual(reading?.relation, relation, "\(style) \(time)")
            let words: String
            switch relation {
            case .on: words = "It's \(time)."
            case .comingUp: words = "Almost \(time)."
            case .justAfter: words = "Just after \(time)."
            }
            XCTAssertEqual(check(eastern, style).text(at: at), words)
            XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(check(eastern, style), saying: words, airTime: at, now: at))
        }
        // "Almost noon." does not stay true once noon has arrived.
        let beforeNoon = utc("2026-11-02T16:58:00Z")
        XCTAssertFalse(DJBreakPreparer.timeCheckStillTrue(check(eastern, .twelveHour), saying: "Almost noon.",
                                                          airTime: beforeNoon, now: utc("2026-11-02T17:00:00Z")))
    }

    /// Europe/London: fall back at 02:00 on 2026-10-25, spring forward at 01:00 on 2027-03-28.
    func testLondonTransitionsUseTheWallClockToo() {
        let london = calendar(.gregorian, "Europe/London")
        let fold = utc("2026-10-25T00:58:00Z")     // 01:58 BST; clocks go back to 01:00 GMT
        let second = utc("2026-10-25T01:58:00Z")   // 01:58 GMT; 02:00 GMT comes next
        let gap = utc("2027-03-28T00:58:00Z")      // 00:58 GMT; 01:00 never occurs (02:00 BST is next)
        let after = utc("2027-03-28T01:01:00Z")    // 02:01 BST
        for style in DJClockStyle.allCases {
            XCTAssertNil(DJTimeCheck.reading(fold, calendar: london, style: style), "\(style): 1:58 BST")
            XCTAssertNil(check(london, style).text(at: fold))
            XCTAssertFalse(DJBreakPreparer.timeCheckStillTrue(
                check(london, style), saying: style == .twelveHour ? "Almost 2 o'clock." : "Almost 2:00.",
                airTime: fold, now: fold.addingTimeInterval(20)))
            XCTAssertNil(DJTimeCheck.reading(gap, calendar: london, style: style), "\(style): 0:58 GMT")
            XCTAssertFalse(DJBreakPreparer.timeCheckStillTrue(
                check(london, style), saying: style == .twelveHour ? "Almost 1 o'clock." : "Almost 1:00.",
                airTime: gap, now: gap.addingTimeInterval(20)))
            let kept = DJTimeCheck.reading(second, calendar: london, style: style)
            XCTAssertEqual(kept?.time, (style == .twelveHour ? "2 o'clock" : "2:00") as String?, "\(style): 1:58 GMT")
        }
        XCTAssertEqual(check(london, .twelveHour).text(at: second), "Almost 2 o'clock.")
        XCTAssertTrue(DJBreakPreparer.timeCheckStillTrue(check(london, .twelveHour), saying: "Almost 2 o'clock.",
                                                         airTime: second, now: second.addingTimeInterval(20)))
        XCTAssertEqual(check(london, .twentyFourHour).text(at: after), "Just after 2:00.")
        XCTAssertEqual(check(london, .twelveHour).text(at: after), "Just after 2 o'clock.")
    }

    /// The opener (and an ordinary break the rules would have allowed) omits the false hour and
    /// says why. The rest of the break is planned. No "2 o'clock" is written down.
    func testAPlanAtTheFallBackOmitsTheTimeCheckAndReportsIt() {
        let when = utc("2026-11-01T05:58:00Z")
        var calendar = self.eastern
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let clock = DJPlanClock(now: when, calendar: calendar, style: .twelveHour)
        var writer = DJScriptWriter(cadence: DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 1, shapes: .natural)
        let plan = writer.plan(tracks: djTracks(8), briefing: nil, hour: 1, clock: clock)
        let opener = plan.breaks[0]
        XCTAssertEqual(opener.shape, .showOpener)
        XCTAssertNil(opener.timeCheck, "no time-check slot when 2:00 is not the next wall time")
        XCTAssertEqual(plan.ordinaryCapReport.omittedOpenerTimeChecks[opener.afterTrack], .notOnTheClock)
        XCTAssertEqual(plan.ordinaryCapReport.droppedTimeChecks[opener.afterTrack]?.reason, .notOnTheClock)
        for cue in plan.breaks.flatMap(\.cues) {
            XCTAssertFalse(cue.text.localizedCaseInsensitiveContains("o'clock"), cue.text)
            XCTAssertFalse(cue.text.contains("2:00"), cue.text)
        }
        XCTAssertGreaterThanOrEqual(opener.cues.count, 2, "welcome and closing still plan")
        XCTAssertEqual(writer.testTimeCheckCount, 1, "the omission occupies the spacing slot")
        // The repeated hour is a real 1:58. The opener may say 2 o'clock.
        let second = DJPlanClock(now: utc("2026-11-01T06:58:00Z"), calendar: calendar, style: .twelveHour)
        var again = DJScriptWriter(cadence: DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 1, shapes: .natural)
        let spoken = again.plan(tracks: djTracks(8), briefing: nil, hour: 1, clock: second)
        XCTAssertNotNil(spoken.breaks[0].timeCheck)
        XCTAssertTrue(spoken.breaks[0].cues.contains { $0.text.contains("2 o'clock") })
        XCTAssertNil(spoken.ordinaryCapReport.omittedOpenerTimeChecks[spoken.breaks[0].afterTrack])
    }
}
