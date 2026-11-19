import XCTest
@testable import AeroDJCore

/// Build 34 owner note, applied to warm's regular breaks: casual, like a DJ hanging out with a
/// friend. Extends #359's opener lint (`ShowOpenerTests.formalPhrases`: announcer boilerplate and
/// spelled-out forms) to every pool an ordinary warm break speaks from, and requires contractions
/// in at least half of those lines. The copy changes; the slots, the pool depth, the caps and the
/// anti-repeat rules do not. Naturalness is not tested here: nobody has listened to it. -Echo
final class WarmCasualCopyTests: XCTestCase {
    /// Every pool an ordinary (non-briefing, non-opener) warm break draws from.
    static func regularPools(_ tone: EditorialTone = .warm) -> [(String, [String])] {
        [
            ("backAnnounce", tone.backAnnounce), ("closing", tone.closing), ("artistFocus", tone.artistFocus),
            ("stationID", tone.stationID), ("continuation", tone.continuation), ("combined", tone.combined),
        ] + DayPart.allCases.map { ("atmosphere \($0)", tone.atmosphere[$0, default: []]) }
    }

    /// The time-check bank warm's regular breaks speak (`DJTimeCheckPhrases()` defaults, Fry's #347).
    static var timeCheckLines: [String] { EditorialTone.warm.allTimeCheckLines }

    /// A real contraction: letters on both sides of the apostrophe. "{artist}'s" is a slot
    /// possessive, not a contraction, so it does not count.
    static func hasContraction(_ line: String) -> Bool {
        line.range(of: #"[A-Za-z](?:'s|'re|'ll|'ve|'d|'m|n't)\b"#, options: .regularExpression) != nil
    }

    static func slots(_ line: String) -> String {
        var found: Set<String> = []
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.insert(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found.sorted().joined(separator: " ")
    }

    func testTheContractionCheckIgnoresSlotPossessives() {
        XCTAssertTrue(Self.hasContraction("That's {title}."))
        XCTAssertTrue(Self.hasContraction("Don't go anywhere."))
        XCTAssertFalse(Self.hasContraction("{station}'s got you covered."))
        XCTAssertFalse(Self.hasContraction("That is {title}."))
    }

    func testWarmRegularBreakCopyHasNoAnnouncerPhrasing() {
        for (pool, lines) in Self.regularPools() {
            for line in lines { XCTAssertEqual(ShowOpenerTests.formal(line), [], "warm.\(pool): \(line)") }
        }
        for line in Self.timeCheckLines { XCTAssertEqual(ShowOpenerTests.formal(line), [], "warm.timeChecks: \(line)") }
    }

    func testAtLeastHalfOfWarmRegularBreakLinesUseContractions() {
        let lines = Self.regularPools().flatMap(\.1) + Self.timeCheckLines
        let share = Double(lines.filter(Self.hasContraction).count) / Double(lines.count)
        XCTAssertGreaterThanOrEqual(share, 0.5, "warm regular breaks: contractions in \(share) of lines")
    }

    func testWarmRegularBreakSentencesStayShort() {
        for (pool, lines) in Self.regularPools() {
            for line in lines {
                for sentence in line.split(whereSeparator: { ".?!".contains($0) }) {
                    XCTAssertLessThanOrEqual(sentence.split(separator: " ").count, 12, "warm.\(pool): \(line)")
                }
            }
        }
    }

    /// Same slots in the same place, so attribution and facts are exactly what they were, and at
    /// least as many templates per slot as before the casual pass (variety for anti-repeat).
    func testWarmPoolsKeepTheirSlotsAndDepth() {
        let warm = EditorialTone.warm
        let pinned: [(String, [String], [String])] = [
            ("backAnnounce", warm.backAnnounce, Array(repeating: "artist title", count: 10)),
            ("closing", warm.closing, ["nextArtist nextTitle", "nextArtist nextTitle", "nextArtist nextTitle", "nextTitle",
                                       "nextArtist nextTitle", "nextArtist nextTitle", "nextTitle", "nextArtist nextTitle",
                                       "nextTitle", "nextTitle"]),
            ("artistFocus", warm.artistFocus, ["artist", "artist title", "artist", "artist title", "artist", "artist", "artist", "artist"]),
            ("stationID", warm.stationID, Array(repeating: "station", count: 8)),
            ("continuation", warm.continuation, Array(repeating: "", count: 8)),
            ("combined", warm.combined, ["nextTitle title", "artist nextArtist", "nextTitle title", "artist nextTitle title",
                                         "artist nextArtist", "artist nextArtist title", "artist nextArtist", "nextArtist title"]),
        ]
        for (pool, lines, slots) in pinned {
            XCTAssertEqual(lines.map(Self.slots), slots, "warm.\(pool): slots or depth changed")
            XCTAssertEqual(Set(lines).count, lines.count, "warm.\(pool): duplicate")
        }
        for part in DayPart.allCases {
            let lines = warm.atmosphere[part, default: []]
            XCTAssertGreaterThanOrEqual(lines.count, 4, "warm.atmosphere \(part)")
            XCTAssertTrue(lines.allSatisfy { Self.slots($0).isEmpty }, "warm.atmosphere \(part): mood lines have no slots")
        }
        XCTAssertEqual(warm.timeChecks, DJTimeCheckPhrases(), "warm keeps #347's time-check bank (already casual)")
    }

    /// Whole planned warm sessions: every ordinary break (not the opener, not a briefing) passes the casual lint.
    func testPlannedWarmOrdinaryBreaksSpeakNoAnnouncerPhrasing() {
        var checked = 0
        for seed in UInt64(1)...40 {
            for hour in [5, 9, 14, 19, 23] {
                var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed,
                                            stationName: "OnAirly", tone: .warm, shapes: .natural)
                for djBreak in writer.plan(tracks: djTracks(24), briefing: nil, hour: hour).breaks
                where djBreak.shape != .showOpener && !djBreak.hasBriefing {
                    for cue in djBreak.cues {
                        XCTAssertEqual(ShowOpenerTests.formal(cue.text), [], "seed \(seed) hour \(hour): \(cue.text)")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 2_000)
    }
}
