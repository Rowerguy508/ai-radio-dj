import XCTest
@testable import AeroDJCore

// Add-station walkthrough step rules (-Nova).

final class AddStationWalkthroughTests: XCTestCase {
    private typealias W = AddStationWalkthrough

    private func ready(typed: String = "", suggested: String? = "Khruangbin Radio",
                       existing: [String] = [], saving: Bool = false) -> AddStationProgress {
        AddStationProgress(kind: .artists, pickError: nil, level: .balanced, typedName: typed,
                           suggestedName: suggested, existingNames: existing, isSaving: saving)
    }

    func testStepsAreNumberedOneToSevenInOrder() {
        XCTAssertEqual(AddStationStep.allCases.map(\.number), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(AddStationStep.allCases, [.kind, .picks, .level, .personality, .talk, .name, .review])
        XCTAssertEqual(AddStationStep.kind.next, .picks)
        XCTAssertEqual(AddStationStep.level.next, .personality)
        XCTAssertEqual(AddStationStep.talk.next, .name)
        XCTAssertNil(AddStationStep.review.next)
        XCTAssertNil(AddStationStep.kind.previous)
        XCTAssertEqual(AddStationStep.picks.accessibilityLabel, "Step 2 of 7, Pick")
    }

    func testTuningStepsAreOptionalAndNeverBlockNext() {
        let p = ready()
        XCTAssertTrue(W.canGoNext(from: .level, p))
        XCTAssertTrue(W.canGoNext(from: .personality, p))
        XCTAssertTrue(W.canGoNext(from: .talk, p))
        XCTAssertFalse(W.canGoNext(from: .talk, ready(saving: true)))
        var noLevel = p
        noLevel.level = nil
        XCTAssertEqual(W.furthestReachable(noLevel), .level, "optional steps don't jump past a missing level")
    }

    func testFreshFlowOnlyAllowsChoosingAKind() {
        let p = AddStationProgress()
        XCTAssertFalse(W.canGoNext(from: .kind, p))
        XCTAssertFalse(W.canGoBack(from: .kind, p))
        XCTAssertEqual(W.furthestReachable(p), .kind)
    }

    func testPicksStepNeedsValidPicks() {
        var p = AddStationProgress(kind: .genre, pickError: .noSeeds)
        XCTAssertTrue(W.canGoNext(from: .kind, p))
        XCTAssertFalse(W.canGoNext(from: .picks, p))
        p.pickError = .invalidGenreID
        XCTAssertFalse(W.isComplete(.picks, p))
        p.pickError = nil
        XCTAssertTrue(W.canGoNext(from: .picks, p))
        XCTAssertEqual(W.furthestReachable(p), .level)
    }

    func testBlankNameUsesSuggestion() {
        XCTAssertEqual(try W.resolvedName(ready()).get(), "Khruangbin Radio")
        XCTAssertEqual(try W.resolvedName(ready(typed: "  Sunday   Drive ")).get(), "Sunday Drive")
    }

    func testNameErrorsMatchRecipeLibraryRules() {
        XCTAssertEqual(W.nameError(ready(suggested: nil)), .emptyName)
        XCTAssertEqual(W.nameError(ready(typed: String(repeating: "a", count: 41))), .nameTooLong)
        XCTAssertEqual(W.nameError(ready(existing: ["khruangbin radio"])), .duplicateName)
        XCTAssertNil(W.nameError(ready(typed: "Other", existing: ["khruangbin radio"])))
        XCTAssertFalse(W.canGoNext(from: .name, ready(existing: ["Khruangbin Radio"])))
    }

    func testSaveOnlyOnReviewWhenEverythingIsComplete() {
        let p = ready()
        XCTAssertTrue(W.canSave(on: .review, p))
        XCTAssertFalse(W.canSave(on: .name, p))
        XCTAssertFalse(W.canGoNext(from: .review, p))
        XCTAssertEqual(W.furthestReachable(p), .review)
        var missing = p
        missing.pickError = .noSeeds
        XCTAssertFalse(W.canSave(on: .review, missing))
    }

    func testSavingLocksNavigation() {
        let p = ready(saving: true)
        XCTAssertFalse(W.canSave(on: .review, p))
        XCTAssertFalse(W.canGoBack(from: .review, p))
        XCTAssertFalse(W.canGoNext(from: .level, p))
    }

    func testHintsAreFixedCopyWithTheArtistCap() {
        XCTAssertEqual(W.pickHint(for: .artists), "Pick up to 5 artists.")
        XCTAssertEqual(W.kindSummary(.genre), "One Apple Music genre.")
    }
}

// Optional DJ and talk steps: "Keep current tuning" (nil) first, copy reused from Tune.
final class AddStationTuningTests: XCTestCase {
    private typealias T = AddStationTuning

    func testOptionsStartWithKeepThenEveryPreset() {
        XCTAssertEqual(T.personalityOptions, [nil, .warm, .upbeat, .laidBack, .minimal])
        XCTAssertEqual(T.talkOptions, [nil, .off, .rare, .occasional, .frequent, .chatty])
        XCTAssertEqual(T.title(nil as DJPersonality?), "Keep current tuning")
        XCTAssertEqual(T.title(nil as CommentaryFrequency?), "Keep current tuning")
        XCTAssertEqual(T.title(CommentaryFrequency.chatty), "Chatty")
    }

    func testKeepNamesTheTuneValue() {
        XCTAssertEqual(T.detail(nil as DJPersonality?, current: .laidBack), "Uses your Tune setting: Laid-back.")
        XCTAssertEqual(T.detail(nil as CommentaryFrequency?, current: .rare), "Uses your Tune setting: Rarely.")
        XCTAssertEqual(T.reviewValue(nil as CommentaryFrequency?, current: .rare), "Rarely (from Tune)")
        XCTAssertEqual(T.reviewValue(CommentaryFrequency.frequent, current: .rare), "Often")
        XCTAssertEqual(T.reviewValue(DJPersonality.minimal, current: .warm), "Minimal")
    }

    func testTalkCopyIsTheTuneCopyAndMatchesThePlanner() {
        // Reuses the Tune strings, so the walkthrough says whatever the planner delivers. Chatty
        // is "every song" once the owner's back-to-back override (#165) is in, and "about N%,
        // never two in a row" before it. Only a preset the planner lets talk at every
        // boundary may say "every song".
        let chatty = T.detail(CommentaryFrequency.chatty, current: .off)
        XCTAssertEqual(chatty, CommentaryFrequency.chatty.honestDescription, "reuses the Tune copy")
        for option in T.talkOptions.compactMap({ $0 }) where option != .off {
            let detail = T.detail(option, current: .chatty)
            XCTAssertEqual(detail, option.honestDescription, "\(option)")
            let share = StationConfiguration(commentary: option).cadence().expectedTalkShare
            if share >= 1 {
                XCTAssertTrue(detail.contains("every song"), detail)
            } else {
                XCTAssertTrue(detail.contains("\(Int((share * 100).rounded()))%"), detail)
                XCTAssertTrue(detail.contains("never two in a row"), detail)
                XCTAssertFalse(detail.lowercased().contains("every song"), detail)
            }
        }
        XCTAssertEqual(T.detail(CommentaryFrequency.off, current: .rare), "Music only. The DJ doesn't talk between songs.")
    }

    func testPersonalityCopyNeverPromisesAVoice() {
        for option in T.personalityOptions.compactMap({ $0 }) {
            XCTAssertTrue(T.detail(option, current: .warm).contains("Same voice"))
        }
        XCTAssertTrue(T.voiceNote.contains("Tune"))
    }

    func testAccessibilityIdSuffixes() {
        XCTAssertEqual(T.personalityOptions.map(T.idSuffix), ["keep", "warm", "upbeat", "laidBack", "minimal"])
        XCTAssertEqual(T.talkOptions.map(T.idSuffix), ["keep", "off", "rare", "occasional", "frequent", "chatty"])
    }
}
