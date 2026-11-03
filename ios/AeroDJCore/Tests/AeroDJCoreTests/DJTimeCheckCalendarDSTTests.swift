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
}
