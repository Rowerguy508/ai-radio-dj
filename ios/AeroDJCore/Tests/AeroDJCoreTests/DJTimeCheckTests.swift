import Foundation
import XCTest
@testable import AeroDJCore

// Spoken time checks (lane 2 part 2, #342, -Fry). Pure Core: the clock is always injected.

private struct FixedExtraLine: DJBreakExtraLineSource {
    func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine? {
        DJExtraLine(text: "Bit of rain after \(previous.id).", attribution: .presenter)
    }
}

final class DJTimeCheckTests: XCTestCase {
    private let dense = DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1)

    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// 2026-10-31 at `hour:minute` in New York.
    private func date(_ hour: Int, _ minute: Int, second: Int = 0, day: Int = 31) -> Date {
        eastern.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    private func clock(_ hour: Int, _ minute: Int, style: DJClockStyle = .twelveHour, airTimes: [Int: Date] = [:]) -> DJPlanClock {
        DJPlanClock(now: date(hour, minute), calendar: eastern, style: style, airTimes: airTimes)
    }

    /// Time checks heavy, so a plan offers one wherever the rules allow. `spacing` 0 lifts the
    /// 30-minute rule so the per-break rules can be seen on their own.
    private func heavy(spacing: Double = 30 * 60) -> DJBreakShapeConfig {
        DJBreakShapeConfig(weights: [.timeCheckIntro: 1000, .comingUpOnly: 1], timeCheckMinSpacingSeconds: spacing)
    }

    /// `dense` with the one ordinary-break cap (#349: the natural shapes fit
    /// `DJCadence.maxOrdinaryBreakSeconds`, not a shape-config cap) set to `seconds`.
    private func dense(cap seconds: Int) -> DJCadence {
        var cadence = dense
        cadence.maxOrdinaryBreakSeconds = seconds
        return cadence
    }

    private func timeChecks(_ plan: DJSessionPlan) -> [(DJBreak, NarrationCue)] {
        plan.breaks.compactMap { b in
            b.timeCheckCueID.flatMap { id in b.cues.first { $0.id == id } }.map { (b, $0) }
        }
    }

    // MARK: Rendering

    func testRoundingEdgeCases() {
        func say(_ h: Int, _ m: Int, _ style: DJClockStyle = .twelveHour) -> String {
            let r = DJTimeCheck.rounded(hour: h, minute: m)
            return DJTimeCheck.spokenTime(hour: r.hour, minute: r.minute, style: style)
        }
        XCTAssertEqual(say(7, 40), "7:40")
        XCTAssertEqual(say(7, 42), "7:40")
        XCTAssertEqual(say(7, 43), "7:45")
        XCTAssertEqual(say(7, 58), "8 o'clock", "x:58 rounds to the next hour, never 7:60")
        XCTAssertEqual(say(7, 57), "7:55")
        XCTAssertEqual(say(8, 2), "8 o'clock")
        XCTAssertEqual(say(8, 3), "8:05")
        XCTAssertEqual(say(11, 58), "noon", "11:58 rounds to 12")
        XCTAssertEqual(say(12, 0), "noon")
        XCTAssertEqual(say(12, 4), "12:05")
        XCTAssertEqual(say(12, 58), "1 o'clock")
        XCTAssertEqual(say(19, 40), "7:40", "12-hour, no am/pm")
        XCTAssertEqual(say(23, 58), "midnight", "wraps past midnight")
        XCTAssertEqual(say(0, 0), "midnight")
        XCTAssertEqual(say(0, 2), "midnight")
        XCTAssertEqual(say(0, 3), "12:05")
        XCTAssertEqual(say(19, 40, .twentyFourHour), "19:40")
        XCTAssertEqual(say(19, 58, .twentyFourHour), "20:00")
        XCTAssertEqual(say(0, 4, .twentyFourHour), "00:05")
        XCTAssertEqual(say(23, 58, .twentyFourHour), "midnight")
        XCTAssertEqual(say(11, 59, .twentyFourHour), "noon")

        XCTAssertEqual(DJTimeCheck.rounded(hour: 7, minute: 58).relation, .comingUp)
        XCTAssertEqual(DJTimeCheck.rounded(hour: 7, minute: 40).relation, .on)
        XCTAssertEqual(DJTimeCheck.rounded(hour: 7, minute: 42).relation, .justAfter)
        XCTAssertEqual(DJTimeCheck.rounded(hour: 23, minute: 58).hour, 0)
    }

    func testEveryMinuteOfTheDayRendersSensibly() {
        for style in DJClockStyle.allCases {
            for raw in 0..<(24 * 60) {
                let r = DJTimeCheck.rounded(hour: raw / 60, minute: raw % 60)
                XCTAssertEqual(r.minute % 5, 0)
                XCTAssertTrue((0..<24).contains(r.hour))
                let rounded = r.hour * 60 + r.minute
                let diff = (rounded - raw + 1440 + 720) % 1440 - 720     // signed, across midnight
                XCTAssertLessThanOrEqual(abs(diff), 2, "\(raw)")
                XCTAssertEqual(r.relation, diff == 0 ? .on : (diff > 0 ? .comingUp : .justAfter), "\(raw)")
                let text = DJTimeCheck.spokenTime(hour: r.hour, minute: r.minute, style: style)
                XCTAssertFalse(text.contains(":60") || text.hasPrefix("0 ") || text.hasPrefix("13 ") || text.hasPrefix("00 "), text)
                XCTAssertFalse(text.lowercased().contains("am") || text.lowercased().contains("pm"), text)
                if style == .twelveHour, let h = Int(text.split(separator: ":").first ?? text.split(separator: " ").first ?? "") {
                    XCTAssertTrue((1...12).contains(h), text)
                }
            }
        }
    }

    func testEveryTimeCheckLinePassesTheHouseStyleLint() {
        let phrases = DJTimeCheckPhrases()
        for style in DJClockStyle.allCases {
            for raw in 0..<(24 * 60) {
                guard let reading = DJTimeCheck.reading(date(raw / 60, raw % 60), calendar: eastern, style: style) else {
                    return XCTFail("\(style) \(raw / 60):\(raw % 60): a normal day has a wall-clock reading")
                }
                for template in phrases.templates(for: reading.relation) {
                    guard let line = TemplatePool.fill(template, ["time": reading.time]) else { return XCTFail(template) }
                    XCTAssertFalse(line.contains("{") || line.contains("}") || line.contains("\n"), line)
                    // One sentence: a single end mark, at the end. Times use ":" so "7:40" is fine.
                    let marks = line.filter { ".!?…".contains($0) }
                    XCTAssertEqual(marks.count, 1, line)
                    XCTAssertTrue(line.hasSuffix("."), line)
                    XCTAssertLessThanOrEqual(line.split(separator: " ").count, 7, line)
                    XCTAssertLessThanOrEqual(DefaultBriefingPlanner.estimatedSpokenSeconds(for: line), 3, line)
                    let lower = line.lowercased()
                    XCTAssertFalse(EditorialPhrasing.forbiddenHype.contains { lower.contains($0) }, line)
                    for word in ["morning", "afternoon", "evening", "tonight", "halfway", "left", " am", " pm", "a.m", "p.m"] {
                        XCTAssertFalse(lower.contains(word), "\(line): no day-part or am/pm claim")
                    }
                }
            }
        }
    }

    func testClockStyleFollowsTheLocale() {
        XCTAssertEqual(DJClockStyle(locale: Locale(identifier: "en_US")), .twelveHour)
        XCTAssertEqual(DJClockStyle(locale: Locale(identifier: "de_DE")), .twentyFourHour)
        XCTAssertEqual(DJClockStyle(locale: Locale(identifier: "fr_FR")), .twentyFourHour)
    }

    func testReadingUsesTheCalendarsTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let at = date(19, 40)                         // 23:40 UTC on Oct 31 (EDT is UTC-4)
        XCTAssertEqual(DJTimeCheck.reading(at, calendar: eastern, style: .twelveHour)?.time, "7:40" as String?)
        XCTAssertEqual(DJTimeCheck.reading(at, calendar: utc, style: .twentyFourHour)?.time, "23:40" as String?)
        XCTAssertEqual(DJTimeCheck.reading(date(7, 57, second: 59), calendar: eastern, style: .twelveHour)?.time, "7:55" as String?,
                       "seconds are ignored")
    }

    // MARK: Planning

    func testTheSpokenTimeIsTheInjectedClock() {
        for (h, m, expected) in [(7, 40, "7:40"), (19, 58, "8 o'clock"), (11, 58, "noon"), (23, 59, "midnight"), (2, 0, "2 o'clock")] {
            var writer = DJScriptWriter(cadence: dense, seed: 5, shapes: heavy())
            let checks = timeChecks(writer.plan(tracks: djTracks(30), briefing: nil, hour: h, clock: clock(h, m)))
            XCTAssertEqual(checks.count, 1, "\(h):\(m): one per plan (one clock reading)")
            XCTAssertTrue(checks.first?.1.text.contains(expected) == true, "\(h):\(m): \(checks.first?.1.text ?? "-")")
            XCTAssertEqual(checks.first?.0.timeCheckPlannedAt, date(h, m))
        }
        // A clock far from today proves nothing reads the system clock.
        let old = DJPlanClock(now: eastern.date(from: DateComponents(year: 1999, month: 1, day: 1, hour: 3, minute: 15))!,
                              calendar: eastern, style: .twentyFourHour)
        var writer = DJScriptWriter(cadence: dense, seed: 5, shapes: heavy())
        XCTAssertTrue(timeChecks(writer.plan(tracks: djTracks(30), briefing: nil, hour: 3, clock: old)).first?.1.text.contains("3:15") == true)
    }

    func testNoClockMeansNoTimeCheck() {
        for seed in UInt64(0)..<20 {
            var writer = DJScriptWriter(cadence: dense, seed: seed, shapes: heavy(spacing: 0))
            let plan = writer.plan(tracks: djTracks(40), briefing: nil, hour: 9)
            XCTAssertTrue(timeChecks(plan).isEmpty)
            XCTAssertFalse(plan.breaks.contains { $0.shape == .timeCheckIntro })
        }
    }

    func testNeverInTheFirstBreakAfterTheGreetingAndNeverTwiceInARow() {
        for seed in UInt64(0)..<50 {
            var writer = DJScriptWriter(cadence: dense, seed: seed, shapes: heavy(spacing: 0))
            let natural = writer.plan(tracks: djTracks(40), briefing: nil, hour: 9, clock: clock(9, 10)).breaks.filter { $0.isPickedShape }
            XCTAssertNotEqual(natural.first?.shape, .timeCheckIntro, "seed \(seed): first break after the greeting")
            XCTAssertEqual(natural.dropFirst().first?.shape, .timeCheckIntro, "seed \(seed): allowed from the second")
            for (a, b) in zip(natural, natural.dropFirst()) {
                XCTAssertFalse(a.shape == .timeCheckIntro && b.shape == .timeCheckIntro, "seed \(seed): twice in a row")
            }
        }
    }

    func testAtMostOncePerThirtyMinutesOfWallTime() {
        for seed in UInt64(0)..<20 {
            var writer = DJScriptWriter(cadence: dense, seed: seed, shapes: heavy())
            func checks(at h: Int, _ m: Int) -> Int {
                timeChecks(writer.plan(tracks: djTracks(20), briefing: nil, hour: h, clock: clock(h, m))).count
            }
            XCTAssertEqual(checks(at: 9, 0), 1, "seed \(seed)")
            XCTAssertEqual(checks(at: 9, 10), 0, "seed \(seed): 10 min later")
            XCTAssertEqual(checks(at: 9, 29), 0, "seed \(seed): 29 min later")
            XCTAssertEqual(checks(at: 9, 30), 1, "seed \(seed): 30 min later")
            XCTAssertEqual(checks(at: 9, 45), 0, "seed \(seed): 15 min after the last")
        }
    }

    func testForgottenBreaksDoNotCountTowardTheSpacing() {
        var writer = DJScriptWriter(cadence: dense, seed: 9, shapes: heavy())
        let first = writer.plan(tracks: djTracks(20), briefing: nil, hour: 9, clock: clock(9, 0))
        XCTAssertEqual(writer.testTimeCheckCount, 1)
        writer.forgetPlannedBreaks(first.breaks)
        XCTAssertEqual(writer.testTimeCheckCount, 0)
        XCTAssertEqual(timeChecks(writer.plan(tracks: djTracks(20), briefing: nil, hour: 9, clock: clock(9, 5))).count, 1,
                       "the replanned-away time check never aired")
    }

    func testSkippedWhenTheKnownAirTimeDriftsPastTwoMinutes() {
        for seed in UInt64(0)..<20 {
            func count(_ air: Date?) -> Int {
                var writer = DJScriptWriter(cadence: dense, seed: seed, shapes: heavy(spacing: 0))
                let airTimes = air.map { a in Dictionary(uniqueKeysWithValues: (0..<40).map { ($0, a) }) } ?? [:]
                return timeChecks(writer.plan(tracks: djTracks(40), briefing: nil, hour: 9, clock: clock(9, 40, airTimes: airTimes))).count
            }
            XCTAssertGreaterThan(count(nil), 0, "seed \(seed): unknown air time")
            XCTAssertGreaterThan(count(date(9, 42)), 0, "seed \(seed): exactly 2 min")
            XCTAssertGreaterThan(count(date(9, 38)), 0, "seed \(seed): 2 min early")
            XCTAssertEqual(count(date(9, 42, second: 1)), 0, "seed \(seed): just over 2 min")
            XCTAssertEqual(count(date(9, 37)), 0, "seed \(seed): 3 min early")
        }
    }

    func testDroppedBeforeTheClosingLineWhenTheCapIsTight() {
        for seed in UInt64(0)..<30 {
            // Roomy: time check, then the extra line, then the closing line last.
            var roomy = DJScriptWriter(cadence: dense, seed: seed, shapes: heavy(spacing: 0))
            roomy.extraLineSource = FixedExtraLine()
            let plan = roomy.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40))
            let withTime = plan.breaks.filter { $0.timeCheckCueID != nil && $0.isPickedShape }
            XCTAssertFalse(withTime.isEmpty, "seed \(seed)")
            for b in withTime {
                XCTAssertEqual(b.cues.first?.id, b.timeCheckCueID, "time check opens the break")
                XCTAssertNotEqual(b.cues.last?.id, b.timeCheckCueID, "never after the closing line")
                XCTAssertEqual(b.talkOverCueID, b.cues.last?.id)
            }
            // Tight: only the closing line fits, so the time check (and the extra) are dropped and
            // the closing line stays.
            var tight = DJScriptWriter(cadence: dense(cap: 3), seed: seed, shapes: heavy(spacing: 0))
            tight.extraLineSource = FixedExtraLine()
            let tightPlan = tight.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40))
            let picked = tightPlan.breaks.filter { $0.shape == .timeCheckIntro }
            XCTAssertFalse(picked.isEmpty, "seed \(seed)")
            for b in picked {
                XCTAssertNil(b.timeCheckCueID, "seed \(seed): dropped to fit")
                XCTAssertEqual(b.cues.count, 1)
                XCTAssertFalse(b.cues[0].text.contains(":") || b.cues[0].text.contains("o'clock"), b.cues[0].text)
            }
            // Build 34: the show opener keeps its own 22 s cap, so its time check stays.
            let openerChecks = tightPlan.breaks.filter { $0.shape == .showOpener && $0.timeCheckCueID != nil }.count
            XCTAssertEqual(tight.testTimeCheckCount, openerChecks, "a dropped time check does not count toward spacing")
        }
        // Extra line goes first: at any cap, a break whose roomy plan had a time check never keeps
        // the extra line and drops the time check; some cap keeps the time check with the extra
        // dropped. (#349's one ordinary cap counts the closing line and the pause, so no single
        // cap value is "room for exactly one optional line".)
        var keptTimeCheckOnly = 0
        for seed in UInt64(0)..<10 {
            var roomy = DJScriptWriter(cadence: dense(cap: 60), seed: seed, shapes: heavy(spacing: 0))
            roomy.extraLineSource = FixedExtraLine()
            let withTime = Set(roomy.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40)).breaks
                .filter { $0.timeCheckCueID != nil }.map(\.afterTrack))
            for cap in 3...10 {
                var writer = DJScriptWriter(cadence: dense(cap: cap), seed: seed, shapes: heavy(spacing: 0))
                writer.extraLineSource = FixedExtraLine()
                for b in writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40)).breaks
                where b.shape == .timeCheckIntro && withTime.contains(b.afterTrack) {
                    let hasExtra = b.cues.contains { $0.text.hasPrefix("Bit of rain") }
                    XCTAssertFalse(hasExtra && b.timeCheckCueID == nil, "cap \(cap) seed \(seed): extra dropped before the time check")
                    if !hasExtra, b.timeCheckCueID != nil { keptTimeCheckOnly += 1 }
                }
            }
        }
        XCTAssertGreaterThan(keptTimeCheckOnly, 0, "some cap fits the time check but not the extra")
    }

    func testRealWeightsKeepTimeChecksRare() {
        var picked = 0, total = 0
        for seed in UInt64(0)..<200 {
            var writer = DJScriptWriter(cadence: dense, seed: seed, shapes: DJBreakShapeConfig(timeCheckMinSpacingSeconds: 0))
            let natural = writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40)).breaks.filter { $0.isPickedShape }
            total += natural.count
            picked += natural.filter { $0.shape == .timeCheckIntro }.count
        }
        let share = Double(picked) / Double(total)
        XCTAssertGreaterThan(share, 0.05, "\(picked)/\(total)")
        XCTAssertLessThan(share, 0.16, "\(picked)/\(total): about 10% when every rule allows one")
    }

    func testSeededPlansWithTheSameClockAreReproducible() {
        func texts(_ seed: UInt64) -> [[String]] {
            var writer = DJScriptWriter(cadence: dense, seed: seed, shapes: heavy(spacing: 0))
            return writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40)).breaks.map { $0.cues.map(\.text) }
        }
        XCTAssertEqual(texts(41), texts(41))
        XCTAssertNotEqual(texts(41), texts(42))
        // Clock on, real weights: the shape stream is still seeded and stable.
        func shapes(_ seed: UInt64) -> [DJBreakShape?] {
            var writer = DJScriptWriter(cadence: dense, seed: seed, shapes: .natural)
            return writer.plan(tracks: djTracks(60), briefing: nil, hour: 9, clock: clock(9, 40)).breaks.map(\.shape)
        }
        XCTAssertEqual(shapes(7), shapes(7))
    }

    func testTimeCheckIsPresenterTextWithNoStationNameOrPersonalText() {
        let personal = "Dentist at three with Dr. Alvarez."
        let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: personal, estimatedSeconds: 2,
                               maxSeconds: 8, sourceItemID: UUID(), source: .calendar, provenance: "p")
        let handoff = NarrationHandoff(cues: [cue], maxSpokenSeconds: 150, experienceSeconds: 300)
        let station = "Maria's Kitchen Radio"
        let tracks = (0..<30).map { DJTrack(id: "p\($0)", title: "Private Mix \($0)", artist: "Home Video \($0)", origin: .library) }
        var found = 0
        for seed in UInt64(0)..<30 {
            var writer = DJScriptWriter(cadence: dense, seed: seed, stationName: station, shapes: heavy(spacing: 0))
            let plan = writer.plan(tracks: tracks, briefing: handoff, hour: 9, clock: clock(9, 40))
            for (b, timeCue) in timeChecks(plan) {
                found += 1
                XCTAssertEqual(b.attributions[timeCue.id], .presenter)
                XCTAssertFalse(timeCue.isContent)
                XCTAssertFalse(b.hasBriefing, "time checks are ordinary breaks only")
                let lower = timeCue.text.lowercased()
                for banned in [station, "maria", "kitchen", personal, "dentist", "alvarez", "private mix", "home video"] {
                    XCTAssertFalse(lower.contains(banned.lowercased()), "\(timeCue.text) contains \(banned)")
                }
                XCTAssertTrue(DJTimeCheckPhrases().templates(for: .on).contains { TemplatePool.fill($0, ["time": "9:40"]) == timeCue.text },
                              "only template text plus the time: \(timeCue.text)")
            }
        }
        XCTAssertGreaterThan(found, 0)
    }

    func testPlannedTimeCheckKeepsItsPhrasingSlotAndReadsAnyClock() {
        var writer = DJScriptWriter(cadence: dense, seed: 3, shapes: heavy(spacing: 0))
        let plan = writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40))
        guard let b = plan.breaks.first(where: { $0.timeCheck != nil }), let tc = b.timeCheck,
              let cue = b.cues.first(where: { $0.id == tc.cueID }) else { return XCTFail("no time check") }
        let phrases = DJTimeCheckPhrases()
        guard let slot = phrases.on.firstIndex(where: { TemplatePool.fill($0, ["time": "9:40"]) == cue.text }) else {
            return XCTFail("plan-time text from the on pool: \(cue.text)")
        }
        XCTAssertEqual(tc.templates, [.on: phrases.on[slot], .comingUp: phrases.comingUp[slot], .justAfter: phrases.justAfter[slot]])
        XCTAssertEqual(tc.plannedAt, date(9, 40))
        XCTAssertEqual(tc.style, .twelveHour)
        XCTAssertEqual(tc.calendar.timeZone, eastern.timeZone)
        // Any later clock: same slot, the relation and time that clock reads.
        XCTAssertEqual(tc.text(at: date(9, 52)), TemplatePool.fill(phrases.justAfter[slot], ["time": "9:50"]))
        XCTAssertEqual(tc.text(at: date(9, 58)), TemplatePool.fill(phrases.comingUp[slot], ["time": "10 o'clock"]))
        XCTAssertEqual(tc.text(at: date(11, 0)), TemplatePool.fill(phrases.on[slot], ["time": "11 o'clock"]))
    }

    func testTimeCheckNeverPlannedWithoutAClosingLine() {
        // A time check is never a break's only line: the closing line always follows it.
        var writer = DJScriptWriter(cadence: dense, seed: 5, shapes: heavy(spacing: 0))
        let plan = writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40))
        for b in plan.breaks where b.timeCheck != nil {
            XCTAssertGreaterThan(b.cues.count, 1)
            XCTAssertNotEqual(b.cues.last?.id, b.timeCheckCueID, "the closing line comes after it")
        }
    }
}
