import Foundation
import XCTest
@testable import AeroDJCore

// Natural break shapes (lane 2, -Fry). Everything runs in-process: no voice, no network.

private struct FixedExtra: DJBreakExtraLineSource {
    let line: DJExtraLine?
    func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine? { line }
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
        XCTAssertLessThanOrEqual(Double(hereViolations) / Double(windows), 0.10, "\"Here's\" more than once in 3 breaks: \(hereViolations)/\(windows)")
    }

    func testEveryNaturalBreakFitsTheCaps() {
        let config = DJBreakShapeConfig.natural
        let extra = FixedExtra(line: DJExtraLine(text: "A short extra line here.", attribution: .presenter))
        for seed in UInt64(0)..<200 {
            for b in naturalBreaks(seed: seed, tracks: djTracks(30, origin: .catalog), extra: extra) {
                XCTAssertLessThanOrEqual(b.estimatedSeconds, Double(config.maxBreakSeconds))
                XCTAssertLessThanOrEqual(b.mainSeconds, Double(DJCadence().maxTransitionSeconds))
                XCTAssertLessThanOrEqual(b.cues.count, config.maxCuesPerBreak)
                XCTAssertFalse(b.hasBriefing)
                if let talkOver = b.talkOverCueID { XCTAssertEqual(talkOver, b.cues.last?.id) }
                XCTAssertEqual(Set(b.attributions.keys), Set(b.cues.map(\.id)), "every cue is attributed")
            }
        }
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
        let line = DJExtraLine(text: "Bit of rain later.", attribution: .presenter)
        let breaks = naturalBreaks(seed: 9, tracks: djTracks(30, origin: .catalog), config: .init(weights: [.comingUpOnly: 1]),
                                   extra: FixedExtra(line: line))
        XCTAssertFalse(breaks.isEmpty)
        for b in breaks {
            XCTAssertEqual(b.cues.map(\.text).first, line.text)
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
    }
}
