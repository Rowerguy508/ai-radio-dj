import Foundation
import XCTest
@testable import AeroDJCore

/// Pins the calendar-hour schedule behind the Duo day wash: mid-hour starts, both
/// 2026 America/New_York DST transitions, the day part of each entry, and a later
/// resume that must not keep the 8 AM tint (the UI side of #445).
final class DayWashScheduleTests: XCTestCase {

    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int = 0,
                      calendar: Calendar? = nil) -> Date {
        let cal = calendar ?? eastern
        return cal.date(from: DateComponents(year: year, month: month, day: day,
                                             hour: hour, minute: minute, second: 0))!
    }

    private func hourStarts(from date: Date, calendar: Calendar, count: Int) -> [Date] {
        Array(DayWashSchedule.hourStarts(from: date, calendar: calendar).prefix(count))
    }

    private func localHour(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date)
    }

    func testMidHourStartYieldsTheNextHour() {
        let start = date(2026, 6, 15, hour: 10, minute: 37)
        let next = DayWashSchedule.nextHourStart(after: start, calendar: eastern)
        let comps = eastern.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: next)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 11)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
        XCTAssertEqual(comps.nanosecond, 0)

        let entries = hourStarts(from: start, calendar: eastern, count: 2)
        XCTAssertEqual(entries[0], date(2026, 6, 15, hour: 10))
        XCTAssertEqual(entries[1], date(2026, 6, 15, hour: 11))
    }

    /// America/New_York, Sunday 8 Mar 2026: 01:59 EST is followed by 03:00 EDT.
    func testSpringForwardEntriesSkipTheMissingTwoOClock() {
        let start = date(2026, 3, 8, hour: 1, minute: 30)
        let next = DayWashSchedule.nextHourStart(after: start, calendar: eastern)
        XCTAssertEqual(next, date(2026, 3, 8, hour: 3))
        XCTAssertEqual(localHour(next, calendar: eastern), 3)

        let entries = hourStarts(from: start, calendar: eastern, count: 3)
        XCTAssertEqual(entries.map { localHour($0, calendar: eastern) }, [1, 3, 4],
                       "01:00 then 03:00 local; 02:00 never occurs")
        XCTAssertEqual(entries[0], date(2026, 3, 8, hour: 1))
        XCTAssertEqual(entries[1], date(2026, 3, 8, hour: 3))
        XCTAssertEqual(entries[2], date(2026, 3, 8, hour: 4))
        assertStrictlyIncreasingHourStarts(entries, calendar: eastern)
    }

    /// America/New_York, Sunday 1 Nov 2026: 01:59:59 EDT is followed by 01:00:00 EST.
    func testFallBackEntriesKeepBothOneOClockHours() {
        // 00:30 EDT. date(from:) would be ambiguous at 01:xx, so the window is built from UTC.
        let start = utc("2026-11-01T04:30:00Z")
        let oneEDT = utc("2026-11-01T05:00:00Z")
        let oneEST = utc("2026-11-01T06:00:00Z")
        let twoEST = utc("2026-11-01T07:00:00Z")
        XCTAssertEqual(localHour(oneEDT, calendar: eastern), 1)
        XCTAssertEqual(localHour(oneEST, calendar: eastern), 1)

        let entries = hourStarts(from: start, calendar: eastern, count: 5)
        XCTAssertEqual(entries, [
            utc("2026-11-01T04:00:00Z"), // 00:00 EDT
            oneEDT,                      // 01:00 EDT
            oneEST,                      // 01:00 EST, one real hour later
            twoEST,                      // 02:00 EST
            utc("2026-11-01T08:00:00Z"), // 03:00 EST
        ])
        XCTAssertEqual(entries.map { localHour($0, calendar: eastern) }, [0, 1, 1, 2, 3])
        XCTAssertEqual(Set(entries).count, entries.count, "no duplicated instants")
        assertStrictlyIncreasingHourStarts(entries, calendar: eastern)
        for pair in zip(entries, entries.dropFirst()) {
            XCTAssertEqual(pair.1.timeIntervalSince(pair.0), 3600, accuracy: 0.001,
                           "no hour is skipped; each civil hour is one real hour")
        }
    }

    /// The wash colour follows each entry's local hour, not UTC.
    func testDayPartFollowsEachEntrysLocalHour() {
        // A midsummer day (no DST change) starting at 10:37, plus both 2026 DST nights.
        let windows: [(label: String, start: Date, hours: [Int])] = [
            ("midsummer", date(2026, 6, 15, hour: 10, minute: 37), Array(10...21)),
            ("spring-forward", date(2026, 3, 8, hour: 1, minute: 30), [1, 3, 4, 5, 6, 7]),
            ("fall-back", utc("2026-11-01T04:30:00Z"), [0, 1, 1, 2, 3, 4]),
        ]
        for window in windows {
            let entries = hourStarts(from: window.start, calendar: eastern, count: window.hours.count)
            XCTAssertEqual(entries.map { localHour($0, calendar: eastern) }, window.hours, window.label)
            for (entry, hour) in zip(entries, window.hours) {
                let part = DayPart(hour: localHour(entry, calendar: eastern))
                XCTAssertEqual(part, DayPart(hour: hour), "\(window.label) \(hour):00")
                let colors = DayWashPalette.colors(for: part)
                XCTAssertEqual(colors.top, colors.bottom)
            }
        }

        // 8 AM Eastern in June is 12:00 UTC. Using the UTC hour would pick afternoon.
        let eightAM = date(2026, 6, 15, hour: 8)
        XCTAssertEqual(Calendar.gmt.component(.hour, from: eightAM), 12)
        let entry = DayWashSchedule.currentHourStart(containing: eightAM, calendar: eastern)
        XCTAssertEqual(DayPart(hour: localHour(entry, calendar: eastern)), .morning)
        XCTAssertEqual(DayPart(hour: Calendar.gmt.component(.hour, from: entry)), .afternoon)
    }

    /// Fixed clock at 8 AM, then 2 PM, then 9 PM on the same day (America/New_York).
    /// A later resume must not keep the 8 AM (morning) wash. This is the UI side of
    /// #445; the issue itself stays with the owner for the Duo check.
    func testFixedClockResumeAdvancesTheDayPart() {
        let day = (year: 2026, month: 6, day: 15)
        let cases: [(hour: Int, part: DayPart)] = [
            (8, .morning),
            (14, .afternoon),
            (21, .evening),
        ]
        var parts: [DayPart] = []
        var currentEntries: [Date] = []
        for item in cases {
            let clock = date(day.year, day.month, day.day, hour: item.hour)
            let current = DayWashSchedule.currentHourStart(containing: clock, calendar: eastern)
            XCTAssertEqual(current, clock, "clock is already on the hour at \(item.hour):00")
            XCTAssertEqual(hourStarts(from: clock, calendar: eastern, count: 1).first, current)
            let part = DayPart(hour: localHour(current, calendar: eastern))
            XCTAssertEqual(part, item.part, "\(item.hour):00 should be \(item.part)")
            parts.append(part)
            currentEntries.append(current)
        }
        XCTAssertEqual(parts, [.morning, .afternoon, .evening])
        XCTAssertEqual(Set(currentEntries).count, 3, "each resume has its own current hour")
        XCTAssertNotEqual(currentEntries[1], currentEntries[0],
                          "after a 2 PM resume the current entry is not still 8 AM")
        XCTAssertNotEqual(parts[1], .morning,
                          "the wash must not stay on the 8 AM morning value after a later resume")
        XCTAssertNotEqual(parts[2], .morning)
    }

    // MARK: - Helpers

    private func assertStrictlyIncreasingHourStarts(_ entries: [Date], calendar: Calendar,
                                                    file: StaticString = #filePath, line: UInt = #line) {
        for (earlier, later) in zip(entries, entries.dropFirst()) {
            XCTAssertLessThan(earlier, later, "entries must strictly increase", file: file, line: line)
        }
        for entry in entries {
            let comps = calendar.dateComponents([.minute, .second, .nanosecond], from: entry)
            XCTAssertEqual(comps.minute, 0, "\(entry) is not an hour start", file: file, line: line)
            XCTAssertEqual(comps.second, 0, "\(entry) is not an hour start", file: file, line: line)
            XCTAssertEqual(comps.nanosecond, 0, "\(entry) is not an hour start", file: file, line: line)
        }
        XCTAssertEqual(Set(entries).count, entries.count, "no duplicated instants", file: file, line: line)
    }
}

private extension Calendar {
    static var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }
}
