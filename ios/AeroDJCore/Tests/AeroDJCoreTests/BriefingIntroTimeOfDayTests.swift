import XCTest
@testable import AeroDJCore

// The briefing now plays once per local day on the first listening session, at any
// hour (owner decision, 2026-10-29). Spoken intro and briefing lines must not assume
// it is morning. Only spoken text is checked; type names may still say "Morning".

private func zoned(_ id: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: id)!
    return calendar
}

private let newYork = zoned("America/New_York")

/// 2026-10-26 in New York at the given local time (plus `dayOffset` days).
private func local(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: 10, day: 26 + dayOffset, hour: hour, minute: minute))!
}

private func items(createdBefore now: Date) -> [ContextItem] {
    [ContextItem(source: .userShared, createdAt: now.addingTimeInterval(-600), title: "Renew the parking permit",
                 summary: "", sensitivity: .low, consent: .granted, provenance: "test:permit"),
     ContextItem(source: .obsidian, createdAt: now.addingTimeInterval(-300), title: "Call the plumber back",
                 summary: "", sensitivity: .low, consent: .granted, provenance: "test:plumber")]
}

private func engine(at now: Date, calendar: Calendar = newYork) -> MorningBriefingEngine {
    MorningBriefingEngine(calendar: calendar, now: { now })
}

/// Every spoken line of the engine's script, with items and with the all-clear fallback.
private func engineLines(at now: Date, calendar: Calendar = newYork) -> [String] {
    let e = engine(at: now, calendar: calendar)
    return e.script(from: items(createdBefore: now)).segments.map(\.text) + e.script(from: []).segments.map(\.text)
}

private let morningWords = ["morning", "morning show"]

private func assertNoMorning(_ lines: [String], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    for text in lines {
        for word in morningWords {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(label): \"\(text)\"", file: file, line: line)
        }
    }
}

final class BriefingIntroTimeOfDayTests: XCTestCase {
    // MARK: MorningBriefingEngine opener and fallback

    func testEightAMGreetsWithMorning() {
        let now = local(8)
        let script = engine(at: now).script(from: items(createdBefore: now))
        XCTAssertEqual(script.segments.first?.text, "Good morning. I'll keep this short before the music.")
        XCTAssertEqual(engine(at: now).script(from: []).segments.first?.text,
                       "Good morning. You're all clear. Nothing needs your attention right now. Enjoy the music.")
    }

    func testOnePMAndEightPMHaveNoMorningWording() {
        let afternoon = engineLines(at: local(13))
        XCTAssertEqual(afternoon.first, "Good afternoon. I'll keep this short before the music.")
        assertNoMorning(afternoon, "1 PM")
        let evening = engineLines(at: local(20))
        XCTAssertEqual(evening.first, "Good evening. I'll keep this short before the music.")
        assertNoMorning(evening, "8 PM")
        // Every hour from noon to midnight: never "morning".
        for hour in 12..<24 { assertNoMorning(engineLines(at: local(hour, 30)), "\(hour):30") }
    }

    func testCrossesMidnight() {
        XCTAssertEqual(engineLines(at: local(23, 59)).first, "Good evening. I'll keep this short before the music.")
        let pastMidnight = engineLines(at: local(0, 1, dayOffset: 1))
        XCTAssertEqual(pastMidnight.first, "Hi there. I'll keep this short before the music.")
        assertNoMorning(pastMidnight, "00:01")
        assertNoMorning(engineLines(at: local(3, 59, dayOffset: 1)), "03:59")
        XCTAssertEqual(engineLines(at: local(4, 0, dayOffset: 1)).first, "Good morning. I'll keep this short before the music.")
        XCTAssertEqual(engineLines(at: local(11, 59, dayOffset: 1)).first, "Good morning. I'll keep this short before the music.")
        XCTAssertEqual(engineLines(at: local(12, 0, dayOffset: 1)).first, "Good afternoon. I'll keep this short before the music.")
        XCTAssertEqual(engineLines(at: local(17, 0, dayOffset: 1)).first, "Good evening. I'll keep this short before the music.")
    }

    func testTimeZoneComesFromInjectedCalendarNotDevice() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        // The device says it is 1 AM on the next day (UTC+14); the injected calendars decide.
        NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")!
        let instant = local(8) // 08:00 New York = 12:00 London = 21:00 Tokyo
        XCTAssertEqual(engineLines(at: instant, calendar: newYork).first,
                       "Good morning. I'll keep this short before the music.")
        let london = engineLines(at: instant, calendar: zoned("Europe/London"))
        XCTAssertEqual(london.first, "Good afternoon. I'll keep this short before the music.")
        assertNoMorning(london, "London noon")
        let tokyo = engineLines(at: instant, calendar: zoned("Asia/Tokyo"))
        XCTAssertEqual(tokyo.first, "Good evening. I'll keep this short before the music.")
        assertNoMorning(tokyo, "Tokyo 9 PM")
    }

    // MARK: DJScriptWriter (the lines the live session actually speaks)

    /// Plans an approved briefing through the writer at the local hour of `now` in `calendar`.
    private func writerLines(at now: Date, calendar: Calendar = newYork, seed: UInt64) -> [String] {
        let handoff = engine(at: now, calendar: calendar).script(from: items(createdBefore: now)).handoff(maxSpokenSeconds: 150)
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed, stationName: "OnAirly")
        let plan = writer.plan(tracks: djTracks(21), briefing: handoff, hour: calendar.component(.hour, from: now))
        return plan.breaks.flatMap { $0.cues.map(\.text) }
    }

    func testWriterGreetingFollowsLocalHour() {
        for seed in UInt64(1)...20 {
            let morning = writerLines(at: local(8), seed: seed)
            XCTAssertTrue(morning.first?.localizedCaseInsensitiveContains("morning") == true, "8 AM seed \(seed): \(morning.first ?? "")")
            assertNoMorning(writerLines(at: local(13), seed: seed), "writer 1 PM seed \(seed)")
            assertNoMorning(writerLines(at: local(20), seed: seed), "writer 8 PM seed \(seed)")
            assertNoMorning(writerLines(at: local(0, 30, dayOffset: 1), seed: seed), "writer 00:30 seed \(seed)")
            assertNoMorning(writerLines(at: local(8), calendar: zoned("Asia/Tokyo"), seed: seed), "writer Tokyo 9 PM seed \(seed)")
        }
    }

    func testBriefingFramingPoolsNeverSayMorning() {
        let tone = EditorialTone.warm
        assertNoMorning(tone.briefingLead + tone.briefingOutro + tone.closing + tone.continuation + tone.stationID,
                        "hour-independent pool")
        for part in [DayPart.afternoon, .evening, .lateNight] {
            assertNoMorning(tone.greetings[part, default: []] + tone.atmosphere[part, default: []], "\(part)")
        }
    }
}
