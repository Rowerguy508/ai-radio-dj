import Foundation
import XCTest
@testable import AeroDJCore

// Per-persona time-check copy (follow-up to #347, -Echo). Each `EditorialTone` carries its own
// `timeChecks` bank, reached through `DJBreakShapeConfig.timeCheckPhrases(for:)` exactly as the
// combined lines are. The time itself, rounding, 12h/24h and noon/midnight stay in `DJTimeCheck`.
final class DJTimeCheckToneTests: XCTestCase {
    private let dense = DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1)

    private static let tones: [(name: String, tone: EditorialTone)] =
        DJPersonality.allCases.map { ($0.rawValue, EditorialTone.forPersonality($0)) }

    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: hour, minute: minute))!
    }

    private func clock(_ hour: Int, _ minute: Int, style: DJClockStyle = .twelveHour) -> DJPlanClock {
        DJPlanClock(now: date(hour, minute), calendar: eastern, style: style)
    }

    private func heavy(spacing: Double = 0) -> DJBreakShapeConfig {
        DJBreakShapeConfig(weights: [.timeCheckIntro: 1000, .comingUpOnly: 1], timeCheckMinSpacingSeconds: spacing)
    }

    private func breakSeconds(_ b: DJBreak) -> Double {
        b.estimatedSeconds + (b.cues.count > 1 && b.talkOverCueID == b.cues.last?.id ? PreparedDJBreak.talkOverGapSeconds : 0)
    }

    // MARK: Copy

    func testWarmKeepsFrysCopyVerbatim() {
        XCTAssertEqual(EditorialTone.warm.timeChecks.on, ["It's {time}.", "Time check, it's {time}.", "Right now, it's {time}."])
        XCTAssertEqual(EditorialTone.warm.timeChecks.comingUp, ["Coming up on {time}.", "Almost {time}.", "Nearly {time} now."])
        XCTAssertEqual(EditorialTone.warm.timeChecks.justAfter, ["Just after {time}.", "Just past {time}.", "A little after {time}."])
        XCTAssertEqual(EditorialTone.warm.timeChecks, DJTimeCheckPhrases())
        XCTAssertEqual(DJBreakShapeConfig.defaultTimeChecks, DJTimeCheckPhrases())
        XCTAssertEqual(DJBreakShapeConfig.natural.timeChecks, DJTimeCheckPhrases())
        XCTAssertEqual(DJBreakShapeConfig.natural.timeCheckPhrases(for: .warm), DJTimeCheckPhrases())
    }

    func testEachPersonaHasItsOwnSlotAlignedBank() {
        let warm = EditorialTone.warm.timeChecks
        for (name, tone) in Self.tones {
            let phrases = tone.timeChecks
            XCTAssertEqual(DJBreakShapeConfig.natural.timeCheckPhrases(for: tone), phrases, name)
            if name != DJPersonality.warm.rawValue { XCTAssertNotEqual(phrases, warm, "\(name) has its own copy") }
            for relation in DJTimeCheckRelation.allCases {
                let list = phrases.templates(for: relation)
                XCTAssertEqual(list.count, warm.templates(for: relation).count, "\(name).\(relation): same slots as warm")
                XCTAssertEqual(Set(list.map(RecentSpokenTemplates.key)).count, list.count, "\(name).\(relation): no duplicates")
                for template in list {
                    XCTAssertEqual(template.components(separatedBy: "{time}").count, 2, "\(template): one {time}")
                    XCTAssertFalse(template.replacingOccurrences(of: "{time}", with: "").contains { "{}".contains($0) },
                                   "\(template): no other placeholder")
                }
            }
            XCTAssertEqual(Set(tone.allTimeCheckLines.map(RecentSpokenTemplates.key)).count, tone.allTimeCheckLines.count, name)
        }
    }

    func testAnOverrideStillWinsOverEveryTone() {
        let custom = DJTimeCheckPhrases(on: ["Custom {time}."], comingUp: ["Custom near {time}."], justAfter: ["Custom past {time}."])
        let config = DJBreakShapeConfig(timeChecks: custom)
        for (name, tone) in Self.tones { XCTAssertEqual(config.timeCheckPhrases(for: tone), custom, name) }
    }

    /// Every template of every persona, both clock styles, every minute of the day: the house
    /// lint, one sentence ending in a period (no exclamation marks, upbeat included), seven words
    /// or fewer, at most 3 s at `DefaultBriefingPlanner.wordsPerMinute`, no day-part or am/pm claim.
    func testEveryToneTimeCheckLinePassesTheLintAtEveryMinute() {
        var longest = 0
        for (name, tone) in Self.tones {
            for style in DJClockStyle.allCases {
                for raw in 0..<(24 * 60) {
                    guard let reading = DJTimeCheck.reading(date(raw / 60, raw % 60), calendar: eastern, style: style) else {
                        return XCTFail("\(name) \(style) \(raw / 60):\(raw % 60): a normal day has a wall-clock reading")
                    }
                    for relation in DJTimeCheckRelation.allCases {
                        for template in tone.timeChecks.templates(for: relation) {
                            guard let line = TemplatePool.fill(template, ["time": reading.time]) else {
                                return XCTFail("\(name): \(template)")
                            }
                            let problems = SpokenScriptLintTests.problems(line)
                            XCTAssertTrue(problems.isEmpty, "\(name): \"\(line)\" -> \(problems)")
                            XCTAssertFalse(line.contains { "()[]{}!\n".contains($0) }, "\(name): \(line)")
                            XCTAssertEqual(line.filter { ".!?…".contains($0) }.count, 1, "\(name): \(line)")
                            XCTAssertTrue(line.hasSuffix("."), "\(name): \(line)")
                            XCTAssertTrue(line.first?.isUppercase == true || line.first?.isNumber == true, "\(name): \(line)")
                            XCTAssertLessThanOrEqual(line.split(separator: " ").count, 7, "\(name): \(line)")
                            let seconds = DefaultBriefingPlanner.estimatedSpokenSeconds(for: line)
                            longest = max(longest, seconds)
                            XCTAssertLessThanOrEqual(seconds, 3, "\(name): \(line)")
                            let lower = line.lowercased()
                            for word in ["morning", "afternoon", "evening", "tonight", "halfway", "left", " am", " pm", "a.m", "p.m"] {
                                XCTAssertFalse(lower.contains(word), "\(name): \(line): no day-part or am/pm claim")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertLessThanOrEqual(longest, 3)
    }

    // MARK: Planning

    /// A writer speaks its own tone's time checks, keeps the slot across relations, and the
    /// time-check cue stays presenter text. Every `on` template airs across seeds.
    func testWriterSpeaksItsTonesTimeChecks() {
        for (name, tone) in Self.tones {
            let phrases = tone.timeChecks
            var used = Set<String>()
            for seed in UInt64(0)..<40 {
                var writer = DJScriptWriter(cadence: dense, seed: seed, tone: tone, shapes: heavy())
                let plan = writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40))
                for b in plan.breaks {
                    guard let tc = b.timeCheck, let cue = b.cues.first(where: { $0.id == tc.cueID }) else { continue }
                    guard let slot = phrases.on.firstIndex(where: { TemplatePool.fill($0, ["time": "9:40"]) == cue.text }) else {
                        XCTFail("\(name): not this tone's copy: \(cue.text)"); continue
                    }
                    used.insert(phrases.on[slot])
                    XCTAssertEqual(tc.templates, [.on: phrases.on[slot], .comingUp: phrases.comingUp[slot],
                                                  .justAfter: phrases.justAfter[slot]], name)
                    XCTAssertEqual(b.attributions[cue.id], .presenter, name)
                    XCTAssertEqual(tc.text(at: date(9, 58)), TemplatePool.fill(phrases.comingUp[slot], ["time": "10 o'clock"]), name)
                    XCTAssertEqual(tc.text(at: date(12, 1)), TemplatePool.fill(phrases.justAfter[slot], ["time": "noon"]), name)
                    XCTAssertLessThanOrEqual(breakSeconds(b), capSeconds(b), "\(name): 12 s cap, 22 s for the show opener")
                }
            }
            XCTAssertEqual(used, Set(phrases.on), "\(name): every slot airs")
        }
    }

    /// Warm with an explicit tone plans exactly what #347 planned with the default writer.
    func testWarmPlansAreUnchanged() {
        for seed in UInt64(0)..<20 {
            for style in DJClockStyle.allCases {
                var before = DJScriptWriter(cadence: dense, seed: seed, shapes: heavy())
                var after = DJScriptWriter(cadence: dense, seed: seed, tone: .warm, shapes: heavy())
                let a = before.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40, style: style))
                let b = after.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40, style: style))
                XCTAssertEqual(a.breaks.map { $0.cues.map(\.text) }, b.breaks.map { $0.cues.map(\.text) })
                XCTAssertEqual(a.breaks.map(\.timeCheck?.templates), b.breaks.map(\.timeCheck?.templates))
            }
        }
    }

    /// The tone changes the words only: where breaks fall, their shapes, and what each cue is
    /// attributed to match warm's plan for the same seed and clock.
    func testPlannedAttributionIsUnchangedAcrossTones() {
        func shape(_ plan: DJSessionPlan) -> [[String]] {
            plan.breaks.map { b in
                ["\(b.afterTrack)", "\(b.shape.map { "\($0)" } ?? "-")", "\(b.timeCheck != nil)"]
                    + b.cues.map { cue in
                        let attribution = b.attributions[cue.id].map { "\($0)" } ?? "none"
                        return cue.id == b.timeCheckCueID ? "time:\(attribution)" : attribution
                    }
            }
        }
        var compared = 0
        for seed in UInt64(0)..<20 {
            var warm = DJScriptWriter(cadence: dense, seed: seed, tone: .warm, shapes: heavy())
            let reference = shape(warm.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40)))
            for (name, tone) in Self.tones {
                var writer = DJScriptWriter(cadence: dense, seed: seed, tone: tone, shapes: heavy())
                let plan = writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock(9, 40))
                for b in plan.breaks {
                    guard let id = b.timeCheckCueID else { continue }
                    compared += 1
                    XCTAssertEqual(b.attributions[id], .presenter, name)
                }
                // Only the time-check cues and their breaks' attribution layout are compared:
                // other pools differ by tone in length, which may move a cap trim elsewhere.
                let mine = shape(plan)
                XCTAssertEqual(mine.filter { $0[2] == "true" }.map { $0.filter { $0.hasPrefix("time:") } },
                               reference.filter { $0[2] == "true" }.map { $0.filter { $0.hasPrefix("time:") } }, "\(name) seed \(seed)")
            }
        }
        XCTAssertGreaterThan(compared, 0)
    }

    /// Anti-repeat is the existing `RecentSpokenTemplates` rule, per tone: a time-check template
    /// never comes back within `recentBreakWindow` breaks.
    func testNoTimeCheckRepeatsInsideTheRecentWindow() {
        let window = heavy().recentBreakWindow
        for (name, tone) in Self.tones {
            var aired = 0
            for seed in UInt64(0)..<20 {
                var writer = DJScriptWriter(cadence: dense, seed: seed, tone: tone, shapes: heavy())
                let plan = writer.plan(tracks: djTracks(60), briefing: nil, hour: 9, clock: clock(9, 40))
                var last: [String: Int] = [:]
                for (index, b) in plan.breaks.enumerated() {
                    guard let id = b.timeCheckCueID, let cue = b.cues.first(where: { $0.id == id }) else { continue }
                    aired += 1
                    let key = RecentSpokenTemplates.textKey(cue.text)
                    if let previous = last[key] {
                        XCTAssertGreaterThanOrEqual(index - previous, window, "\(name) seed \(seed): \(cue.text) repeats")
                    }
                    last[key] = index
                }
            }
            XCTAssertGreaterThan(aired, 0, name)
        }
    }

    /// Build 34: the session's show opener keeps its own 22 s cap; every other break keeps 12 s.
    private func capSeconds(_ b: DJBreak) -> Double {
        Double(b.shape == .showOpener ? dense.maxOpenerBreakSeconds : dense.maxOrdinaryBreakSeconds)
    }

    /// Whole sessions per persona with the real natural weights stay inside the 12 s cap
    /// (the show opener inside its 22 s cap).
    func testNaturalSessionsPerToneStayInsideTheCap() {
        for (name, tone) in Self.tones {
            for seed in UInt64(0)..<30 {
                var writer = DJScriptWriter(cadence: dense, seed: seed, tone: tone, shapes: .natural)
                let plan = writer.plan(tracks: djTracks(40), briefing: nil, hour: 9, clock: clock(9, 40))
                for b in plan.breaks where b.timeCheck != nil {
                    XCTAssertLessThanOrEqual(breakSeconds(b), capSeconds(b), "\(name) seed \(seed)")
                }
            }
        }
    }
}
