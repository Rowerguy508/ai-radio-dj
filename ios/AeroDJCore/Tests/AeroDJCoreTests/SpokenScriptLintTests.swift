import XCTest
@testable import AeroDJCore

/// House-style lint for what the DJ actually says (dj-naturalness plan, section 5). Renders every
/// pool line with sample metadata, and whole planned sessions across seeds and hours, and rejects
/// anything that would sound wrong through a voice: the old brand, markdown, emoji, URLs, tags,
/// leftover braces, catalog suffixes, and robotic or assistant phrasing. Complements #297's
/// source-literal scan by checking rendered output, metadata included.
final class SpokenScriptLintTests: XCTestCase {
    /// Lower-cased phrases a radio host would not say.
    static let roboticPhrases = [
        "as an ai", "here is", "here are", "i hope you enjoy", "hope you enjoy", "let me", "in conclusion",
        "additionally", "furthermore", "moreover", "i'd be happy", "i would be happy", "certainly",
        "your personalized", "personalized station", "welcome to your", "i'm your ai", "ai dj",
        "the next song is", "you just heard the song", "by the artist", "the song titled", "track number",
        "firstly", "secondly", "first,", "second,", "lastly", "without further ado", "stay tuned for more updates",
        "just you, me, and the music", "thanks for spending a little time here",
    ]

    /// Sample fills, including raw catalog metadata the speaker must never read verbatim.
    static let samples: [(title: String, artist: String)] = [
        ("Holocene", "Bon Iver"),
        ("Pink + White", "Frank Ocean"),
        ("Midnight City (Remastered 2011)", "M83"),
        ("Dreams - 2004 Remaster", "Fleetwood Mac"),
        ("Hold On [Explicit]", "Ana feat. Bo"),
        ("Sunflower (feat. Swae Lee)", "Post Malone"),
    ]

    /// Every reason a spoken line fails the house style; empty when it passes.
    static func problems(_ line: String) -> [String] {
        var found: [String] = []
        let lower = line.lowercased()
        if lower.contains("aerodj") || lower.contains("aero dj") { found.append("old brand") }
        if line.contains(where: { "*_#`".contains($0) }) { found.append("markdown character") }
        if line.contains("[") || line.contains("]") { found.append("bracket or markdown link") }
        if line.range(of: #"^\s*(?:[-•]|\d+\.)\s"#, options: .regularExpression) != nil { found.append("list marker") }
        if line.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation
            || ($0.properties.isEmoji && $0.value > 0x238C) }) { found.append("emoji") }
        if lower.contains("http") || lower.contains("www.") || lower.contains("://")
            || lower.range(of: #"\.(com|net|org|io|app)\b"#, options: .regularExpression) != nil { found.append("url") }
        if line.contains("<") || line.contains(">") { found.append("tag") }
        if line.contains("{") || line.contains("}") { found.append("leftover brace") }
        if line.contains("!!") || line.contains("??") { found.append("punctuation run") }
        for phrase in roboticPhrases where lower.contains(phrase) { found.append("robotic: \(phrase)") }
        for word in EditorialPhrasing.forbiddenHype where lower.contains(word) { found.append("hype: \(word)") }
        if lower.range(of: #"\b(feat|ft)\."#, options: .regularExpression) != nil { found.append("raw feat.") }
        if lower.contains("remaster") || lower.contains("explicit") { found.append("catalog suffix") }
        return found
    }

    private func assertClean(_ line: String, _ context: String, file: StaticString = #filePath, line number: UInt = #line) {
        let issues = Self.problems(line)
        XCTAssertTrue(issues.isEmpty, "\(context): \"\(line)\" -> \(issues)", file: file, line: number)
    }

    func testTheLintCatchesEachProblem() {
        let bad = [
            "You're listening to AeroDJ.", "**Holocene**, Bon Iver.", "`Next`: Myth.", "# Up next", "- Holocene",
            "1. Holocene", "Holocene 🎶", "Visit onairly.app now.", "See https://example.com.", "<break time=\"1s\"/>",
            "Here's {nextTitle}.", "Wow!!", "Here is your next song.", "Let me catch you up.", "As an AI, I pick songs.",
            "I hope you enjoy this one.", "Additionally, there's more.", "That was amazing.", "Song (feat. X).",
            "Song - Remastered.", "Song [Explicit].",
        ]
        for line in bad { XCTAssertFalse(Self.problems(line).isEmpty, "lint should reject: \(line)") }
        for line in ["That's Holocene from Bon Iver.", "OnAirly. Stick around.", "Morning — let's ease into it.",
                     "Here's Pink + White, from Frank Ocean.", "Sunflower featuring Swae Lee."] {
            XCTAssertEqual(Self.problems(line), [], line)
        }
    }

    func testEveryPoolLineRendersCleanWithSampleMetadata() {
        let tone = EditorialTone.warm
        let pools: [(String, [String])] = [
            ("backAnnounce", tone.backAnnounce), ("closing", tone.closing), ("artistFocus", tone.artistFocus),
            ("stationID", tone.stationID), ("continuation", tone.continuation), ("briefingLead", tone.briefingLead),
            ("briefingOutro", tone.briefingOutro),
            ("atmosphere", DayPart.allCases.flatMap { tone.atmosphere[$0, default: []] }),
            ("greetings", DayPart.allCases.flatMap { tone.greetings[$0, default: []] }),
        ]
        for (name, lines) in pools {
            for template in lines {
                for sample in Self.samples {
                    let values = ["title": sample.title, "artist": sample.artist, "nextTitle": sample.title,
                                  "nextArtist": sample.artist, "station": "OnAirly"]
                    guard let line = TemplatePool.fill(template, values) else {
                        return XCTFail("\(name): \"\(template)\" did not fill from the sample metadata")
                    }
                    assertClean(line, name)
                }
                // House style: short spoken sentences.
                for sentence in template.split(whereSeparator: { ".?".contains($0) }) {
                    XCTAssertLessThanOrEqual(sentence.split(separator: " ").count, 12, "\(name): \(template)")
                }
            }
        }
    }

    func testPoolsAreDeepEnoughToAvoidQuickRepeats() {
        let tone = EditorialTone.warm
        for (name, lines) in [("backAnnounce", tone.backAnnounce), ("closing", tone.closing), ("artistFocus", tone.artistFocus),
                              ("stationID", tone.stationID), ("continuation", tone.continuation),
                              ("briefingLead", tone.briefingLead), ("briefingOutro", tone.briefingOutro)] {
            XCTAssertTrue((8...12).contains(lines.count), "\(name) has \(lines.count) lines; the house style wants 8 to 12")
        }
        for part in DayPart.allCases {
            XCTAssertGreaterThanOrEqual(tone.atmosphere[part, default: []].count, 3, "atmosphere \(part)")
            XCTAssertGreaterThanOrEqual(tone.greetings[part, default: []].count, 3, "greetings \(part)")
        }
        let contractions = tone.allLines.filter { $0.contains("'") }.count
        XCTAssertGreaterThanOrEqual(Double(contractions) / Double(tone.allLines.count), 0.25, "contractions throughout")
    }

    func testPlannedSessionsSpeakOnlyCleanLines() {
        let named = Self.samples.enumerated().map { DJTrack(id: "n\($0.offset)", title: $0.element.title, artist: $0.element.artist) }
        let tracks = named + djTracks(18) + named
        let note = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "You've got Grocery list. From your notes.",
                                estimatedSeconds: 4, maxSeconds: 12, sourceItemID: UUID(), source: .obsidian, provenance: "n:1")
        var spokenLines = 0
        for seed in UInt64(1)...60 {
            for hour in [5, 9, 14, 19, 23] {
                for briefing in [nil, NarrationHandoff(cues: [note], maxSpokenSeconds: 150, experienceSeconds: 300)] {
                    var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed,
                                                stationName: "OnAirly")
                    for djBreak in writer.plan(tracks: tracks, briefing: briefing, hour: hour).breaks {
                        for cue in djBreak.cues {
                            assertClean(cue.text, "seed \(seed) hour \(hour)")
                            spokenLines += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(spokenLines, 3_000)
    }

    // MARK: SpokenTitle

    func testSpokenTitleDropsCatalogSuffixesAndSpeaksFeaturedArtists() {
        let cases: [(String, String)] = [
            ("Midnight City (Remastered 2011)", "Midnight City"),
            ("Dreams - 2004 Remaster", "Dreams"),
            ("Dreams - Remastered", "Dreams"),
            ("Let It Be (Remastered 2009)", "Let It Be"),
            ("Hold On [Explicit]", "Hold On"),
            ("Hold On (Clean)", "Hold On"),
            ("Rumours (Deluxe Edition)", "Rumours"),
            ("Song (Single Version)", "Song"),
            ("Song (40th Anniversary Edition)", "Song"),
            ("Sunflower (feat. Swae Lee)", "Sunflower featuring Swae Lee"),
            ("Sunflower [feat. Swae Lee]", "Sunflower featuring Swae Lee"),
            ("Sunflower (ft. Swae Lee) [Explicit]", "Sunflower featuring Swae Lee"),
            ("Sunflower feat. Swae Lee", "Sunflower featuring Swae Lee"),
            ("  Holocene  ", "Holocene"),
            ("Pink + White", "Pink + White"),
        ]
        for (raw, spoken) in cases { XCTAssertEqual(SpokenTitle.clean(raw), spoken, raw) }
    }

    func testSpokenTitleKeepsMeaningfulVersionsAndNeverEmptiesATitle() {
        // These say which recording it is, so they stay.
        XCTAssertEqual(SpokenTitle.clean("Holocene (Live)"), "Holocene (Live)")
        XCTAssertEqual(SpokenTitle.clean("Midnight City (Eric Prydz Remix)"), "Midnight City (Eric Prydz Remix)")
        XCTAssertEqual(SpokenTitle.clean("Song - Acoustic"), "Song - Acoustic")
        XCTAssertEqual(SpokenTitle.clean("Re-Make - Re-Model"), "Re-Make - Re-Model")
        // A title that is only a tag is spoken as it was rather than as nothing.
        XCTAssertEqual(SpokenTitle.clean("(Remastered)"), "(Remastered)")
        XCTAssertEqual(SpokenTitle.clean(""), "")
        XCTAssertEqual(SpokenTitle.cleanArtist("Ana feat. Bo"), "Ana featuring Bo")
        XCTAssertEqual(SpokenTitle.cleanArtist("Ana ft. Bo"), "Ana featuring Bo")
        XCTAssertEqual(SpokenTitle.cleanArtist("Simon & Garfunkel"), "Simon & Garfunkel")
    }

    func testTemplateFillSpeaksTheCleanTitleAndStillRefusesMissingValues() {
        XCTAssertEqual(TemplatePool.fill("That's {title} from {artist}.",
                                         ["title": "Midnight City (Remastered 2011)", "artist": "M83"]),
                       "That's Midnight City from M83.")
        XCTAssertEqual(TemplatePool.fill("Here's {nextTitle}.", ["nextTitle": "Sunflower (feat. Swae Lee)"]),
                       "Here's Sunflower featuring Swae Lee.")
        XCTAssertEqual(TemplatePool.fill("{station}. Stick around.", ["station": "Mix (Remastered)"]),
                       "Mix (Remastered). Stick around.", "the station name is not a track title")
        XCTAssertNil(TemplatePool.fill("That's {title} from {artist}.", ["title": "Holocene"]))
        XCTAssertNil(TemplatePool.fill("That's {title} from {artist}.", ["title": "Holocene", "artist": ""]))
        XCTAssertNil(TemplatePool.fill("That's {title}.", ["title": "   "]))
    }
}
