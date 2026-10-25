import XCTest
@testable import AeroDJCore

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let newYork = calendar("America/New_York")

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, in cal: Calendar = newYork) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

/// Monday 2026-10-26 07:00 New York.
private let fixedNow = at(26, 7)

private func event(_ title: String, _ start: Date, _ end: Date, id: String? = nil, occurrence: Date? = nil,
                   allDay: Bool = false, status: CalendarEventSnapshot.Status = .confirmed,
                   availability: CalendarEventSnapshot.Availability = .busy, calendarID: String = "work") -> CalendarEventSnapshot {
    CalendarEventSnapshot(calendarItemID: id ?? "id-\(title)", occurrenceDate: occurrence ?? start, title: title,
                          start: start, end: end, isAllDay: allDay, status: status,
                          availability: availability, calendarID: calendarID)
}

private actor FakeReader: CalendarEventReading {
    var state: CalendarAccess
    let stored: [CalendarEventSnapshot]
    private(set) var queries: [(Date, Date, Set<String>?)] = []

    init(_ state: CalendarAccess = .fullAccess, _ events: [CalendarEventSnapshot] = []) {
        self.state = state
        self.stored = events
    }

    func access() async -> CalendarAccess { state }
    func calendars() async -> [CalendarDescriptor] { [] }
    func requestFullAccess() async throws -> CalendarAccess { state }
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEventSnapshot] {
        queries.append((start, end, calendarIDs))
        return stored  // deliberately unfiltered: the source must filter itself
    }
}

private let optedIn: Set<String> = ["work", "personal"]

private func source(_ events: [CalendarEventSnapshot],
                    policy: CalendarSourcePolicy = .init(includedCalendarIDs: optedIn, consent: .granted),
                    cal: Calendar = newYork, now: Date = fixedNow) -> CalendarContextSource {
    CalendarContextSource(reader: FakeReader(.fullAccess, events), policy: policy, calendar: cal, now: { now })
}

final class CalendarContextSourceTests: XCTestCase {
    func testEveryNonFullAccessStateThrowsDistinctError() async {
        for state in [CalendarAccess.notDetermined, .restricted, .denied, .writeOnly] {
            let reader = FakeReader(state, [event("A", at(26, 9), at(26, 10))])
            do {
                _ = try await CalendarContextSource(reader: reader, now: { fixedNow }).fetchItems()
                XCTFail("\(state) should throw")
            } catch {
                XCTAssertEqual(error as? CalendarContextError, .accessUnavailable(state))
            }
            let queried = await reader.queries.count
            XCTAssertEqual(queried, 0, "no read attempted for \(state)")
        }
    }

    func testEmptyCalendarAndQueryWindowUseInjectedDay() async throws {
        let reader = FakeReader(.fullAccess, [])
        let items = try await CalendarContextSource(reader: reader, policy: .init(includedCalendarIDs: ["work"]),
                                                    calendar: newYork, now: { fixedNow }).fetchItems()
        XCTAssertEqual(items, [])
        let queries = await reader.queries
        XCTAssertEqual(queries.first?.0, at(26, 0))
        XCTAssertEqual(queries.first?.1, at(27, 0))
        XCTAssertEqual(queries.first?.2, ["work"])
    }

    func testTodayWindowAllDayAndMultiDay() async throws {
        let items = try await source([
            event("Yesterday", at(25, 9), at(25, 10)),
            event("Tomorrow", at(27, 9), at(27, 10)),
            event("Standup", at(26, 9, 30), at(26, 10)),
            event("Holiday", at(26, 0), at(27, 0), allDay: true),
            event("Conference", at(24, 0), at(29, 0), allDay: true),
            event("Night shift", at(25, 22), at(26, 8)),
        ]).fetchItems()
        XCTAssertEqual(items.map(\.title), ["Conference", "Night shift", "Holiday", "Standup"])
        XCTAssertEqual(items.map(\.summary),
                       ["All day, through Wednesday, Oct 28", "Until 8 AM", "All day", "9:30 AM to 10 AM"])
        XCTAssertEqual(items.map(\.eventAt), [nil, at(25, 22), nil, at(26, 9, 30)], "all-day has no clock time")
        XCTAssertEqual(items.last?.expiresAt, at(26, 10))
    }

    func testTimeZoneIsInjectedNotDevice() async throws {
        let tokyo = calendar("Asia/Tokyo")
        // 2026-10-26 07:00 New York == 20:00 Tokyo; 23:30 Tokyo is today there.
        let items = try await source([event("Late call", at(26, 23, 30, in: tokyo), at(27, 0, 15, in: tokyo)),
                                      event("Breakfast", at(26, 8, in: tokyo), at(26, 9, in: tokyo))],
                                     cal: tokyo).fetchItems()
        XCTAssertEqual(items.map(\.title), ["Breakfast", "Late call"])
        XCTAssertEqual(items.last?.summary, "11:30 PM to 12:15 AM, through Tuesday, Oct 27")
    }

    func testCanceledAndUnselectedCalendarsSkipped() async throws {
        let items = try await source([
            event("Canceled", at(26, 9), at(26, 10), status: .canceled),
            event("Home", at(26, 11), at(26, 12), calendarID: "home"),
            event("Kept", at(26, 13), at(26, 14), status: .tentative),
        ], policy: .init(includedCalendarIDs: ["work"], consent: .granted)).fetchItems()
        XCTAssertEqual(items.map(\.title), ["Kept"])
        XCTAssertEqual(items.first?.summary, "1 PM to 2 PM, tentative")
    }

    func testPrivateFromCalendarOrAvailabilityIsRedacted() async throws {
        let items = try await source([
            event("Therapy", at(26, 9), at(26, 10), calendarID: "personal"),
            event("Out of office", at(26, 11), at(26, 12), availability: .unavailable),
            event("Lunch", at(26, 12), at(26, 13)),
        ], policy: .init(includedCalendarIDs: optedIn, privateCalendarIDs: ["personal"], consent: .granted)).fetchItems()
        XCTAssertEqual(items.map(\.title), ["Private event", "Private event", "Lunch"])
        XCTAssertEqual(items.map(\.sensitivity), [.high, .high, .low])
        XCTAssertFalse(items.contains { $0.summary.contains("Therapy") || $0.summary.contains("office") })

        let open = try await source([event("Out of office", at(26, 11), at(26, 12), availability: .unavailable)],
                                    policy: .init(includedCalendarIDs: optedIn, privateAvailabilities: [], consent: .granted)).fetchItems()
        XCTAssertEqual(open.map(\.title), ["Out of office"])
    }

    func testRecurringOccurrencesAndStableIDs() async throws {
        let first = event("Pills", at(26, 8), at(26, 8, 5), id: "series/1:x_y")
        let second = event("Pills", at(26, 20), at(26, 20, 5), id: "series/1:x_y")
        let duplicate = first
        let items = try await source([second, duplicate, first]).fetchItems()
        XCTAssertEqual(items.count, 2, "distinct occurrences kept, exact duplicates removed")
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
        XCTAssertEqual(items.first?.provenance, "calendar-event:series%2F1%3Ax%5Fy@2026-10-26T12:00:00Z")

        let again = try await source([first, second]).fetchItems()
        XCTAssertEqual(again.map(\.id), items.map(\.id), "ids survive refresh")
        XCTAssertEqual(again, items)
    }

    func testMovedOccurrenceKeepsIdentityFromOccurrenceDate() async throws {
        // A single occurrence moved from 08:00 to 09:00 keeps its original occurrence date.
        let original = try await source([event("Gym", at(26, 8), at(26, 9), id: "s")]).fetchItems()
        let moved = try await source([event("Gym", at(26, 9), at(26, 10), id: "s", occurrence: at(26, 8))]).fetchItems()
        XCTAssertEqual(moved.first?.id, original.first?.id)
        XCTAssertEqual(moved.first?.eventAt, at(26, 9))
    }

    func testConsentFollowsPolicyAndGatesNarration() async throws {
        let pending = try await source([event("Standup", at(26, 9), at(26, 10))], policy: .init(includedCalendarIDs: optedIn)).fetchItems()
        XCTAssertEqual(pending.first?.consent, .notRequested)
        let planner = DefaultBriefingPlanner(now: { fixedNow })
        let none = try await planner.plan(from: pending, targetSpokenSeconds: 60)
        XCTAssertTrue(none.segments.isEmpty)

        let granted = try await source([event("Standup", at(26, 9), at(26, 10)),
                                        event("Earlier", at(26, 5), at(26, 6))]).fetchItems()
        XCTAssertEqual(granted.map(\.title), ["Earlier", "Standup"])
        XCTAssertEqual(granted.filter { $0.isNarratable(at: fixedNow) }.map(\.title), ["Standup"],
                       "an event that already ended has expired")
    }

    func testTitlesCleanedAndBounded() async throws {
        let items = try await source([event("  Team\n  sync ", at(26, 9), at(26, 10)),
                                      event("", at(26, 11), at(26, 12)),
                                      event(String(repeating: "x", count: 100), at(26, 13), at(26, 14))]).fetchItems()
        XCTAssertEqual(items[0].title, "Team sync")
        XCTAssertEqual(items[1].title, "Untitled event")
        XCTAssertEqual(items[2].title.count, 81)
    }

    func testNoCalendarReadUntilOptedIn() async throws {
        let reader = FakeReader(.fullAccess, [event("Standup", at(26, 9), at(26, 10))])
        let items = try await CalendarContextSource(reader: reader, policy: .init(consent: .granted),
                                                    calendar: newYork, now: { fixedNow }).fetchItems()
        XCTAssertEqual(items, [])
        let queries = await reader.queries
        XCTAssertTrue(queries.isEmpty, "default policy opts in no calendar and never queries EventKit")
    }

    func testPrivateAndBusyCanBeExcluded() async throws {
        let events = [event("Therapy", at(26, 9), at(26, 10), calendarID: "personal"),
                      event("Focus", at(26, 11), at(26, 12), availability: .busy),
                      event("Lunch", at(26, 12), at(26, 13), availability: .free)]
        let excluded = try await source(events, policy: .init(includedCalendarIDs: optedIn, privateCalendarIDs: ["personal"],
                                                              privateAvailabilities: [.busy], privateHandling: .exclude,
                                                              consent: .granted)).fetchItems()
        XCTAssertEqual(excluded.map(\.title), ["Lunch"])
        let redacted = try await source(events, policy: .init(includedCalendarIDs: optedIn, privateAvailabilities: [.busy],
                                                              consent: .granted)).fetchItems()
        XCTAssertEqual(redacted.map(\.title), ["Private event", "Private event", "Lunch"], "busy blocks hidden")
    }

    func testMidnightTimedEventKeepsItsTime() async throws {
        let items = try await source([event("Launch", at(26, 0), at(26, 0, 30))], now: at(25, 23)).fetchItems()
        XCTAssertEqual(items, [], "tomorrow's midnight is outside today's window")
        let today = try await source([event("Late launch", at(27, 0), at(27, 0, 30)),
                                      event("Midnight", at(26, 0), at(26, 0, 30))], now: at(26, 0)).fetchItems()
        XCTAssertEqual(today.map(\.eventAt), [at(26, 0)])
        XCTAssertEqual(today.first?.summary, "12 AM to 12:30 AM")
    }

    func testDSTDayWindowIs23Hours() async throws {
        // 2026-11-01 is the US fall-back day (25 h); 2027-03-14 spring-forward (23 h).
        let reader = FakeReader(.fullAccess, [])
        let spring = newYork.date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 12))!
        _ = try await CalendarContextSource(reader: reader, policy: .init(includedCalendarIDs: optedIn),
                                            calendar: newYork, now: { spring }).fetchItems()
        let q = await reader.queries
        XCTAssertEqual(q.first.map { $0.1.timeIntervalSince($0.0) }, 23 * 3600)
    }
}
