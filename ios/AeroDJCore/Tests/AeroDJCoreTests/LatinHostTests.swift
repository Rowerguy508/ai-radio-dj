import XCTest
@testable import AeroDJCore

/// #196 (-Fry): Latin host persona, host language and Spanglish controls. Core rules only.
/// Naturalness, pronunciation and dialect are NOT TESTED here: they need human listening (§10).
final class LatinHostTests: XCTestCase {
    private let allStyles = Set(SpanishVoiceStyle.allCases)

    // MARK: Preference model

    func testDefaultIsTodaysEnglishHost() {
        let d = DJHostLanguagePreference.default
        XCTAssertEqual(d.language, .english)
        XCTAssertEqual(d.spanglish, .off)
        XCTAssertFalse(d.speaksSpanish)
        XCTAssertEqual(StationConfiguration.default.hostLanguage, d)
    }

    func testBaseLanguageAndSpanglishLevelAreIndependent() {
        // Nova's #198 mock (#666): Language English / Español, plus a separate Spanglish level.
        for language in DJHostLanguage.allCases {
            for level in SpanglishIntensity.allCases {
                let p = DJHostLanguagePreference(language: language, spanglish: level)
                XCTAssertEqual(p.language, language)
                XCTAssertEqual(p.spanglish, level)
                XCTAssertEqual(p.speaksSpanish, language == .spanish || level != .off)
            }
        }
    }

    func testRawValuesArePinned() {
        XCTAssertEqual(DJHostLanguage.allCases.map(\.rawValue), ["english", "spanish"])
        XCTAssertEqual(SpanglishIntensity.allCases.map(\.rawValue), ["off", "light", "conversational"])
        XCTAssertEqual(SpanishVoiceStyle.allCases.map(\.rawValue), ["neutralLatinAmerican", "caribbean", "mexican"])
    }

    func testPreferenceDecodesLossily() throws {
        let json = #"{"language":"spanglish","spanglish":"light","voiceStyle":"klingon"}"#
        let p = try JSONDecoder().decode(DJHostLanguagePreference.self, from: Data(json.utf8))
        XCTAssertEqual(p, DJHostLanguagePreference(language: .english, spanglish: .light, voiceStyle: .neutralLatinAmerican))
        let empty = try JSONDecoder().decode(DJHostLanguagePreference.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .default)
    }

    // MARK: StationConfiguration persistence

    func testDefaultConfigEncodingHasNoHostLanguageKey() throws {
        let data = try JSONEncoder().encode(StationConfiguration.default)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["hostLanguage"], "pre-#196 configs and recipes must round-trip byte for byte")
    }

    func testConfigRoundTripsHostLanguage() throws {
        var config = StationConfiguration(genres: ["Salsa"])
        config.hostLanguage = DJHostLanguagePreference(language: .spanish, spanglish: .conversational, voiceStyle: .caribbean)
        let back = try JSONDecoder().decode(StationConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back, config)
    }

    func testPreSixteenConfigAndBadHostLanguageLoadAsDefault() throws {
        let old = #"{"genres":["salsa"],"energy":0.5}"#
        XCTAssertEqual(try JSONDecoder().decode(StationConfiguration.self, from: Data(old.utf8)).hostLanguage, .default)
        let bad = #"{"genres":["salsa"],"hostLanguage":42}"#
        let config = try JSONDecoder().decode(StationConfiguration.self, from: Data(bad.utf8))
        XCTAssertEqual(config.hostLanguage, .default)
        XCTAssertEqual(config.genres, ["salsa"], "a bad host language never drops the rest of the config")
    }

    // MARK: Resolver: never promise a voice the device lacks

    func testEnglishNeedsNoSpanishVoice() {
        let r = DJHostLanguageResolver.resolve(.default, availableStyles: [])
        XCTAssertEqual(r, ResolvedHostLanguage(language: .english, spanglish: .off, voiceStyle: nil, downgrade: nil))
    }

    func testNoSpanishVoiceFallsBackToEnglish() {
        for pref in [DJHostLanguagePreference(language: .spanish), .init(language: .english, spanglish: .light),
                     .init(language: .spanish, spanglish: .conversational)] {
            let r = DJHostLanguageResolver.resolve(pref, availableStyles: [])
            XCTAssertEqual(r.language, .english)
            XCTAssertEqual(r.spanglish, .off)
            XCTAssertNil(r.voiceStyle)
            XCTAssertEqual(r.downgrade, .noSpanishVoice)
        }
    }

    func testRequestedStyleKeptWhenAvailable() {
        let r = DJHostLanguageResolver.resolve(.init(language: .spanish, voiceStyle: .caribbean), availableStyles: allStyles)
        XCTAssertEqual(r.voiceStyle, .caribbean)
        XCTAssertNil(r.downgrade)
    }

    func testMissingStyleFallsBackNeutralFirstAndSaysSo() {
        let pref = DJHostLanguagePreference(language: .english, spanglish: .light, voiceStyle: .caribbean)
        let neutral = DJHostLanguageResolver.resolve(pref, availableStyles: [.mexican, .neutralLatinAmerican])
        XCTAssertEqual(neutral.voiceStyle, .neutralLatinAmerican)
        XCTAssertEqual(neutral.downgrade, .styleUnavailable)
        XCTAssertEqual(neutral.language, .english)
        XCTAssertEqual(neutral.spanglish, .light)
        let mexican = DJHostLanguageResolver.resolve(pref, availableStyles: [.mexican])
        XCTAssertEqual(mexican.voiceStyle, .mexican)
        XCTAssertEqual(mexican.downgrade, .styleUnavailable)
    }

    // MARK: Genres and suggestion (station tags only)

    func testGenreTagsMatchInsensitively() {
        XCTAssertEqual(LatinGenre(tag: "Reggaetón"), .reggaeton)
        XCTAssertEqual(LatinGenre(tag: "  regional   Mexicano "), .regionalMexican)
        XCTAssertEqual(LatinGenre(tag: "Pop-Latino"), .latinPop)
        XCTAssertEqual(LatinGenre(tag: "SALSA"), .salsa)
        XCTAssertNil(LatinGenre(tag: "jazz"))
        XCTAssertNil(LatinGenre(tag: "salsa verde recipes"))
    }

    func testSuggestionNeedsHalfTheTagsToBeLatin() {
        XCTAssertFalse(LatinHostSuggestion.suggests(genres: []))
        XCTAssertFalse(LatinHostSuggestion.suggests(genres: ["jazz", "soul", "salsa"]))
        XCTAssertTrue(LatinHostSuggestion.suggests(genres: ["jazz", "bachata"]))
        XCTAssertTrue(LatinHostSuggestion.suggests(genres: ["merengue"]))
        XCTAssertEqual(LatinHostSuggestion.dominantGenre(genres: ["jazz", "bolero", "salsa"]), .bolero)
        XCTAssertNil(LatinHostSuggestion.dominantGenre(genres: ["jazz"]))
    }

    func testSuggestionReadsOnlyGenreTags() {
        // The API takes the station's genre tags and nothing else: no artist, seed or listener input.
        let source = try? String(contentsOf: Self.sourceURL, encoding: .utf8)
        let body = source?.components(separatedBy: "public enum LatinHostSuggestion").last?
            .components(separatedBy: "public struct LatinHostLine").first?
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n") ?? ""
        XCTAssertFalse(body.isEmpty)
        for banned in ["seeds", "artist:", "StationSeed", "listener", "Locale.current", "preferredLanguages"] {
            XCTAssertFalse(body.contains(banned), "LatinHostSuggestion must not read \(banned)")
        }
    }

    func testEachGenreHasItsOwnStyleNoteAndSalsaIsNotHype() {
        let notes = LatinGenre.allCases.map(\.styleNote)
        XCTAssertEqual(Set(notes).count, notes.count)
        XCTAssertFalse(LatinGenre.salsa.allowsExclamation)
        XCTAssertFalse(LatinGenre.bolero.allowsExclamation)
        XCTAssertTrue(LatinGenre.merengue.allowsExclamation)
    }

    // MARK: Script rules

    private func host(_ language: DJHostLanguage, _ intensity: SpanglishIntensity = .off) -> ResolvedHostLanguage {
        DJHostLanguageResolver.resolve(.init(language: language, spanglish: intensity), availableStyles: allStyles)
    }

    private var allLatinHosts: [ResolvedHostLanguage] {
        [host(.spanish), host(.spanish, .light), host(.spanish, .conversational), host(.english, .light), host(.english, .conversational)]
    }

    func testLightSpanglishAllowsOneShortSwitch() {
        let one = LatinHostLine([.es("Mi gente,"), .en("here comes {nextTitle}.")])
        XCTAssertEqual(LatinHostScriptRules.problems(one, host: host(.english, .light), genre: nil), [])
        let two = LatinHostLine([.es("Ahora sí."), .en("And next,"), .es("{nextTitle}.")])
        XCTAssertEqual(LatinHostScriptRules.problems(two, host: host(.spanish, .light), genre: nil), [.tooManySwitches(2)])
        XCTAssertEqual(LatinHostScriptRules.problems(two, host: host(.spanish, .conversational), genre: nil), [])
    }

    func testSpanishHostRefusesEnglishAndSpanglishRefusesMonolingual() {
        let mixed = LatinHostLine([.es("Mi gente,"), .en("up next.")])
        XCTAssertEqual(LatinHostScriptRules.problems(mixed, host: host(.spanish), genre: nil), [.wrongLanguage])
        let spanish = LatinHostLine([.es("Ahora viene {nextTitle}.")])
        XCTAssertEqual(LatinHostScriptRules.problems(spanish, host: host(.spanish, .light), genre: nil), [.wrongLanguage])
        XCTAssertEqual(LatinHostScriptRules.problems(spanish, host: host(.english, .light), genre: nil), [.wrongLanguage, .wrongBaseLanguage])
    }

    func testSpanglishLineMustLeanOnTheBaseLanguage() {
        let mostlyEnglish = LatinHostLine([.es("Mi gente,"), .en("here comes {nextTitle}.")])
        XCTAssertEqual(LatinHostScriptRules.problems(mostlyEnglish, host: host(.english, .light), genre: nil), [])
        XCTAssertEqual(LatinHostScriptRules.problems(mostlyEnglish, host: host(.spanish, .light), genre: nil), [.wrongBaseLanguage])
        let mostlySpanish = LatinHostLine([.es("Seguimos aquí con ustedes."), .en("Now, {nextTitle}.")])
        XCTAssertEqual(LatinHostScriptRules.problems(mostlySpanish, host: host(.spanish, .light), genre: nil), [])
        XCTAssertEqual(LatinHostScriptRules.problems(mostlySpanish, host: host(.english, .light), genre: nil), [.wrongBaseLanguage])
    }

    func testEnglishBaseWithoutSpanglishHasNoLatinCopy() {
        XCTAssertFalse(host(.english).speaksSpanish)
        XCTAssertEqual(LatinHostCopy.closingPool(host: host(.english), genre: nil), [])
    }

    func testStereotypesIdentityClaimsAndHypeAreRefused() {
        XCTAssertEqual(LatinHostScriptRules.textProblems("¡Ay caramba, qué tema!", genre: .merengue),
                       [.forbiddenPhrase("ay caramba"), .hype("qué tema")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Soy dominicano y esto es lo mío.", genre: nil),
                       [.identityClaim("soy dominicano")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Un tema legendary.", genre: nil), [.hype("legendary")])
    }

    func testSpanishHypeIsRefusedWithOrWithoutAccents() {
        XCTAssertEqual(LatinHostScriptRules.textProblems("Here's {nextArtist}, un temazo.", genre: nil), [.hype("temazo")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Coming up, una joya.", genre: nil), [.hype("joya")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Ese tema nunca falla.", genre: nil), [.hype("nunca falla")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Que tema.", genre: nil), [.hype("qué tema")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Qué clase de tema.", genre: nil), [.hype("qué clase de tema")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Algo increible.", genre: nil), [.hype("increíble")])
        XCTAssertFalse(LatinHostPromptRules.acceptsOutput("Una bomba de {nextArtist}.", genre: .dembow, names: []))
    }

    /// Echo's #670 follow-up: real titles and artists are not hype, and a hype word inside a
    /// longer word does not count. Host-added hype next to a name is still refused.
    func testSpanishHypeSparesRealNamesAndPartWords() {
        XCTAssertTrue(LatinHostPromptRules.acceptsOutput("Up next, La Bomba.", genre: .salsa, names: ["La Bomba"]))
        XCTAssertTrue(LatinHostPromptRules.acceptsOutput("Ahora, Bomba Estéreo.", genre: .cumbia, names: ["Bomba Estéreo"]))
        XCTAssertTrue(LatinHostPromptRules.acceptsOutput("Seguimos con El Mejor Día.", genre: .latinPop,
                                                         names: ["el mejor dia"]))
        XCTAssertTrue(LatinHostPromptRules.acceptsOutput("Seguimos con Joyas Prestadas.", genre: .latinPop, names: ["Joyas Prestadas"]))
        XCTAssertTrue(LatinHostPromptRules.acceptsOutput("Seguimos con Bombardeo.", genre: .latinPop, names: []))
        XCTAssertEqual(LatinHostScriptRules.textProblems("La Bomba, un temazo.", genre: nil, names: ["La Bomba"]),
                       [.hype("temazo")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Bomba Estéreo, una bomba.", genre: nil,
                                                         names: ["Bomba Estéreo"]), [.hype("bomba")])
        XCTAssertEqual(LatinHostScriptRules.textProblems("Up next, La Bomba.", genre: nil), [.hype("bomba")],
                       "without names the check stays strict")
    }

    /// Echo's #670 re-review (comment 7193911354): a name is removed at most once, as whole words,
    /// so the hype word repeated after the name still counts; and a name that is the whole line
    /// is never removed, so passing the line itself as a name hides nothing.
    func testANameIsRemovedOnceAndNeverAsTheWholeLine() {
        let repeats: [(String, String, String)] = [
            ("Bomba, una bomba.", "Bomba", "bomba"), ("Joya, una joya.", "Joya", "joya"),
            ("El Mejor, el mejor.", "El Mejor", "el mejor"), ("Increíble, increíble.", "Increíble", "increíble"),
            ("Temazo, un temazo.", "Temazo", "temazo"),
        ]
        for (line, name, hype) in repeats {
            XCTAssertEqual(LatinHostScriptRules.textProblems(line, genre: nil, names: [name]), [.hype(hype)], line)
            XCTAssertFalse(LatinHostPromptRules.acceptsOutput(line, genre: nil, names: [name]), line)
        }
        let line = "La Bomba, un temazo."
        XCTAssertEqual(LatinHostScriptRules.textProblems(line, genre: nil, names: [line]),
                       [.hype("temazo"), .hype("bomba")])
        XCTAssertFalse(LatinHostPromptRules.acceptsOutput(line, genre: nil, names: [line]))
        XCTAssertFalse(LatinHostPromptRules.acceptsOutput("Temazo.", genre: nil, names: ["Temazo"]))
        // The gap a name leaves never joins its neighbours into a phrase.
        XCTAssertTrue(LatinHostPromptRules.acceptsOutput("La Joya mejor.", genre: nil, names: ["Joya"]))
    }

    /// Echo's #670 review: the copy and the AI genre notes have no song data, so neither may name
    /// instruments, tempo, a genre for the song, or a verdict on it.
    private let inventedFacts = ["metales", "horn", "piano", "percus", "guitar", "guitarra", "bajar el ritmo",
                                 "tempo", "bachata", "nunca falla", "listen for", "escucha"]

    func testCopyBankInventsNoFactsAndHasNoHype() {
        for line in LatinHostCopy.closing {
            let f = line.text.lowercased()
            for word in inventedFacts { XCTAssertFalse(f.contains(word), "\(word) in \(line.text)") }
            let hype = LatinHostScriptRules.textProblems(line.text, genre: line.genres?.first).filter {
                if case .hype = $0 { return true } else { return false }
            }
            XCTAssertEqual(hype, [], line.text)
        }
    }

    func testGenreNotesNeverInviteSongClaims() {
        for genre in LatinGenre.allCases {
            let note = genre.styleNote.lowercased()
            for word in inventedFacts + ["mention", "point at"] { XCTAssertFalse(note.contains(word), "\(genre): \(note)") }
        }
        XCTAssertTrue(LatinHostPromptRules.rules.contains {
            $0.contains("instruments") && $0.contains("only if the provided facts mention them")
        })
    }

    func testExclamationOnlyOnDanceGenres() {
        XCTAssertEqual(LatinHostScriptRules.textProblems("¡Dale! Seguimos.", genre: .salsa), [.exclamationOffGenre])
        XCTAssertEqual(LatinHostScriptRules.textProblems("¡Dale! Seguimos.", genre: nil), [.exclamationOffGenre])
        XCTAssertEqual(LatinHostScriptRules.textProblems("¡Dale! Seguimos.", genre: .merengue), [])
    }

    // MARK: Copy bank

    func testEveryLineFitsAtLeastOneHostAndOnlyUsesNextSlots() {
        let hosts = allLatinHosts
        for line in LatinHostCopy.closing {
            let genres: [LatinGenre?] = line.genres.map { $0.map(Optional.some) } ?? [nil] + LatinGenre.allCases.map(Optional.some)
            let fits = hosts.contains { h in genres.contains { LatinHostScriptRules.problems(line, host: h, genre: $0).isEmpty } }
            XCTAssertTrue(fits, "unusable line: \(line.text)")
            let slots = line.text.matches(of: /\{[A-Za-z]+\}/).map { String($0.output) }
            XCTAssertTrue(Set(slots).isSubset(of: ["{nextTitle}", "{nextArtist}"]), line.text)
        }
    }

    func testEveryHostAndGenreHasAPoolAndPoolsObeyTheRules() {
        for h in allLatinHosts {
            for genre in [nil] + LatinGenre.allCases.map(Optional.some) {
                let pool = LatinHostCopy.closingPool(host: h, genre: genre)
                XCTAssertGreaterThanOrEqual(pool.count, 3, "\(h.language)/\(h.spanglish)/\(String(describing: genre))")
                for line in pool {
                    XCTAssertEqual(LatinHostScriptRules.problems(line, host: h, genre: genre), [])
                    if let g = line.genres { XCTAssertTrue(genre.map(g.contains) ?? false) }
                }
            }
        }
    }

    func testSalsaNeverGetsTheReggaetonLines() {
        let salsa = LatinHostCopy.closingPool(host: host(.english, .light), genre: .salsa).map(\.text)
        let reggaeton = LatinHostCopy.closingPool(host: host(.english, .light), genre: .reggaeton).map(\.text)
        XCTAssertFalse(salsa.contains("Let's get into {nextTitle}, dale."))
        XCTAssertTrue(reggaeton.contains("Let's get into {nextTitle}, dale."))
    }

    func testEnglishHostGetsNoLatinCopy() {
        XCTAssertEqual(LatinHostCopy.closingPool(host: host(.english), genre: .salsa), [])
        XCTAssertEqual(LatinHostCopy.closingPool(host: DJHostLanguageResolver.resolve(.init(language: .spanish), availableStyles: []), genre: .salsa), [])
    }

    // MARK: AI-path prompt rules

    func testEnglishRequestsAreUnchanged() {
        XCTAssertEqual(LatinHostPromptRules.instructions(host: host(.english), genre: .salsa), [])
        XCTAssertEqual(LatinHostPromptRules.requestFields(host: host(.english), genre: .salsa),
                       ["hostLanguage": "english", "spanglish": "off"])
    }

    func testRequestFieldsAreCodesOnly() {
        let h = DJHostLanguageResolver.resolve(.init(language: .spanish, spanglish: .conversational, voiceStyle: .mexican),
                                               availableStyles: allStyles)
        let fields = LatinHostPromptRules.requestFields(host: h, genre: .regionalMexican)
        XCTAssertEqual(fields, ["hostLanguage": "spanish", "spanglish": "conversational",
                                "voiceStyle": "mexican", "latinGenre": "regionalMexican"])
        let codes = Set(DJHostLanguage.allCases.map(\.rawValue) + SpanglishIntensity.allCases.map(\.rawValue)
                        + SpanishVoiceStyle.allCases.map(\.rawValue) + LatinGenre.allCases.map(\.rawValue))
        XCTAssertTrue(Set(fields.values).isSubset(of: codes))
    }

    func testInstructionsCarryTheFixedRulesLanguageRuleAndGenreNote() {
        let h = host(.spanish, .light)
        let lines = LatinHostPromptRules.instructions(host: h, genre: .bachata)
        XCTAssertEqual(Array(lines.prefix(LatinHostPromptRules.rules.count)), LatinHostPromptRules.rules)
        XCTAssertEqual(lines.dropLast().last, LatinHostPromptRules.languageRule(h))
        XCTAssertEqual(lines.last, LatinGenre.bachata.styleNote)
        XCTAssertTrue(lines.joined().contains("not a real person"))
        let rules = allLatinHosts.map(LatinHostPromptRules.languageRule)
        XCTAssertEqual(Set(rules).count, rules.count, "each base and level gets its own instruction")
        XCTAssertEqual(LatinHostPromptRules.languageRule(host(.english, .light)),
                       "Speak mostly English, with one short Spanish phrase per line, four words or fewer.")
    }

    func testAIOutputGoesThroughTheSameRules() {
        XCTAssertTrue(LatinHostPromptRules.acceptsOutput("Seguimos con buena música. Up next, Obsesión.", genre: .bachata, names: ["Obsesión"]))
        XCTAssertFalse(LatinHostPromptRules.acceptsOutput("Arriba arriba, here comes the next one.", genre: .cumbia, names: []))
        XCTAssertFalse(LatinHostPromptRules.acceptsOutput("As a Latina, I love this one.", genre: .latinPop, names: []))
    }

    // MARK: Not wired yet

    func testNotWiredIntoBreakSessionYet() throws {
        let session = try String(contentsOf: Self.sourceURL.deletingLastPathComponent().appendingPathComponent("DJBreakSession.swift"),
                                 encoding: .utf8)
        XCTAssertFalse(session.contains("LatinHost"), "#196 wiring is a separate, reviewed step")
    }

    static var sourceURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AeroDJCore/DJ/LatinHost.swift")
    }
}
