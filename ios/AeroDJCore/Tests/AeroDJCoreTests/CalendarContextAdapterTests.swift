import XCTest
@testable import AeroDJCore

final class CalendarContextAdapterTests: XCTestCase {
    private var cal: Calendar { Calendar(identifier: .gregorian) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    func testOnlyTodaysEventsIncluded() throws {
        let adapter = CalendarContextAdapter(calendar: cal)
        let today = date(2026, 10, 25, 9)
        let tomorrow = date(2026, 10, 26, 9)
        let events = [
            CalendarEvent(id: "e1", title: "Today", start: today, end: today.addingTimeInterval(3600), isAllDay: false, isCanceled: false, isPrivate: false, calendarName: "Work"),
            CalendarEvent(id: "e2", title: "Tomorrow", start: tomorrow, end: tomorrow.addingTimeInterval(3600), isAllDay: false, isCanceled: false, isPrivate: false, calendarName: "Work"),
        ]
        let items = adapter.todayItems(from: events, now: today, timezone: cal.timeZone)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Today")
    }

    func testCanceledAndPrivateSkipped() throws {
        let adapter = CalendarContextAdapter(calendar: cal)
        let now = date(2026, 10, 25, 9)
        let events = [
            CalendarEvent(id: "c1", title: "Canceled", start: now, end: now.addingTimeInterval(3600), isAllDay: false, isCanceled: true, isPrivate: false, calendarName: "Work"),
            CalendarEvent(id: "c2", title: "Private", start: now, end: now.addingTimeInterval(3600), isAllDay: false, isCanceled: false, isPrivate: true, calendarName: "Work"),
        ]
        XCTAssertTrue(adapter.todayItems(from: events, now: now, timezone: cal.timeZone).isEmpty)
    }

    func testRecurringDedupe() throws {
        let adapter = CalendarContextAdapter(calendar: cal)
        let now = date(2026, 10, 25, 9)
        // Same stable id prefix (recurring master), two instances today.
        let events = [
            CalendarEvent(id: "standup_f27_1", title: "Standup", start: now, end: now.addingTimeInterval(1800), isAllDay: false, isCanceled: false, isPrivate: false, calendarName: "Work"),
            CalendarEvent(id: "standup_f27_2", title: "Standup", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), isAllDay: false, isCanceled: false, isPrivate: false, calendarName: "Work"),
        ]
        XCTAssertEqual(adapter.todayItems(from: events, now: now, timezone: cal.timeZone).count, 1)
    }

    func testAllDayEventIncluded() throws {
        let adapter = CalendarContextAdapter(calendar: cal)
        let now = date(2026, 10, 25, 12)
        let events = [
            CalendarEvent(id: "bday", title: "Birthday", start: now, end: now, isAllDay: true, isCanceled: false, isPrivate: false, calendarName: "Home"),
        ]
        let items = adapter.todayItems(from: events, now: now, timezone: cal.timeZone)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].summary.contains("All day"))
    }

    func testTitleTrimmedAndProvenanceStable() throws {
        let adapter = CalendarContextAdapter(calendar: cal, maxTitleLength: 8)
        let now = date(2026, 10, 25, 9)
        let long = "A very long meeting title about everything"
        let events = [CalendarEvent(id: "long123", title: long, start: now, end: now.addingTimeInterval(3600), isAllDay: false, isCanceled: false, isPrivate: false, calendarName: nil)]
        let items = adapter.todayItems(from: events, now: now, timezone: cal.timeZone)
        XCTAssertTrue(items[0].title.hasSuffix("…"))
        XCTAssertEqual(items[0].provenance, "calendar://long123")
    }

    func testNoEventsTodayEmpty() throws {
        let adapter = CalendarContextAdapter(calendar: cal)
        XCTAssertTrue(adapter.todayItems(from: [], now: Date(), timezone: cal.timeZone).isEmpty)
    }
}