import Foundation
import XCTest
@testable import AeroDJCore

// Natural break shapes (lane 2, -Fry). Everything runs in-process: no voice, no network.

private struct FixedExtra: DJBreakExtraLineSource {
    let line: DJExtraLine?
    func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine? { line }
}

/// A different extra line at every boundary (as weather would read), so anti-repeat never drops it.
private struct VaryingExtra: DJBreakExtraLineSource {
    func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine? {
        DJExtraLine(text: "Bit of rain by \(previous.id).", attribution: .presenter)
    }
}

final class DJBreakShapesTests: XCTestCase {
    /// Dense cadence so 30 tracks give plenty of breaks.
    private let dense = DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1)

    /// Every track shares the same title and artist, so filled text identifies the template.
    private func sameMetaTracks(_ n: Int, origin: TrackOrigin = .catalog) -> [DJTrack] {
        (0..<n).map { DJTrack(id: "t\($0)", title: "Song", artist: "Band", origin: origin) }
    }

    /// Ordinary natural breaks of one session (the greeting break is excluded).
    private func naturalBreaks(seed: UInt64, tracks: [DJTrack], config: DJBreakShapeConfig = .natural,
                               tone: EditorialTone = .warm, cadence: DJCadence? = nil,
                               extra: (any DJBreakExtraLineSource)? = nil) -> [DJBreak] {
        var writer = DJScriptWriter(cadence: cadence ?? dense, seed: seed, tone: tone, shapes: config)
        writer.extraLineSource = extra
        return writer.plan(tracks: tracks, briefing: nil, hour: 10).breaks.filter { $0.shape != nil }
    }

    private func bigTone() -> EditorialTone {
        func many(_ stem: String, _ placeholder: String) -> [String] {
            ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet",
             "Kilo", "Lima", "Mike", "November", "Oscar", "Papa"].map { "\($0) \(stem) \(placeholder)." }
        }
        var tone = EditorialTone.warm
        tone.backAnnounce = many("back", "{title}")
        tone.closing = many("next", "{nextTitle}")
        tone.artistFocus = many("artist", "{artist}")
        tone.stationID = many("station", "{station}")
        tone.continuation = many("more", "now")
        tone.atmosphere = Dictionary(uniqueKeysWithValues: DayPart.allCases.map { ($0, many("air", "today")) })
        return tone
    }

    /// Repeat counts over whole sessions (greeting break included): identical lines, and shared
    /// phrases of `RecentSpokenTemplates.minPhraseWords`+ words, inside `window` breaks.
    private func repeatStats(tone: EditorialTone, hour: Int, seeds: Range<UInt64> = 0..<200)
        -> (lines: Int, identical: Int, phrase: Int, openerPairs: Int, sameFirstWord: Int, windows: Int, here: Int) {
        let window = DJBreakShapeConfig.natural.recentBreakWindow
        var r = (lines: 0, identical: 0, phrase: 0, openerPairs: 0, sameFirstWord: 0, windows: 0, here: 0)
        for seed in seeds {
            var writer = DJScriptWriter(cadence: dense, seed: seed, tone: tone, shapes: .natural)
            let all = writer.plan(tracks: djTracks(30, origin: .catalog), briefing: nil, hour: hour).breaks
            let texts = all.map { $0.cues.map(\.text) }
            for (i, current) in texts.enumerated() {
                let earlier = texts[max(0, i - window)..<i].flatMap { $0 }
                let earlierPhrases = earlier.reduce(into: Set<String>()) { $0.formUnion(RecentSpokenTemplates.phrases($1)) }
                for line in current {
                    r.lines += 1
                    if earlier.contains(line) { r.identical += 1 }
                    if !RecentSpokenTemplates.phrases(line).isDisjoint(with: earlierPhrases) { r.phrase += 1 }
                }
                XCTAssertEqual(Set(current).count, current.count, "seed \(seed): same line twice in one break")
            }
            let natural = all.filter { $0.shape != nil }.map { $0.cues.map(\.text) }
            for i in natural.indices.dropFirst() {
                r.openerPairs += 1
                if RecentSpokenTemplates.firstWord(natural[i][0]) == RecentSpokenTemplates.firstWord(natural[i - 1][0]) { r.sameFirstWord += 1 }
            }
            for i in natural.indices where i >= 2 {
                r.windows += 1
                if natural[(i - 2)...i].flatMap({ $0 }).filter(RecentSpokenTemplates.startsWithHere).count > 1 { r.here += 1 }
            }
        }
        return r
    }

    func testDefaultIsOffAndClassicPlansCarryNoShape() {
        var classic = DJScriptWriter(cadence: dense, seed: 4)
        XCTAssertNil(classic.shapes)
        XCTAssertTrue(classic.plan(tracks: djTracks(30), briefing: nil, hour: 9).breaks.allSatisfy { $0.shape == nil })
    }

    func testShapesNeverMoveWhereBreaksFall() {
        for seed in UInt64(0)..<100 {
            var classic = DJScriptWriter(seed: seed)
            var natural = DJScriptWriter(seed: seed, shapes: .natural)
            XCTAssertEqual(classic.plan(tracks: djTracks(30), briefing: nil, hour: 9).breaks.map(\.afterTrack),
                           natural.plan(tracks: djTracks(30), briefing: nil, hour: 9).breaks.map(\.afterTrack), "seed \(seed)")
        }
    }

    func testEveryShapeAiresAndCombinedIsAboutAThird() {
        var counts: [DJBreakShape: Int] = [:]
        for seed in UInt64(0)..<200 {
            for b in naturalBreaks(seed: seed, tracks: djTracks(30, origin: .catalog)) { counts[b.shape!, default: 0] += 1 }
        }
        let total = counts.values.reduce(0, +)
        for shape in DJBreakShape.allCases where shape != .timeCheckIntro {
            XCTAssertGreaterThan(counts[shape] ?? 0, total / 50, "\(shape) should air: \(counts)")
        }
        XCTAssertNil(counts[.timeCheckIntro], "no clock source in this slice")
        let combinedShare = Double(counts[.combined] ?? 0) / Double(total)
        XCTAssertTrue((0.22...0.40).contains(combinedShare), "combined share \(combinedShare)")
    }

    func testNoShapeTwiceInARowAndStationIDSpacing() {
        for seed in UInt64(0)..<200 {
            let shapes = naturalBreaks(seed: seed, tracks: djTracks(30, origin: .catalog)).map { $0.shape! }
            for (a, b) in zip(shapes, shapes.dropFirst()) { XCTAssertNotEqual(a, b, "seed \(seed): \(shapes)") }
            XCTAssertFalse(shapes.prefix(2).contains(.stationID), "seed \(seed): no station ID right after the greeting")
        }
    }

    func testNoTemplateRepeatsWithinTheWindowWhenPoolsAllowIt() {
        let config = DJBreakShapeConfig.natural
        for seed in UInt64(0)..<200 {
            let breaks = naturalBreaks(seed: seed, tracks: sameMetaTracks(30), tone: bigTone())
            let texts = breaks.map { $0.cues.map(\.text) }
            for (i, lines) in texts.enumerated() {
                XCTAssertEqual(Set(lines).count, lines.count, "seed \(seed): repeat inside one break")
                let window = texts[max(0, i - config.recentBreakWindow)..<i].flatMap { $0 }
                for line in lines { XCTAssertFalse(window.contains(line), "seed \(seed) break \(i): \(line)") }
                if i > 0 {
                    XCTAssertNotEqual(RecentSpokenTemplates.firstWord(lines[0]), RecentSpokenTemplates.firstWord(texts[i - 1][0]),
                                      "seed \(seed) break \(i): opener first word repeats")
                }
            }
        }
    }

    func testWarmPoolsSoundVariedAcrossBreaks() {
        var openerPairs = 0, sameFirstWord = 0, hereViolations = 0, windows = 0
        for seed in UInt64(0)..<200 {
            let texts = naturalBreaks(seed: seed, tracks: sameMetaTracks(30)).map { $0.cues.map(\.text) }
            for i in texts.indices.dropFirst() {
                XCTAssertTrue(Set(texts[i]).isDisjoint(with: texts[i - 1]), "seed \(seed): same line in consecutive breaks")
                openerPairs += 1
                if RecentSpokenTemplates.firstWord(texts[i][0]) == RecentSpokenTemplates.firstWord(texts[i - 1][0]) { sameFirstWord += 1 }
            }
            for i in texts.indices where i >= 2 {
                windows += 1
                if texts[(i - 2)...i].flatMap({ $0 }).filter(RecentSpokenTemplates.startsWithHere).count > 1 { hereViolations += 1 }
            }
        }
        XCTAssertLessThanOrEqual(Double(sameFirstWord) / Double(openerPairs), 0.25, "opener first-word repeats \(sameFirstWord)/\(openerPairs)")
        // Bound set for the pre-#339 five-line closing pool (406/2400 = 16.9%), where the hard
        // identical-in-6 rule beat the soft "Here's" rule. Since #339 `.warm` is lane 1's ten-line
        // pool and measures 0/2400 here (forward merge, Linux). Left at 20% on purpose; tightening
        // it is a separate call (see `testLane1PoolsMeetTheSoftRules`, which holds 10%).
        XCTAssertLessThanOrEqual(Double(hereViolations) / Double(windows), 0.20, "\"Here's\" more than once in 3 breaks: \(hereViolations)/\(windows)")
    }

    func testEveryNaturalBreakFitsTheCaps() {
        let config = DJBreakShapeConfig.natural
        var withExtra = 0
        for seed in UInt64(0)..<200 {
            for b in naturalBreaks(seed: seed, tracks: djTracks(30, origin: .catalog), extra: VaryingExtra()) {
                // #320: the 0.3 s pause before a closing line that follows other talk counts too.
                let gap = b.cues.count > 1 && b.talkOverCueID == b.cues.last?.id ? PreparedDJBreak.talkOverGapSeconds : 0
                XCTAssertLessThanOrEqual(b.estimatedSeconds + gap, Double(config.maxBreakSeconds))
                if b.cues.contains(where: { $0.text.hasPrefix("Bit of rain") }) { withExtra += 1 }
                XCTAssertLessThanOrEqual(b.mainSeconds, Double(DJCadence().maxTransitionSeconds))
                XCTAssertLessThanOrEqual(b.cues.count, config.maxCuesPerBreak)
                XCTAssertFalse(b.hasBriefing)
                if let talkOver = b.talkOverCueID { XCTAssertEqual(talkOver, b.cues.last?.id) }
                XCTAssertEqual(Set(b.attributions.keys), Set(b.cues.map(\.id)), "every cue is attributed")
            }
        }
        XCTAssertGreaterThan(withExtra, 0, "the extra line fits some breaks")
    }

    func testCapCountsThePauseBeforeTheClosingLine() {
        // Opener 6 s + closing 6 s = 12 s of words: fits without the pause, over with it.
        let six = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
        XCTAssertEqual(DefaultBriefingPlanner.estimatedSpokenSeconds(for: six), 6)
        var tone = EditorialTone.warm
        tone.backAnnounce = ["{title} " + six]
        tone.artistFocus = ["{artist} " + six]
        tone.closing = ["{nextTitle} " + six]
        let tracks = (0..<30).map { DJTrack(id: "t\($0)", title: "x", artist: "y", origin: .catalog) }
        XCTAssertEqual(DefaultBriefingPlanner.estimatedSpokenSeconds(for: "x " + six), 6)
        let classicOnly = DJBreakShapeConfig(weights: [.classic: 1], maxBreakSeconds: 12)
        var writer = DJScriptWriter(cadence: DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1, maxTransitionSeconds: 20,
                                                       maxClosingSeconds: 8),
                                    seed: 4, tone: tone, shapes: classicOnly)
        let natural = writer.plan(tracks: tracks, briefing: nil, hour: 10).breaks.filter { $0.shape != nil }
        XCTAssertTrue(natural.isEmpty, "6 s + 0.3 s pause + 6 s is over 12 s: music only, got \(natural.map { $0.cues.map(\.text) })")
        let roomier = DJBreakShapeConfig(weights: [.classic: 1], maxBreakSeconds: 13)
        var writer2 = DJScriptWriter(cadence: DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1, maxTransitionSeconds: 20,
                                                        maxClosingSeconds: 8),
                                     seed: 4, tone: tone, shapes: roomier)
        XCTAssertFalse(writer2.plan(tracks: tracks, briefing: nil, hour: 10).breaks.filter { $0.shape != nil }.isEmpty)
    }

    /// Echo's #339 note: "Glad you're here" sits in three pools. A line shared by pools must not
    /// air twice inside the window, whichever pool it comes from.
    func testALineSharedByPoolsNeverRepeatsInsideTheWindow() {
        let shared = "Glad you're here."
        var tone = EditorialTone.warm
        tone.continuation = [shared, "More on the way.", "Stay right there."]
        tone.atmosphere = Dictionary(uniqueKeysWithValues: DayPart.allCases.map { ($0, [shared, "Easy stretch."]) })
        let config = DJBreakShapeConfig(weights: [.classic: 10, .comingUpOnly: 1, .backAnnounceOnly: 1])
        var aired = 0
        for seed in UInt64(0)..<200 {
            let texts = naturalBreaks(seed: seed, tracks: djTracks(30, origin: .catalog), config: config, tone: tone,
                                      extra: FixedExtra(line: DJExtraLine(text: shared, attribution: .presenter)))
                .map { $0.cues.map(\.text) }
            let hits = texts.indices.filter { texts[$0].contains(shared) }
            aired += hits.count
            for (a, b) in zip(hits, hits.dropFirst()) {
                XCTAssertGreaterThan(b - a, config.recentBreakWindow, "seed \(seed): shared line again after \(b - a) breaks")
            }
            for lines in texts { XCTAssertLessThanOrEqual(lines.filter { $0 == shared }.count, 1, "seed \(seed): twice in one break") }
        }
        XCTAssertGreaterThan(aired, 200, "the shared line still airs")
    }

    /// Across every pool, the whole session (greeting break included), every day part: no identical
    /// line and no shared 3+ word phrase inside the window, with the shipped pools (lane 1's, #339).
    func testNoIdenticalLineOrSharedPhraseInsideTheWindowAcrossAllPools() {
        for (name, tone) in [("warm", EditorialTone.warm)] {
            for hour in [6, 15, 23] {
                let r = repeatStats(tone: tone, hour: hour, seeds: 0..<100)
                print("repeat-stats \(name) hour \(hour): \(r)")
                XCTAssertGreaterThan(r.lines, 1500)
                XCTAssertEqual(r.identical, 0, "\(name) \(hour)h: identical line inside the window \(r)")
                XCTAssertEqual(r.phrase, 0, "\(name) \(hour)h: shared phrase inside the window \(r)")
            }
        }
    }

    /// The soft rules on lane 1's pools (`.warm` since #339): opener first word repeats at most 1 in 4 (the plan's bar),
    /// and "Here's" more than once in 3 breaks in at most 1 window in 10.
    func testLane1PoolsMeetTheSoftRules() {
        let r = repeatStats(tone: .warm, hour: 10)
        print("soft-rules lane1: \(r)")
        XCTAssertLessThanOrEqual(Double(r.sameFirstWord) / Double(r.openerPairs), 0.25, "\(r)")
        XCTAssertLessThanOrEqual(Double(r.here) / Double(r.windows), 0.10, "\(r)")
    }

    func testOverCapBreakDropsOptionalLinesThenGoesMusicOnly() {
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        let extra = FixedExtra(line: DJExtraLine(text: long, attribution: .presenter))
        let planned = naturalBreaks(seed: 3, tracks: djTracks(30, origin: .catalog), extra: extra)
        XCTAssertFalse(planned.isEmpty)
        XCTAssertFalse(planned.flatMap(\.cues).contains { $0.text == long }, "the over-cap extra is dropped first")

        var tone = EditorialTone.warm
        tone.closing = ["{nextTitle} " + long]
        tone.backAnnounce = ["{title} " + long]
        let config = DJBreakShapeConfig(weights: [.comingUpOnly: 1, .backAnnounceOnly: 1])
        var writer = DJScriptWriter(cadence: dense, seed: 1, tone: tone, shapes: config)
        let breaks = writer.plan(tracks: djTracks(30), briefing: nil, hour: 10).breaks
        XCTAssertLessThanOrEqual(breaks.count, 1, "at most the classic greeting break")
        XCTAssertTrue(breaks.allSatisfy { $0.shape == nil }, "every over-cap natural break stays music-only")
    }

    func testCombinedLineNamesBothTracksAtTheMostRestrictiveOrigin() {
        let config = DJBreakShapeConfig(weights: [.combined: 1])
        let tracks = (0..<30).map { DJTrack(id: "t\($0)", title: "Song \($0)", artist: "Artist \($0)", origin: $0 % 2 == 0 ? .catalog : .library) }
        let breaks = naturalBreaks(seed: 8, tracks: tracks, config: config)
        XCTAssertFalse(breaks.isEmpty)
        for b in breaks {
            XCTAssertEqual(b.shape, .combined)
            XCTAssertEqual(b.cues.count, 1)
            let ids = ["t\(b.afterTrack)", "t\(b.afterTrack + 1)"]
            XCTAssertEqual(b.attributions[b.cues[0].id], .trackMetadata(trackIDs: ids, origin: .library))
            XCTAssertEqual(b.talkOverCueID, b.cues[0].id, "a short combined line lands over the intro")
        }
        let allCatalog = naturalBreaks(seed: 8, tracks: djTracks(30, origin: .catalog), config: config)
        XCTAssertTrue(allCatalog.allSatisfy { b in
            if case .trackMetadata(_, let origin) = b.attributions[b.cues[0].id]! { return origin == .catalog } else { return false }
        })
    }

    func testMissingMetadataNarrowsTheShapes() {
        let picker = DJBreakShapePicker(seed: 1)
        XCTAssertEqual(Set(picker.eligible(.init(canBackAnnounce: false, canForwardSell: true, stationIDUsable: false))),
                       [.classic, .comingUpOnly])
        XCTAssertEqual(Set(picker.eligible(.init(canBackAnnounce: true, canForwardSell: false))), [.classic, .backAnnounceOnly])
        XCTAssertEqual(picker.eligible(.init(canBackAnnounce: false, canForwardSell: false)), [])
        XCTAssertTrue(picker.eligible(.init(timeCheckAvailable: true)).contains(.timeCheckIntro))

        let blank = (0..<30).map { DJTrack(id: "t\($0)", title: $0 % 2 == 0 ? "" : "Song", artist: $0 % 2 == 0 ? "" : "Band", origin: .catalog) }
        for b in naturalBreaks(seed: 5, tracks: blank) {
            for cue in b.cues { XCTAssertFalse(cue.text.contains("{") || cue.text.contains("}"), cue.text) }
            if blank[b.afterTrack].title.isEmpty { XCTAssertFalse([.backAnnounceOnly, .combined].contains(b.shape!)) }
            if blank[b.afterTrack + 1].title.isEmpty { XCTAssertFalse([.comingUpOnly, .combined, .stationID].contains(b.shape!)) }
        }
    }

    func testStationIDPicksAreSpacedAndSkippedForUnusableNames() {
        var picker = DJBreakShapePicker(config: .init(weights: [.stationID: 100, .classic: 1]), seed: 2)
        var shapes: [DJBreakShape] = []
        for _ in 0..<20 { let s = picker.pick(.init())!; picker.record(s); shapes.append(s) }
        XCTAssertEqual(Array(shapes.prefix(2)), [.classic, .classic])
        for (a, b) in zip(shapes, shapes.dropFirst()) { XCTAssertFalse(a == .stationID && b == .stationID) }
        XCTAssertTrue(shapes.contains(.stationID))

        var writer = DJScriptWriter(cadence: dense, seed: 2, stationName: "{bad}", shapes: .natural)
        XCTAssertFalse(writer.plan(tracks: djTracks(30), briefing: nil, hour: 10).breaks.contains { $0.shape == .stationID })
    }

    func testCreatedStationNameStaysOnDevice() {
        var writer = DJScriptWriter(cadence: dense, seed: 6, stationName: "Rainy Day Mix",
                                    shapes: .init(weights: [.stationID: 10, .comingUpOnly: 1]))
        let ids = writer.plan(tracks: djTracks(30, origin: .catalog), briefing: nil, hour: 10).breaks.filter { $0.shape == .stationID }
        XCTAssertFalse(ids.isEmpty)
        for b in ids { XCTAssertEqual(b.attributions[b.cues[0].id], .stationName) }
    }

    func testExtraLineSeamSitsBeforeTheClosingLine() {
        let breaks = naturalBreaks(seed: 9, tracks: djTracks(30, origin: .catalog), config: .init(weights: [.comingUpOnly: 1]),
                                   extra: VaryingExtra())
        XCTAssertFalse(breaks.isEmpty)
        for b in breaks {
            XCTAssertEqual(b.cues.map(\.text).first, "Bit of rain by t\(b.afterTrack).")
            XCTAssertEqual(b.cues.count, 2)
            XCTAssertEqual(b.attributions[b.cues[0].id], .presenter)
            XCTAssertEqual(b.talkOverCueID, b.cues[1].id)
        }
        let bad = naturalBreaks(seed: 9, tracks: djTracks(30, origin: .catalog), config: .init(weights: [.comingUpOnly: 1]),
                                extra: FixedExtra(line: DJExtraLine(text: "Rain {later}", attribution: .presenter)))
        XCTAssertTrue(bad.allSatisfy { $0.cues.count == 1 }, "an extra with braces is never spoken")
        let none = naturalBreaks(seed: 9, tracks: djTracks(30, origin: .catalog), config: .init(weights: [.comingUpOnly: 1]))
        XCTAssertTrue(none.allSatisfy { $0.cues.count == 1 })
    }

    func testTheSameExtraLineIsNotRepeatedInsideTheWindow() {
        let config = DJBreakShapeConfig.natural
        let line = DJExtraLine(text: "Bit of rain later.", attribution: .presenter)
        for seed in UInt64(0)..<50 {
            let texts = naturalBreaks(seed: seed, tracks: djTracks(30, origin: .catalog), extra: FixedExtra(line: line))
                .map { $0.cues.map(\.text) }
            let aired = texts.indices.filter { texts[$0].contains(line.text) }
            XCTAssertFalse(aired.isEmpty, "seed \(seed): the extra airs")
            for (a, b) in zip(aired, aired.dropFirst()) {
                XCTAssertGreaterThan(b - a, config.recentBreakWindow, "seed \(seed): extra again after \(b - a) breaks")
            }
        }
    }

    func testSeededSessionsAreReproducible() {
        let a = naturalBreaks(seed: 77, tracks: djTracks(30)).map { $0.cues.map(\.text) }
        let b = naturalBreaks(seed: 77, tracks: djTracks(30)).map { $0.cues.map(\.text) }
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, naturalBreaks(seed: 78, tracks: djTracks(30)).map { $0.cues.map(\.text) })
    }

    func testBriefingBreaksKeepTheClassicPath() {
        let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: "Dentist at three.", estimatedSeconds: 2,
                               maxSeconds: 8, sourceItemID: UUID(), source: .calendar, provenance: "p")
        let handoff = NarrationHandoff(cues: [cue], maxSpokenSeconds: 150, experienceSeconds: 300)
        var writer = DJScriptWriter(cadence: dense, seed: 3, shapes: .natural)
        let plan = writer.plan(tracks: djTracks(30), briefing: handoff, hour: 9)
        let briefing = plan.breaks.filter(\.hasBriefing)
        XCTAssertEqual(briefing.count, 1)
        XCTAssertNil(briefing[0].shape)
        XCTAssertTrue(plan.breaks.contains { $0.shape != nil })
    }

    func testNaturalLinesPassTheCopyLint() {
        let pool = DJBreakShapeConfig.defaultCombined
        var spoken: [String] = pool
        for seed in UInt64(0)..<100 { spoken += naturalBreaks(seed: seed, tracks: djTracks(30)).flatMap { $0.cues.map(\.text) } }
        for line in spoken {
            let lower = line.lowercased()
            XCTAssertFalse(lower.contains("aerodj"), line)
            XCTAssertFalse(EditorialPhrasing.forbiddenHype.contains { lower.contains($0) }, line)
            XCTAssertFalse(line.unicodeScalars.contains { $0.properties.isEmojiPresentation }, line)
            XCTAssertFalse(line.contains("*") || line.contains("#") || line.contains("http") || line.contains("<"), line)
            XCTAssertLessThanOrEqual(line.split(separator: " ").count, 12, line)
        }
        for line in spoken.dropFirst(pool.count) { XCTAssertFalse(line.contains("{") || line.contains("}"), line) }
    }

    func testTieredAvoidancePrefersStrictThenRelaxes() {
        var rng = SeededGenerator(seed: 1)
        var pool = TemplatePool(["A {x}.", "B {x}.", "C {x}."])
        let picked = pool.next(filling: ["x": "1"], avoiding: [{ $0 != "C {x}." }], using: &rng)
        XCTAssertEqual(picked?.template, "C {x}.")
        XCTAssertEqual(picked?.text, "C 1.")
        let second = pool.next(filling: ["x": "1"], avoiding: [{ _ in true }, { $0 == "C {x}." }], using: &rng)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second?.template, "C {x}.")
        XCTAssertNotNil(pool.next(filling: ["x": "1"], avoiding: [{ _ in true }], using: &rng), "relaxes rather than go silent")
        XCTAssertNil(pool.next(filling: [:], avoiding: [], using: &rng))
    }

    func testRecentTemplatesRules() {
        var recent = RecentSpokenTemplates(window: 2, hereWindow: 3)
        recent.record(["Here's {nextTitle}.", "That was {title}."])
        XCTAssertTrue(recent.rejects("Here's {nextArtist}.", sameBreak: [], isOpener: false), "one Here's per 3 breaks")
        XCTAssertTrue(recent.rejects("here's {nextTitle}. ", sameBreak: [], isOpener: false))
        XCTAssertTrue(recent.rejects("Here's again.", sameBreak: [], isOpener: true), "first word repeats the last opener")
        XCTAssertFalse(recent.rejects("This is {nextTitle}.", sameBreak: [], isOpener: true))
        XCTAssertTrue(recent.rejects("This is {nextTitle}.", sameBreak: ["This is {nextTitle}."], isOpener: false))
        recent.record(["One."]); recent.record(["Two."])
        XCTAssertFalse(recent.rejects("That was {title}.", sameBreak: [], isOpener: false), "outside the window")
        XCTAssertFalse(recent.rejects("Here's {nextArtist}.", sameBreak: [], isOpener: false), "3 breaks later")
        XCTAssertFalse(recent.rejects("Two.", sameBreak: [], isOpener: false, window: 0, strict: false))

        // Spoken text counts, not just the template: two pools, same words.
        var spoken = RecentSpokenTemplates(window: 3, hereWindow: 3)
        spoken.record(["Glad {x}."], texts: ["Glad you're here."])
        XCTAssertTrue(spoken.repeats("Glad you're here.", text: "glad you're  here", sameBreak: []))
        XCTAssertFalse(spoken.repeats("Glad you're here.", sameBreak: []), "different template, no text given")
        XCTAssertTrue(spoken.repeats("A.", text: "Same.", sameBreak: ["Same."]), "same words already in this break")
    }
}
