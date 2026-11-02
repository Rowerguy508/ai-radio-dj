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
        ("Ocean Avenue (Live 2014)", "Yellowcard"),
        ("Rather Be (Clean Bandit Remix)", "Clean Bandit feat. Jess Glynne"),
        ("Song - Live 2011", "Artist"),
        ("Song (with Strings) [Acoustic]", "Artist"),
        ("Help! (Live)", "The Beatles"),
    ]

    /// Every persona's bank (lane 4). Each house-style test below runs over all of them.
    static let tones: [(name: String, tone: EditorialTone)] =
        DJPersonality.allCases.map { ($0.rawValue, EditorialTone.forPersonality($0)) }

    static func pools(_ tone: EditorialTone) -> [(String, [String])] {
        [
            ("backAnnounce", tone.backAnnounce), ("closing", tone.closing), ("artistFocus", tone.artistFocus),
            ("stationID", tone.stationID), ("continuation", tone.continuation), ("briefingLead", tone.briefingLead),
            ("briefingOutro", tone.briefingOutro),
            ("atmosphere", DayPart.allCases.flatMap { tone.atmosphere[$0, default: []] }),
            ("greetings", DayPart.allCases.flatMap { tone.greetings[$0, default: []] }),
            ("combined", tone.combined),
        ]
    }

    /// Every reason a spoken line fails the house style; empty when it passes.
    static func problems(_ line: String) -> [String] {
        var found: [String] = []
        let lower = line.lowercased()
        if lower.contains("aerodj") || lower.contains("aero dj") { found.append("old brand") }
        if line.contains(where: { "*_#`".contains($0) }) { found.append("markdown character") }
        if line.contains("[") || line.contains("]") { found.append("bracket or markdown link") }
        if line.contains("(") || line.contains(")") { found.append("round bracket") }
        if line.range(of: #",\s*[,.!?;:]"#, options: .regularExpression) != nil { found.append("comma run") }
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
            "Song - Remastered.", "Song [Explicit].", "That's Song (Live).", "Song,, then more.", "That's Song, .",
            "Song, Live, ?",
        ]
        for line in bad { XCTAssertFalse(Self.problems(line).isEmpty, "lint should reject: \(line)") }
        for line in ["That's Holocene from Bon Iver.", "OnAirly. Stick around.", "Morning — let's ease into it.",
                     "Here's Pink + White, from Frank Ocean.", "Sunflower featuring Swae Lee.",
                     "That's Ocean Avenue, Live 2014 there."] {
            XCTAssertEqual(Self.problems(line), [], line)
        }
    }

    func testEveryPoolLineRendersCleanWithSampleMetadata() {
        for (toneName, tone) in Self.tones { for (pool, lines) in Self.pools(tone) {
            let name = "\(toneName).\(pool)"
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
        } }
    }

    /// The closing line talks up the intro, so its template is one sentence of seven words or fewer.
    func testClosingLinesAreSevenWordsOrFewer() {
        for (name, tone) in Self.tones {
            for line in tone.closing {
                XCTAssertLessThanOrEqual(line.split(separator: " ").count, 7, "\(name): \(line)")
                XCTAssertEqual(line.filter { ".?".contains($0) }.count, 1, "\(name), one sentence: \(line)")
                XCTAssertTrue(line.contains("{nextTitle}"), "\(name), names the next song: \(line)")
            }
        }
    }

    /// Stock phrases say themselves once: a greeting, station ID and atmosphere line can share a break.
    func testStockPhrasesAppearInOnePoolLineAtMost() {
        for (name, tone) in Self.tones {
            let lines = tone.allLines.map { $0.lowercased() }
            for phrase in ["glad you're here", "ease into", "easy does it", "good to have you"] {
                XCTAssertLessThanOrEqual(lines.filter { $0.contains(phrase) }.count, 1, "\(name): \(phrase)")
            }
        }
    }

    /// Day-part lines are mood only: nothing that is false late in the day part or reads as a clock time.
    func testDayPartLinesMakeNoClockClaims() {
        for (name, tone) in Self.tones {
        let dayPartLines = DayPart.allCases.flatMap { tone.atmosphere[$0, default: []] + tone.greetings[$0, default: []] }
        for line in dayPartLines {
            let lower = line.lowercased()
            for claim in ["halfway", "left", "o'clock", "middle of", "almost", "nearly", "midday", "noon", "midnight"] {
                // Whole words only: "afternoon" is a day part, "noon" is a clock claim.
                XCTAssertNil(lower.range(of: "\\b\(claim)\\b", options: .regularExpression), "\(name), \(claim): \(line)")
            }
            XCTAssertNil(line.rangeOfCharacter(from: .decimalDigits), "\(name): \(line)")
        }
        }
    }

    func testPoolsAreDeepEnoughToAvoidQuickRepeats() {
        for (toneName, tone) in Self.tones {
        for (name, lines) in [("backAnnounce", tone.backAnnounce), ("closing", tone.closing), ("artistFocus", tone.artistFocus),
                              ("stationID", tone.stationID), ("continuation", tone.continuation),
                              ("briefingLead", tone.briefingLead), ("briefingOutro", tone.briefingOutro),
                              ("combined", tone.combined)] {
            XCTAssertTrue((8...12).contains(lines.count), "\(toneName).\(name) has \(lines.count) lines; the house style wants 8 to 12")
        }
        for part in DayPart.allCases {
            XCTAssertGreaterThanOrEqual(tone.atmosphere[part, default: []].count, 3, "\(toneName) atmosphere \(part)")
            XCTAssertGreaterThanOrEqual(tone.greetings[part, default: []].count, 3, "\(toneName) greetings \(part)")
        }
        let contractions = tone.allLines.filter { $0.contains("'") }.count
        XCTAssertGreaterThanOrEqual(Double(contractions) / Double(tone.allLines.count), 0.25, "\(toneName): contractions throughout")
        }
    }

    /// 600 planned sessions (60 seeds x 5 hours x with/without a briefing) per persona.
    func testPlannedSessionsSpeakOnlyCleanLines() {
        for (name, tone) in Self.tones { assertPlannedSessionsClean(tone, name) }
    }

    private func assertPlannedSessionsClean(_ tone: EditorialTone, _ toneName: String) {
        let named = Self.samples.enumerated().map { DJTrack(id: "n\($0.offset)", title: $0.element.title, artist: $0.element.artist) }
        let tracks = named + djTracks(18) + named
        let note = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "You've got Grocery list. From your notes.",
                                estimatedSeconds: 4, maxSeconds: 12, sourceItemID: UUID(), source: .obsidian, provenance: "n:1")
        var spokenLines = 0
        for seed in UInt64(1)...60 {
            for hour in [5, 9, 14, 19, 23] {
                for briefing in [nil, NarrationHandoff(cues: [note], maxSpokenSeconds: 150, experienceSeconds: 300)] {
                    var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed,
                                                stationName: "OnAirly", tone: tone)
                    for djBreak in writer.plan(tracks: tracks, briefing: briefing, hour: hour).breaks {
                        for cue in djBreak.cues {
                            assertClean(cue.text, "\(toneName) seed \(seed) hour \(hour)")
                            spokenLines += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(spokenLines, 3_000, toneName)
    }

    // MARK: Personas (lane 4)

    func testForPersonalityMapsEachPersonalityToItsBank() {
        XCTAssertEqual(EditorialTone.forPersonality(.warm), .warm)
        XCTAssertEqual(EditorialTone.forPersonality(.upbeat), .upbeat)
        XCTAssertEqual(EditorialTone.forPersonality(.laidBack), .laidBack)
        XCTAssertEqual(EditorialTone.forPersonality(.minimal), .minimal)
        let banks = DJPersonality.allCases.map { EditorialTone.forPersonality($0) }
        for (i, a) in banks.enumerated() { for b in banks[(i + 1)...] { XCTAssertNotEqual(a, b, "each persona sounds different") } }
    }

    /// New personas are their own words: no line is copied verbatim from `warm`, and no pool repeats a line.
    func testPersonaBanksDoNotReuseWarmLinesOrRepeatWithinAPool() {
        let warm = Set(EditorialTone.warm.allLines)
        for (name, tone) in Self.tones {
            if tone != .warm {
                for line in tone.allLines { XCTAssertFalse(warm.contains(line), "\(name) copies warm: \(line)") }
            }
            for (pool, lines) in Self.pools(tone) + DayPart.allCases.map({ ("greetings \($0)", tone.greetings[$0, default: []]) }) {
                if pool == "atmosphere" || pool == "greetings" { continue }
                XCTAssertEqual(Set(lines).count, lines.count, "\(name).\(pool) has a duplicate line")
            }
            for part in DayPart.allCases {
                let lines = tone.atmosphere[part, default: []]
                XCTAssertEqual(Set(lines).count, lines.count, "\(name).atmosphere \(part) has a duplicate line")
            }
        }
    }

    /// Each pool fills only from its own facts, and no line carries a number of its own.
    func testPersonaPoolsUseOnlyTheirOwnPlaceholders() {
        for (name, tone) in Self.tones {
            let allowed: [(String, [String], Set<String>)] = [
                ("backAnnounce", tone.backAnnounce, ["title", "artist"]),
                ("artistFocus", tone.artistFocus, ["title", "artist"]),
                ("closing", tone.closing, ["nextTitle", "nextArtist"]),
                ("stationID", tone.stationID, ["station"]),
                ("continuation", tone.continuation, []), ("briefingLead", tone.briefingLead, []),
                ("briefingOutro", tone.briefingOutro, []),
                ("atmosphere", tone.atmosphere.values.flatMap { $0 }, []),
                ("greetings", tone.greetings.values.flatMap { $0 }, []),
                ("combined", tone.combined, ["title", "artist", "nextTitle", "nextArtist"]),
            ]
            for (pool, lines, ok) in allowed {
                for line in lines {
                    XCTAssertTrue(Self.placeholders(line).isSubset(of: ok), "\(name).\(pool): \(line)")
                    XCTAssertFalse(line.contains(where: \.isNumber), "\(name).\(pool): \(line)")
                }
            }
            for part in DayPart.allCases {
                XCTAssertFalse(tone.atmosphere[part, default: []].isEmpty, "\(name) atmosphere \(part)")
                XCTAssertFalse(tone.greetings[part, default: []].isEmpty, "\(name) greeting \(part)")
            }
        }
    }

    /// Lane 4 follow-up: each persona's combined ("that was X, here's Y") bank names the song that
    /// just played and the next one, from track metadata only, and leans on "Here's" at most once.
    func testCombinedBanksNameBothSongsInTheHouseStyle() {
        XCTAssertEqual(EditorialTone.warm.combined, [
            "That was {title}. Now here's {nextTitle}.",
            "{artist} there. Now let's hear {nextArtist}.",
            "That's {title}. We'll go to {nextTitle} next.",
            "{title}, from {artist}. Next it's {nextTitle}.",
            "Okay, that's {artist}. Here comes {nextArtist}.",
            "{artist}, {title}. And this one's {nextArtist}.",
            "We're going from {artist} to {nextArtist}.",
            "{title} there. Up next, it's {nextArtist}.",
        ], "warm's combined lines: #344's slots, re-pinned for the casual pass (build 34 owner note)")
        for (name, tone) in Self.tones {
            XCTAssertTrue((8...12).contains(tone.combined.count), "\(name).combined has \(tone.combined.count) lines")
            XCTAssertLessThanOrEqual(tone.combined.filter { $0.lowercased().hasPrefix("here's") }.count, 1,
                                     "\(name).combined: one line starting \"Here's\" at most")
            for line in tone.combined {
                let found = Self.placeholders(line)
                XCTAssertTrue(found.isSubset(of: ["title", "artist", "nextTitle", "nextArtist"]), "\(name).combined: \(line)")
                XCTAssertFalse(found.isDisjoint(with: ["title", "artist"]), "\(name).combined names the song that played: \(line)")
                XCTAssertFalse(found.isDisjoint(with: ["nextTitle", "nextArtist"]), "\(name).combined names the next song: \(line)")
                XCTAssertFalse(line.contains(where: \.isNumber), "\(name).combined: \(line)")
                XCTAssertLessThanOrEqual(line.split(separator: " ").count, 12, "\(name).combined, one breath: \(line)")
            }
            let tones = Self.tones.map(\.tone)
            for other in tones where other != tone {
                XCTAssertTrue(Set(tone.combined).isDisjoint(with: other.combined), "\(name).combined shares a line with another persona")
            }
        }
    }

    /// Sentinel's rule for premium voices: the typed station name lives only in station-ID lines,
    /// which the writer attributes `.stationName` so `mayLeaveDevice` keeps them on-device.
    func testStationPlaceholderAppearsOnlyInStationIDLines() {
        for (name, tone) in Self.tones {
            XCTAssertTrue(tone.stationID.allSatisfy { $0.contains("{station}") }, "\(name): every station ID names the station")
            for (pool, lines) in Self.pools(tone) where pool != "stationID" {
                for line in lines { XCTAssertFalse(line.contains("{station}"), "\(name).\(pool) inlines the station: \(line)") }
            }
        }
    }

    /// With and without a briefing: the typed name and personal-update text never ride in a
    /// `.presenter` segment, so `mayLeaveDevice` can keep both on-device.
    func testATypedStationNameIsNeverAPresenterLine() {
        let typed = "Kitchen Radio"
        let personal = "You've got Grocery list. From your notes."
        let tracks = djTracks(24)
        let note = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: personal,
                                estimatedSeconds: 4, maxSeconds: 12, sourceItemID: UUID(), source: .obsidian, provenance: "n:1")
        let briefings: [NarrationHandoff?] = [nil, NarrationHandoff(cues: [note], maxSpokenSeconds: 150, experienceSeconds: 300)]
        for (name, tone) in Self.tones {
            var sawName = false, sawBriefing = false
            for seed in UInt64(1)...40 {
                for hour in [5, 9, 14, 19, 23] {
                    for briefing in briefings {
                        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed,
                                                    stationName: typed, tone: tone)
                        for djBreak in writer.plan(tracks: tracks, briefing: briefing, hour: hour).breaks {
                            for cue in djBreak.cues {
                                let attribution = djBreak.attributions[cue.id]
                                let context = "\(name) seed \(seed) hour \(hour) briefing \(briefing != nil): \(cue.text)"
                                if cue.text.contains(typed) {
                                    sawName = true
                                    XCTAssertEqual(attribution, .stationName, context)
                                }
                                if cue.text == personal {
                                    sawBriefing = true
                                    guard case .personalContext = attribution else {
                                        return XCTFail("personal update not attributed .personalContext: \(context)")
                                    }
                                }
                                if attribution == .presenter {
                                    XCTAssertFalse(cue.text.contains(typed), "typed name in a presenter line: \(context)")
                                    XCTAssertFalse(cue.text.contains("Grocery list"), "personal text in a presenter line: \(context)")
                                }
                            }
                        }
                    }
                }
            }
            XCTAssertTrue(sawName, "\(name): station IDs still air with the typed name")
            XCTAssertTrue(sawBriefing, "\(name): the briefing case actually placed the personal update")
        }
    }

    private static func placeholders(_ line: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.insert(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    /// The shipped default: the built-in station name, every raw pool line, and whole sessions
    /// planned with the writer's default name never say the old brand.
    func testShippedDefaultsNeverSayTheOldBrand() {
        XCTAssertEqual(DJScriptWriter.builtInStationName, "OnAirly")
        XCTAssertFalse(Self.problems(DJScriptWriter.builtInStationName).contains("old brand"))
        for line in EditorialTone.warm.allLines {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("aerodj"), line)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("aero dj"), line)
        }
        var sawStationID = false
        for seed in UInt64(1)...40 {
            var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed)
            for djBreak in writer.plan(tracks: djTracks(24), briefing: nil, hour: [8, 15, 22][Int(seed % 3)]).breaks {
                for cue in djBreak.cues {
                    assertClean(cue.text, "default writer seed \(seed)")
                    if cue.text.contains("OnAirly") { sawStationID = true }
                }
            }
        }
        XCTAssertTrue(sawStationID, "station IDs air with the real name")
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
        XCTAssertEqual(SpokenTitle.clean("Holocene (Live)"), "Holocene, Live")
        XCTAssertEqual(SpokenTitle.clean("Midnight City (Eric Prydz Remix)"), "Midnight City, Eric Prydz Remix")
        XCTAssertEqual(SpokenTitle.clean("Song - Acoustic"), "Song, Acoustic")
        XCTAssertEqual(SpokenTitle.clean("Re-Make - Re-Model"), "Re-Make - Re-Model")
        // A title that is only a tag is spoken as it was rather than as nothing.
        XCTAssertEqual(SpokenTitle.clean("(Remastered)"), "(Remastered)")
        XCTAssertEqual(SpokenTitle.clean(""), "")
        XCTAssertEqual(SpokenTitle.cleanArtist("Ana feat. Bo"), "Ana featuring Bo")
        XCTAssertEqual(SpokenTitle.cleanArtist("Ana ft. Bo"), "Ana featuring Bo")
        XCTAssertEqual(SpokenTitle.cleanArtist("Simon & Garfunkel"), "Simon & Garfunkel")
    }

    /// #339 follow-up (-Fry): tags match exactly, not by prefix or suffix, and anything naming the
    /// recording (remix, mix, live, acoustic, demo) is kept. "(with X)" is not always a credit.
    /// Since the bracket fix (-Echo), kept tags keep their words but are spoken as ", tag".
    func testSpokenTitleKeepsRecordingVersionsThatStartOrEndLikeATag() {
        let kept: [(String, String)] = [
            ("Rather Be (Clean Bandit Remix)", "Rather Be, Clean Bandit Remix"),   // starts with "clean"
            ("Rather Be - Clean Bandit Remix", "Rather Be, Clean Bandit Remix"),
            ("Song (Mono Remix)", "Song, Mono Remix"),                             // starts with "mono"
            ("Song (Stereo Mix)", "Song, Stereo Mix"),                             // starts with "stereo"
            ("Song (Live 2011 Remaster)", "Song, Live 2011 Remaster"),             // ends with "remaster"
            ("Song - Live 2011 Remaster", "Song, Live 2011 Remaster"),
            ("Song (Live Edition)", "Song, Live Edition"),                         // ends with "edition"
            ("Song (Acoustic Version)", "Song, Acoustic Version"),
            ("Song (Demo Remastered)", "Song, Demo Remastered"),
            ("Song (LIVE)", "Song, LIVE"),
            ("Song (with Strings)", "Song, with Strings"),                         // not an artist credit
        ]
        for (raw, spoken) in kept { XCTAssertEqual(SpokenTitle.clean(raw), spoken, raw) }
    }

    // MARK: SpokenTitle brackets (-Echo)

    func testKeptTagsAreSpokenWithoutBracketsKeepingTheirWordsAndCase() {
        // Orion's case. Casing is preserved exactly ("Live", not "live").
        XCTAssertEqual(SpokenTitle.clean("Ocean Avenue (Live 2014)"), "Ocean Avenue, Live 2014")
        XCTAssertEqual(SpokenTitle.clean("Ocean Avenue [Live 2014]"), "Ocean Avenue, Live 2014")
        let remix = SpokenTitle.clean("Rather Be (Clean Bandit Remix)")
        XCTAssertEqual(remix, "Rather Be, Clean Bandit Remix")
        XCTAssertTrue(remix.contains("Clean Bandit Remix"), "the tag's words survive as written")
        XCTAssertEqual(SpokenTitle.clean("Song - Live 2011 Remaster"), "Song, Live 2011 Remaster")
        XCTAssertEqual(SpokenTitle.clean("Song – Acoustic"), "Song, Acoustic")
        XCTAssertEqual(SpokenTitle.clean("Song (with Strings)"), "Song, with Strings")
        // Several kept tags become a comma chain; catalog tags in the chain still drop.
        XCTAssertEqual(SpokenTitle.clean("Song (Live) [Acoustic]"), "Song, Live, Acoustic")
        XCTAssertEqual(SpokenTitle.clean("Song (Live) [Explicit]"), "Song, Live")
        XCTAssertEqual(SpokenTitle.clean("Song (Remastered 2011) - Live 2011"), "Song, Live 2011")
        XCTAssertEqual(SpokenTitle.clean("Sunflower (feat. Swae Lee) (Live)"), "Sunflower featuring Swae Lee, Live")
        // No words are ever added: the spoken words are the raw words minus dropped catalog tags.
        for raw in ["Ocean Avenue (Live 2014)", "Rather Be (Clean Bandit Remix)", "Song (Live) [Acoustic]",
                    "Song - Live 2011 Remaster", "Song (with Strings)"] {
            XCTAssertEqual(Self.words(SpokenTitle.clean(raw)), Self.words(raw), raw)
        }
    }

    func testBracketedAndDashedTagsSpeakIdentically() {
        XCTAssertEqual(SpokenTitle.clean("Song (Live 2011 Remaster)"), SpokenTitle.clean("Song - Live 2011 Remaster"))
        XCTAssertEqual(SpokenTitle.clean("Song - Live 2011 Remaster"), "Song, Live 2011 Remaster")
    }

    func testCatalogTagsAndFeaturingAreUnchangedByTheBracketFix() {
        XCTAssertEqual(SpokenTitle.clean("Midnight City (Remastered 2011)"), "Midnight City")
        XCTAssertEqual(SpokenTitle.clean("Song (Remastered 2011)"), "Song")
        XCTAssertEqual(SpokenTitle.clean("Dreams - 2004 Remaster"), "Dreams")
        XCTAssertEqual(SpokenTitle.clean("Sunflower (feat. Swae Lee)"), "Sunflower featuring Swae Lee")
        XCTAssertEqual(SpokenTitle.clean("Sunflower feat. Swae Lee"), "Sunflower featuring Swae Lee")
        XCTAssertEqual(SpokenTitle.cleanArtist("Ana feat. Bo"), "Ana featuring Bo")
        // Dash suffixes that do not name a recording are left as written.
        XCTAssertEqual(SpokenTitle.clean("Re-Make - Re-Model"), "Re-Make - Re-Model")
    }

    func testOddBracketsAreLeftUnchangedRatherThanMangled() {
        let unchanged = [
            "Song (Live 2014",            // unbalanced
            "Song Live 2014)",            // unbalanced
            "Song (Live [2014])",         // nested
            "Song (Live 2014]",           // mismatched
            "(Live)",                     // only a bracket
            "(Live) (Remix)",             // only brackets
            "(Remastered)",               // only a catalog tag
            "(I Can't Get No) Satisfaction", // leading bracket is part of the title
        ]
        for raw in unchanged { XCTAssertEqual(SpokenTitle.clean(raw), raw, raw) }
        XCTAssertEqual(SpokenTitle.clean("Song, (Live)"), "Song, Live", "no double comma")
        XCTAssertEqual(SpokenTitle.clean("Song ( Live , )"), "Song, Live", "no comma before the end")
        XCTAssertEqual(SpokenTitle.clean("Song ()"), "Song")
    }

    /// #352 review follow-ups (-Fry's nits, -Echo).
    func testDashSuffixesThatDoNotNameARecordingAreLeftAsWritten() {
        // Nit 2: plain words after a dash reach the recording-word gate and must stay as written.
        for raw in ["Song - Part Two", "Song – Part Two", "Song — Interlude", "Clocks - Reprise"] {
            XCTAssertEqual(SpokenTitle.clean(raw), raw, raw)
        }
        XCTAssertEqual(SpokenTitle.clean("Song - Part Two (Live)"), "Song - Part Two, Live")
    }

    func testMalformedBracketsStillDropCatalogTags() {
        // Nit 1: odd brackets only skip the tag rewrite; catalog tags still drop as before #352.
        XCTAssertEqual(SpokenTitle.clean("Song [Explicit] (Remix (Edit))"), "Song (Remix (Edit))")
        XCTAssertEqual(SpokenTitle.clean("Song (Live [2014]) [Explicit]"), "Song (Live [2014])")
        // A stray closing bracket before a kept tag leaves the tag as written.
        XCTAssertEqual(SpokenTitle.clean("Song] (Live)"), "Song] (Live)")
    }

    func testSeparatorsAfterTheLastTagDoNotKeepItsBrackets() {
        // Nit 3: trailing separators go before the rewrite, so the tag still loses its brackets.
        XCTAssertEqual(SpokenTitle.clean("Song (Live) ,"), "Song, Live")
        XCTAssertEqual(SpokenTitle.clean("Song (Live);"), "Song, Live")
        XCTAssertEqual(SpokenTitle.clean("Song [Acoustic] :"), "Song, Acoustic")
    }

    func testTitlesEndingASentenceTakeNoCommaBeforeTheirTags() {
        // Nit 4: "Help!, Live" read oddly; same words, no comma after "!", "?" or ".".
        XCTAssertEqual(SpokenTitle.clean("Help! (Live)"), "Help! Live")
        XCTAssertEqual(SpokenTitle.clean("Why? (Acoustic) [Live]"), "Why? Acoustic, Live")
        XCTAssertEqual(SpokenTitle.clean("Song. - Live 2011"), "Song. Live 2011")
        XCTAssertEqual(SpokenTitle.clean("Help! (2009 Digital Remaster)"), "Help!")
        for raw in ["Help! (Live)", "Why? (Acoustic) [Live]"] {
            XCTAssertEqual(Self.words(SpokenTitle.clean(raw)), Self.words(raw), raw)
            let line = TemplatePool.fill("That's {title}, from {artist}.", ["title": raw, "artist": "M83"])!
            XCTAssertNil(line.range(of: #"[!?.],"#, options: .regularExpression), line)
            XCTAssertFalse(line.contains("(") || line.contains(")"), line)
        }
    }

    /// #353 blocker (-Fry): a nested group is never cut in half by the catalog or "feat." rewrite.
    func testNestedBracketGroupsAreNeverCutInHalf() {
        XCTAssertEqual(SpokenTitle.clean("Song (Remastered [2011])"), "Song (Remastered [2011])")
        XCTAssertEqual(SpokenTitle.clean("Song [Remastered (2011)]"), "Song [Remastered (2011)]")
        XCTAssertEqual(SpokenTitle.clean("Song (feat. X [Y])"), "Song (feat. X [Y])")
        XCTAssertEqual(SpokenTitle.clean("Song [Explicit] (Remix (Edit))"), "Song (Remix (Edit))")
        // Found by the property check below: a catalog dash suffix inside a group no longer eats its ")".
        XCTAssertEqual(SpokenTitle.clean("Song (Dreams - 2004 Remaster)"), "Song, Dreams - 2004 Remaster")
        XCTAssertEqual(SpokenTitle.clean("Song - Remastered (2011)"), "Song")
    }

    /// Every bracketed or dashed title fixture in this file, alone and with tags added around it:
    /// cleanup never leaves an unbalanced bracket or a lone ")" / "]" that the raw title did not have.
    static let bracketTitleFixtures: [String] = [
        "Midnight City (Remastered 2011)", "Dreams - 2004 Remaster", "Hold On [Explicit]", "Sunflower (feat. Swae Lee)",
        "Ocean Avenue (Live 2014)", "Rather Be (Clean Bandit Remix)", "Song - Live 2011", "Song (with Strings) [Acoustic]",
        "Help! (Live)", "Dreams - Remastered", "Let It Be (Remastered 2009)", "Hold On (Clean)",
        "Rumours (Deluxe Edition)", "Song (Single Version)", "Song (40th Anniversary Edition)", "Sunflower [feat. Swae Lee]",
        "Sunflower (ft. Swae Lee) [Explicit]", "Holocene (Live)", "Midnight City (Eric Prydz Remix)", "Song - Acoustic",
        "Re-Make - Re-Model", "(Remastered)", "Rather Be - Clean Bandit Remix", "Song (Mono Remix)",
        "Song (Stereo Mix)", "Song (Live 2011 Remaster)", "Song - Live 2011 Remaster", "Song (Live Edition)",
        "Song (Acoustic Version)", "Song (Demo Remastered)", "Song (LIVE)", "Song (with Strings)",
        "Ocean Avenue [Live 2014]", "Song – Acoustic", "Song (Live) [Acoustic]", "Song (Live) [Explicit]",
        "Song (Remastered 2011) - Live 2011", "Sunflower (feat. Swae Lee) (Live)", "Song (Remastered 2011)", "Song (Live 2014",
        "Song Live 2014)", "Song (Live [2014])", "Song (Live 2014]", "(Live)",
        "(Live) (Remix)", "(I Can't Get No) Satisfaction", "Song, (Live)", "Song ( Live , )",
        "Song ()", "Song - Part Two", "Song – Part Two", "Song — Interlude",
        "Clocks - Reprise", "Song - Part Two (Live)", "Song - Part Two, Live", "Song [Explicit] (Remix (Edit))",
        "Song (Remix (Edit))", "Song (Live [2014]) [Explicit]", "Song] (Live)", "Song (Live) ,",
        "Song (Live);", "Song [Acoustic] :", "Why? (Acoustic) [Live]", "Song. - Live 2011",
        "Help! (2009 Digital Remaster)", "Song [Acoustic]", "Song (Live) [Demo]", "Let It Be - Remastered 2009",
        "Song (Remastered Version)", "Song (Clean Version)", "Song (Mono)", "Song [Stereo]",
        "Rumours (Super Deluxe Edition)", "Song (Bonus Track Version)", "Sunflower (Featuring Swae Lee)", "Sunflower ft. Swae Lee - Remastered",
        "Mix (Remastered)", "Mix (Remastered). Stick around.", "Song (Remastered [2011])", "Song [Remastered (2011)]",
        "Song (feat. X [Y])", "Song [feat. X (Y)]", "Song (Explicit [Live])",
    ]

    func testCleanupNeverLeavesAnUnbalancedBracket() {
        let fixtures = Self.bracketTitleFixtures + Self.samples.map(\.title)
        var inputs: [String] = []
        for raw in fixtures {
            inputs += [raw, raw + " (Live)", raw + " [Explicit]", raw + " - Live 2011", "Song (" + raw + ")",
                       "Song [" + raw + "]", "Song (Remastered [" + raw + "])", "Song (feat. X [" + raw + "])"]
        }
        for raw in inputs {
            let spoken = SpokenTitle.clean(raw)
            if Self.bracketsBalance(raw) { XCTAssertTrue(Self.bracketsBalance(spoken), "\(raw) -> \(spoken)") }
            if !Self.hasLoneCloser(raw) { XCTAssertFalse(Self.hasLoneCloser(spoken), "\(raw) -> \(spoken)") }
        }
    }

    /// Brackets close in order and with their own kind (nesting allowed).
    private static func bracketsBalance(_ text: String) -> Bool {
        var stack: [Character] = []
        for char in text {
            switch char {
            case "(", "[": stack.append(char)
            case ")": guard stack.popLast() == "(" else { return false }
            case "]": guard stack.popLast() == "[" else { return false }
            default: continue
            }
        }
        return stack.isEmpty
    }

    /// A ")" or "]" with no open bracket of its own kind before it.
    private static func hasLoneCloser(_ text: String) -> Bool {
        var round = 0, square = 0
        for char in text {
            switch char {
            case "(": round += 1
            case "[": square += 1
            case ")": if round == 0 { return true }; round -= 1
            case "]": if square == 0 { return true }; square -= 1
            default: continue
            }
        }
        return false
    }

    func testTemplateFillNeverMakesCommaRuns() {
        for template in ["{title} there.", "That's {title}, from {artist}.", "Up next: {nextTitle}!", "{title}?"] {
            for raw in ["Ocean Avenue (Live 2014)", "Song (Live) [Acoustic]", "Song, (Live)", "Song,", "Song ( Live , )",
                        "Song - Live 2011 Remaster", "Song (Remastered 2011)"] {
                let line = TemplatePool.fill(template, ["title": raw, "nextTitle": raw, "artist": "M83"])!
                XCTAssertNil(line.range(of: #",\s*[,.!?;:]"#, options: .regularExpression), line)
                XCTAssertFalse(line.contains("(") || line.contains(")"), line)
            }
        }
        XCTAssertEqual(TemplatePool.fill("{title} there.", ["title": "Ocean Avenue (Live 2014)"]),
                       "Ocean Avenue, Live 2014 there.")
    }

    /// Every tone's every pool line, filled from bracketed sample titles, speaks no bracket.
    func testNoToneSpeaksABracketForBracketedTitles() {
        let titles = ["Ocean Avenue (Live 2014)", "Rather Be (Clean Bandit Remix)", "Song [Acoustic]",
                      "Song (Live) [Demo]", "Song (with Strings)", "Midnight City (Remastered 2011)", "Hold On [Explicit]"]
        let names = Set(Self.tones.map(\.name))
        XCTAssertEqual(names, ["warm", "upbeat", "laidBack", "minimal"])
        for (toneName, tone) in Self.tones { for (pool, lines) in Self.pools(tone) { for template in lines {
            for title in titles {
                guard let line = TemplatePool.fill(template, ["title": title, "nextTitle": title, "artist": "Artist",
                                                              "nextArtist": "Artist", "station": "OnAirly"]) else { continue }
                XCTAssertFalse(line.contains(where: { "()[]".contains($0) }), "\(toneName).\(pool): \(line)")
            }
        } } }
    }

    /// Sentinel: the fix is formatting only. A plan over bracketed titles gives every cue the
    /// same attribution (track ids and origin) as the same plan over the already-spoken titles.
    func testCleanedTitlesKeepTheirTrackOriginAttribution() {
        let raws = ["Ocean Avenue (Live 2014)", "Rather Be (Clean Bandit Remix)", "Song - Live 2011 Remaster",
                    "Song (with Strings) [Acoustic]"]
        func tracks(_ titles: [String]) -> [DJTrack] {
            titles.enumerated().map { i, title in
                DJTrack(id: "b\(i)", title: title, artist: "Artist \(i)", origin: i % 2 == 0 ? .library : .catalog)
            } + djTracks(12, origin: .catalog)
        }
        let bracketed = tracks(raws + raws), spoken = tracks((raws + raws).map(SpokenTitle.clean))
        var sawCleanTitle = false
        for (toneName, tone) in Self.tones {
            for seed in UInt64(1)...30 {
                var a = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed, tone: tone)
                var b = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed, tone: tone)
                let planA = a.plan(tracks: bracketed, briefing: nil, hour: 9)
                let planB = b.plan(tracks: spoken, briefing: nil, hour: 9)
                XCTAssertEqual(planA.breaks.count, planB.breaks.count, "\(toneName) seed \(seed)")
                for (breakA, breakB) in zip(planA.breaks, planB.breaks) {
                    XCTAssertEqual(breakA.cues.map(\.text), breakB.cues.map(\.text), "\(toneName) seed \(seed)")
                    for (cueA, cueB) in zip(breakA.cues, breakB.cues) {
                        XCTAssertEqual(breakA.attributions[cueA.id], breakB.attributions[cueB.id], "\(toneName): \(cueA.text)")
                        for (i, raw) in raws.enumerated() where cueA.text.contains(SpokenTitle.clean(raw)) {
                            sawCleanTitle = true
                            guard case .trackMetadata(let ids, let origin)? = breakA.attributions[cueA.id] else {
                                return XCTFail("cleaned title not attributed to track metadata: \(cueA.text)")
                            }
                            XCTAssertTrue(ids.contains("b\(i)") || ids.contains("b\(i + raws.count)"), cueA.text)
                            if i % 2 == 0 { XCTAssertEqual(origin, .library, "library stays on-device: \(cueA.text)") }
                        }
                    }
                }
            }
        }
        XCTAssertTrue(sawCleanTitle, "the plans actually spoke a cleaned title")
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    func testSpokenTitleStillDropsExactTagsWithYearsOrVersion() {
        let cases: [(String, String)] = [
            ("Midnight City (Remastered 2011)", "Midnight City"),
            ("Let It Be - Remastered 2009", "Let It Be"),
            ("Dreams - 2004 Remaster", "Dreams"),
            ("Help! (2009 Digital Remaster)", "Help!"),
            ("Song (Remastered Version)", "Song"),
            ("Song (Clean Version)", "Song"),
            ("Song (Mono)", "Song"),
            ("Song [Stereo]", "Song"),
            ("Rumours (Super Deluxe Edition)", "Rumours"),
            ("Song (Bonus Track Version)", "Song"),
            ("Sunflower (feat. Swae Lee)", "Sunflower featuring Swae Lee"),
            ("Sunflower (Featuring Swae Lee)", "Sunflower featuring Swae Lee"),
            ("Sunflower (ft. Swae Lee) [Explicit]", "Sunflower featuring Swae Lee"),
            ("Sunflower ft. Swae Lee - Remastered", "Sunflower featuring Swae Lee"),
        ]
        for (raw, spoken) in cases { XCTAssertEqual(SpokenTitle.clean(raw), spoken, raw) }
        // The exact-match rule is not a prefix rule: a tag followed by other words stays.
        XCTAssertFalse(SpokenTitle.isCatalogTag("Clean Bandit Remix"))
        XCTAssertFalse(SpokenTitle.isCatalogTag("Explicit Content Warning"))
        XCTAssertTrue(SpokenTitle.isCatalogTag("40th Anniversary Edition"))
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
