import XCTest
@testable import AeroDJCore

private func resp(_ term: String, _ spoken: String) -> PronunciationHint {
    PronunciationHint(term: term, respelling: spoken)!
}

private func ipa(_ term: String, _ sounds: String) -> PronunciationHint {
    PronunciationHint(term: term, ipa: sounds)!
}

final class PronunciationHintsTests: XCTestCase {
    // MARK: hint validation

    func testHintsRefuseMarkupQuotesAndEmptyValues() {
        XCTAssertNil(PronunciationHint(term: "", respelling: "x"))
        XCTAssertNil(PronunciationHint(term: "  ", ipa: "x"))
        XCTAssertNil(PronunciationHint(term: "Sade", respelling: ""))
        XCTAssertNil(PronunciationHint(term: "Sade", respelling: "a<break/>b"))
        XCTAssertNil(PronunciationHint(term: "Sade", ipa: "a\"b"))
        XCTAssertNil(PronunciationHint(term: "Sade", ipa: "a&b"))
        XCTAssertNil(PronunciationHint(term: "Sade", respelling: "it's"))
        XCTAssertNil(PronunciationHint(term: "Sade", respelling: "a\nb"))
        XCTAssertNil(PronunciationHint(term: "Sade", respelling: String(repeating: "a", count: 81)))
        XCTAssertNotNil(PronunciationHint(term: "Sade", ipa: "ʃɑˈdeɪ"))
    }

    // MARK: plain-text transform

    func testRespellingReplacesTheNameAndKeepsTheRestOfTheLine() {
        let t = PronunciationHintTable([resp("Sade", "Shah-day")])
        XCTAssertEqual(t.applying(toPlainText: "Up next, Sade with Smooth Operator."), "Up next, Shah-day with Smooth Operator.")
    }

    func testEmptyTableAndNoMatchLeaveTextUnchanged() {
        let line = "Up next, Tame Impala."
        XCTAssertEqual(PronunciationHintTable.empty.applying(toPlainText: line), line)
        XCTAssertEqual(PronunciationHintTable([resp("Sade", "Shah-day")]).applying(toPlainText: line), line)
        XCTAssertFalse(PronunciationHintTable([resp("Sade", "Shah-day")]).applies(to: line))
        XCTAssertEqual(PronunciationHintTable([resp("Sade", "Shah-day")]).segments(in: line), [.text(line)])
        XCTAssertEqual(PronunciationHintTable.standard.segments(in: ""), [])
    }

    func testMatchingIgnoresCaseAccentsAndCurlyApostrophes() {
        let t = PronunciationHintTable([resp("Beyoncé", "Bee-yon-say"), resp("Guns N' Roses", "Guns and Roses")])
        XCTAssertEqual(t.applying(toPlainText: "beyonce, BEYONCÉ and Beyoncé"), "Bee-yon-say, Bee-yon-say and Bee-yon-say")
        XCTAssertEqual(t.applying(toPlainText: "Guns N\u{2019} Roses"), "Guns and Roses")
    }

    func testOnlyWholeNamesMatch() {
        let t = PronunciationHintTable([resp("Sade", "Shah-day")])
        XCTAssertEqual(t.applying(toPlainText: "Persuaded, Sadeness, 3Sade"), "Persuaded, Sadeness, 3Sade")
        XCTAssertEqual(t.applying(toPlainText: "Sade's best"), "Shah-day's best")
        XCTAssertEqual(t.applying(toPlainText: "(Sade)"), "(Shah-day)")
    }

    func testLongestNameWinsWhereTwoOverlap() {
        let t = PronunciationHintTable([resp("Lil", "Little"), resp("Lil Nas X", "Lil Naz Ex")])
        XCTAssertEqual(t.applying(toPlainText: "Lil Nas X then Lil Wayne"), "Lil Naz Ex then Little Wayne")
    }

    func testNameWithPunctuationAtItsEdgesStillMatches() {
        let t = PronunciationHintTable([resp("P!nk", "Pink"), resp("AC/DC", "A C D C")])
        XCTAssertEqual(t.applying(toPlainText: "P!nk, then AC/DC."), "Pink, then A C D C.")
    }

    func testLaterHintForTheSameNameReplacesTheEarlierOne() {
        let t = PronunciationHintTable([resp("Sade", "Shah-day"), resp("SADE", "Shar-day")])
        XCTAssertEqual(t.hints.count, 1)
        XCTAssertEqual(t.applying(toPlainText: "Sade"), "Shar-day")
        let merged = PronunciationHintTable([resp("Sade", "A")]).merging(PronunciationHintTable([resp("Sade", "B")]))
        XCTAssertEqual(merged.applying(toPlainText: "Sade"), "B")
    }

    func testTransformIsPureAndRepeatable() {
        let t = PronunciationHintTable.standard
        let line = "Next up: Sade, then Björk."
        XCTAssertEqual(t.applying(toPlainText: line), t.applying(toPlainText: line))
        XCTAssertEqual(t.applying(toPlainText: line), "Next up: Shah-day, then Byerk.")
    }

    // MARK: IPA

    func testIPASegmentsKeepTheWrittenNameAndSplitTheLine() {
        let t = PronunciationHintTable([ipa("Sade", "ʃɑˈdeɪ")])
        XCTAssertEqual(t.segments(in: "Hear Sade now"), [.text("Hear "), .ipa(text: "Sade", ipa: "ʃɑˈdeɪ"), .text(" now")])
        XCTAssertEqual(t.applying(toPlainText: "Hear Sade now"), "Hear Sade now", "plain text cannot carry IPA")
        XCTAssertTrue(t.applies(to: "Hear Sade now"))
    }

    // MARK: SSML

    func testSSMLRespellingIsAppliedInTextAndTagsAreUntouched() {
        let t = PronunciationHintTable([resp("Sade", "Shah-day")])
        let ssml = SpeechDelivery.ssml("Up next is Sade. Then more music.")
        XCTAssertEqual(t.applying(toSSML: ssml), "<speak>Up next is Shah-day.<break time=\"300ms\"/> Then more music.</speak>")
    }

    func testSSMLWithNoMatchIsReturnedByteForByte() {
        let ssml = SpeechDelivery.ssml("Fish & chips: Tom's \"best\" <hits>. Then more.")
        XCTAssertEqual(PronunciationHintTable.standard.applying(toSSML: ssml), ssml)
        XCTAssertEqual(PronunciationHintTable.empty.applying(toSSML: ssml), ssml)
    }

    func testSSMLEscapingSurvivesAChangedRun() {
        let t = PronunciationHintTable([resp("Sade", "Shah-day")])
        let ssml = SpeechDelivery.ssml("Sade & Tom's <live> \"set\"")
        XCTAssertEqual(t.applying(toSSML: ssml), "<speak>Shah-day &amp; Tom&apos;s &lt;live&gt; &quot;set&quot;</speak>")
    }

    func testSSMLNameWithAnApostropheMatchesItsEscapedForm() {
        let t = PronunciationHintTable([resp("Guns N' Roses", "Guns and Roses")])
        XCTAssertEqual(t.applying(toSSML: SpeechDelivery.ssml("Guns N' Roses next")), "<speak>Guns and Roses next</speak>")
    }

    func testEntityNamesNeverMatchInsideEscapes() {
        let t = PronunciationHintTable([resp("amp", "AMP"), resp("lt", "LT"), resp("quot", "QUOT")])
        let ssml = SpeechDelivery.ssml("Fish & chips < 5 \"quoted\"")
        XCTAssertEqual(t.applying(toSSML: ssml), ssml)
    }

    func testSSMLIPAIsWrappedInAPhonemeElement() {
        let t = PronunciationHintTable([ipa("Sade", "ʃɑˈdeɪ")])
        XCTAssertEqual(t.applying(toSSML: SpeechDelivery.ssml("Hear Sade now")),
                       "<speak>Hear <phoneme alphabet=\"ipa\" ph=\"ʃɑˈdeɪ\">Sade</phoneme> now</speak>")
    }

    func testRunWithANumericCharacterReferenceIsLeftAlone() {
        let t = PronunciationHintTable([resp("Sade", "Shah-day")])
        XCTAssertEqual(t.applying(toSSML: "<speak>Sade &#39;s</speak>"), "<speak>Sade &#39;s</speak>")
    }

    func testPlainTextOfHintedSSMLIsTheRespelledLine() {
        let t = PronunciationHintTable([resp("Sade", "Shah-day")])
        let hinted = t.applying(toSSML: SpeechDelivery.ssml("Up next is Sade. Then more."))
        XCTAssertEqual(SpeechDelivery.plainText(fromSSML: hinted), "Up next is Shah-day. Then more.")
    }

    // MARK: seed table

    func testStandardTableEntriesAreAllValidRespellings() {
        XCTAssertFalse(PronunciationHintTable.standard.isEmpty)
        for hint in PronunciationHintTable.standard.hints {
            guard case .respelling(let spoken) = hint.kind else { return XCTFail("seed entries are respellings only") }
            XCTAssertNotEqual(spoken, hint.term)
        }
    }

    func testStandardTableFixesTheKnownNames() {
        let t = PronunciationHintTable.standard
        XCTAssertEqual(t.applying(toPlainText: "Sade, Beyoncé and Billie Eilish"), "Shah-day, Bee-yon-say and Billie Eye-lish")
        XCTAssertEqual(t.applying(toPlainText: "Deadmau5 and AC/DC"), "dead mouse and A C D C")
    }

    func testHintsDoNotTouchCloudSpeakableText() {
        // The table is applied only by the on-device route; SpeechDelivery output is independent of it.
        XCTAssertEqual(SpeechDelivery.speakable("Sade at 9 AM"), "Sade at 9 a.m.")
    }
}
