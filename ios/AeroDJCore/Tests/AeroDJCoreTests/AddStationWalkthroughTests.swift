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

    func testStepsAreNumberedOneToFiveInOrder() {
        XCTAssertEqual(AddStationStep.allCases.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(AddStationStep.kind.next, .picks)
        XCTAssertNil(AddStationStep.review.next)
        XCTAssertNil(AddStationStep.kind.previous)
        XCTAssertEqual(AddStationStep.picks.accessibilityLabel, "Step 2 of 5, Pick")
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
