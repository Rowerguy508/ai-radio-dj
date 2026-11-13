import XCTest
@testable import AeroDJCore

/// Book pose places the player on the leading side of a vertical division and keeps
/// every control column off that band. The hinge angle is not an input.
final class FoldAwarenessTests: XCTestCase {
    private let artMin = 140.0
    private let artMax = 420.0
    private let width = 640.0
    private let height = 820.0

    func testNoDivisionKeepsTheCentredGutter() {
        let decision = resolve(divisions: [])
        XCTAssertFalse(decision.isBookPose)
        XCTAssertEqual(decision.metrics, ordinary(width: width, height: height))
    }

    func testACentredBookFoldMatchesTodaysGutter() {
        let fold = vertical(minX: width / 2 - FoldedColumnLayout.duoFoldGutter / 2,
                            width: FoldedColumnLayout.duoFoldGutter, height: height)
        let decision = resolve(divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        XCTAssertEqual(decision.metrics, ordinary(width: width, height: height))
        assertClear(decision, of: fold, containerWidth: width)
        XCTAssertGreaterThanOrEqual(decision.metrics.barWidth, StudioLayoutMetrics.touchTargetMin)
        XCTAssertGreaterThanOrEqual(decision.metrics.contentWidth, StudioLayoutMetrics.touchTargetMin)
        XCTAssertGreaterThanOrEqual(decision.metrics.leftWidth, StudioLayoutMetrics.touchTargetMin)
    }

    func testTheNarrowDuoKeepsTheSameCentredFrames() {
        let fold = vertical(minX: 250 - 14, width: 28, height: height)
        let decision = resolve(width: 500, divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        XCTAssertEqual(decision.metrics, ordinary(width: 500, height: height))
        assertClear(decision, of: fold, containerWidth: 500)
    }

    func testAnOffCentreFoldMovesBothColumnsOffIt() {
        let fold = vertical(minX: 200, width: 48, height: height)
        let decision = resolve(divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        let metrics = decision.metrics
        XCTAssertEqual(metrics.edgeInset + metrics.leftWidth, fold.minX, accuracy: 0.001)
        XCTAssertEqual(metrics.contentMinX, fold.maxX, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(metrics.barWidth, StudioLayoutMetrics.touchTargetMin)
        XCTAssertGreaterThanOrEqual(metrics.contentWidth, StudioLayoutMetrics.touchTargetMin)
        XCTAssertGreaterThanOrEqual(metrics.leftWidth, StudioLayoutMetrics.touchTargetMin)
        XCTAssertEqual(metrics.edgeInset * 2 + metrics.leftWidth + metrics.foldGutter
                       + metrics.contentWidth + metrics.barWidth, width, accuracy: 0.001)
        assertClear(decision, of: fold, containerWidth: width)
        XCTAssertNotEqual(metrics, ordinary(width: width, height: height))
    }

    func testTheAngleDoesNotMoveTheColumns() {
        let fold = vertical(minX: 200, width: 48, height: height)
        let shallow = resolve(angle: 20, divisions: [fold])
        let steep = resolve(angle: 160, divisions: [fold])
        XCTAssertEqual(shallow, steep)
    }

    func testAMissingHingeStillClearsAnActiveFold() {
        let fold = vertical(minX: 200, width: 48, height: height)
        let decision = resolve(status: nil, divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        assertClear(decision, of: fold, containerWidth: width)
    }

    func testFullyOpenAndClosedKeepTheOrdinaryLayout() {
        let fold = vertical(minX: 200, width: 48, height: height)
        for status in [FoldAwareness.HingeStatus.fullyOpen, .closed] {
            let decision = resolve(status: status, divisions: [fold])
            XCTAssertFalse(decision.isBookPose, "\(status)")
            XCTAssertEqual(decision.metrics, ordinary(width: width, height: height))
        }
    }

    func testAHorizontalDivisionIsNotBookPose() {
        let laptop = FoldAwareness.Division(minX: 0, minY: 400, width: width, height: 32, isActive: true)
        let decision = resolve(divisions: [laptop])
        XCTAssertFalse(decision.isBookPose)
        XCTAssertEqual(decision.metrics, ordinary(width: width, height: height))
    }

    func testAnInactiveVerticalDivisionIsNotBookPose() {
        var fold = vertical(minX: 200, width: 48, height: height)
        fold.isActive = false
        let decision = resolve(divisions: [fold])
        XCTAssertFalse(decision.isBookPose)
    }

    func testAShortVerticalRegionIsNotTheFold() {
        let chip = vertical(minX: 300, width: 20, height: 200)
        let decision = resolve(divisions: [chip])
        XCTAssertFalse(decision.isBookPose)
    }

    func testTheTallerVerticalDivisionWins() {
        let short = vertical(minX: 80, width: 20, height: height * 0.6)
        let fold = vertical(minX: 300, width: 36, height: height)
        let laptop = FoldAwareness.Division(minX: 0, minY: 400, width: width, height: 24, isActive: true)
        let decision = resolve(divisions: [laptop, short, fold])
        XCTAssertTrue(decision.isBookPose)
        XCTAssertEqual(decision.metrics.contentMinX, fold.maxX, accuracy: 0.001)
        assertClear(decision, of: fold, containerWidth: width)
    }

    func testAFoldAgainstTheTrailingEdgeLeavesNoUndersizedControl() {
        let fold = vertical(minX: 560, width: 40, height: height)
        let decision = resolve(divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        XCTAssertEqual(decision.metrics.contentWidth, 0)
        XCTAssertEqual(decision.metrics.barWidth, 0)
        XCTAssertGreaterThanOrEqual(decision.metrics.leftWidth, StudioLayoutMetrics.touchTargetMin)
        assertClear(decision, of: fold, containerWidth: width)
    }

    func testAFoldAgainstTheLeadingEdgePutsTheControlsOnTheTrailingSide() {
        let fold = vertical(minX: 4, width: 30, height: height)
        let decision = resolve(divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        XCTAssertEqual(decision.metrics.leftWidth, 0, "the leading sliver cannot hold a 44 pt control")
        XCTAssertGreaterThanOrEqual(decision.metrics.contentMinX, fold.maxX)
        XCTAssertGreaterThanOrEqual(decision.metrics.barWidth, StudioLayoutMetrics.touchTargetMin)
        XCTAssertGreaterThanOrEqual(decision.metrics.contentWidth, StudioLayoutMetrics.touchTargetMin)
        assertClear(decision, of: fold, containerWidth: width)
    }

    func testAControlSideJustWideEnoughForATargetKeepsTheBar() {
        // inner end is 624. A fold that ends at 574 leaves 50 pt: at least 44, under the 56 pt bar.
        let fold = vertical(minX: 534, width: 40, height: height)
        let decision = resolve(divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        XCTAssertEqual(decision.metrics.contentWidth, 0)
        XCTAssertGreaterThanOrEqual(decision.metrics.barWidth, StudioLayoutMetrics.touchTargetMin)
        XCTAssertLessThan(decision.metrics.barWidth, FoldedColumnLayout.duoBarWidth)
        XCTAssertEqual(decision.metrics.contentMinX, fold.maxX, accuracy: 0.001)
        assertClear(decision, of: fold, containerWidth: width)
    }

    func testAControlSideBetweenTheBarAndASecondTargetKeepsTheBar() {
        // inner end is 624. A fold that ends at 560 leaves 64 pt, enough for the 56 pt bar
        // and not enough for another 44 pt column.
        let fold = vertical(minX: 520, width: 40, height: height)
        let decision = resolve(divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        XCTAssertEqual(decision.metrics.barWidth, FoldedColumnLayout.duoBarWidth)
        XCTAssertEqual(decision.metrics.contentWidth, 0)
        XCTAssertGreaterThanOrEqual(decision.metrics.contentMinX, fold.maxX)
        assertClear(decision, of: fold, containerWidth: width)
    }

    func testPhonePortraitAndLandscapeIgnoreTheFold() {
        let portraitFold = vertical(minX: 180, width: 30, height: 844)
        let portrait = resolve(width: 390, height: 844, divisions: [portraitFold])
        XCTAssertFalse(portrait.isBookPose)
        XCTAssertEqual(portrait.metrics, ordinary(width: 390, height: 844))

        let landscapeFold = vertical(minX: 400, width: 28, height: 390)
        let landscape = resolve(width: 844, height: 390, divisions: [landscapeFold])
        XCTAssertFalse(landscape.isBookPose)
        XCTAssertEqual(landscape.metrics, ordinary(width: 844, height: 390))
    }

    func testANonFiniteContainerKeepsTheOrdinaryCall() {
        let fold = vertical(minX: 200, width: 48, height: height)
        let decision = resolve(width: .nan, divisions: [fold])
        XCTAssertFalse(decision.isBookPose)
        XCTAssertEqual(decision.metrics, ordinary(width: .nan, height: height))
    }

    func testAnUnknownStatusStillClearsTheFold() {
        let fold = vertical(minX: 200, width: 48, height: height)
        let decision = resolve(status: .unknown, divisions: [fold])
        XCTAssertTrue(decision.isBookPose)
        assertClear(decision, of: fold, containerWidth: width)
    }

    // MARK: - Helpers

    private func resolve(width: Double? = nil, height: Double? = nil,
                         status: FoldAwareness.HingeStatus? = .partiallyOpen,
                         angle: Double = 120,
                         divisions: [FoldAwareness.Division]) -> FoldAwareness.Decision {
        let containerWidth = width ?? self.width
        let containerHeight = height ?? self.height
        let hinge = status.map { FoldAwareness.HingeSample(status: $0, angleDegrees: angle) }
        return FoldAwareness.resolve(
            containerWidth: containerWidth, containerHeight: containerHeight,
            hinge: hinge, divisions: divisions, artMin: artMin, artMax: artMax)
    }

    private func ordinary(width: Double, height: Double) -> FoldedColumnLayout.DuoHorizontal {
        FoldedColumnLayout.duoHorizontal(containerWidth: width, containerHeight: height,
                                         artMin: artMin, artMax: artMax)
    }

    private func vertical(minX: Double, width: Double, height: Double) -> FoldAwareness.Division {
        FoldAwareness.Division(minX: minX, minY: 0, width: width, height: height, isActive: true)
    }

    /// The player column, when it has width, ends at or before the fold. The control
    /// columns, when they have width, start at or after the fold. Neither range crosses it.
    private func assertClear(_ decision: FoldAwareness.Decision, of fold: FoldAwareness.Division,
                             containerWidth: Double) {
        let metrics = decision.metrics
        XCTAssertEqual(metrics.edgeInset * 2 + metrics.leftWidth + metrics.foldGutter
                       + metrics.contentWidth + metrics.barWidth,
                       containerWidth, accuracy: 0.001)
        if metrics.leftWidth > 0 {
            XCTAssertLessThanOrEqual(metrics.edgeInset + metrics.leftWidth, fold.minX + 0.001)
            XCTAssertGreaterThanOrEqual(metrics.leftWidth, StudioLayoutMetrics.touchTargetMin)
        }
        if metrics.contentWidth + metrics.barWidth > 0 {
            XCTAssertGreaterThanOrEqual(metrics.contentMinX, fold.maxX - 0.001)
        }
        if metrics.barWidth > 0 {
            XCTAssertGreaterThanOrEqual(metrics.barWidth, StudioLayoutMetrics.touchTargetMin)
        }
        if metrics.contentWidth > 0 {
            XCTAssertGreaterThanOrEqual(metrics.contentWidth, StudioLayoutMetrics.touchTargetMin)
        }
        let playerMax = metrics.edgeInset + metrics.leftWidth
        let controlsMax = metrics.barMinX + metrics.barWidth
        XCTAssertFalse(rangesOverlap(metrics.edgeInset, playerMax, fold.minX, fold.maxX) && metrics.leftWidth > 0)
        XCTAssertFalse(rangesOverlap(metrics.contentMinX, controlsMax, fold.minX, fold.maxX)
                       && metrics.contentWidth + metrics.barWidth > 0)
    }

    private func rangesOverlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool {
        a1 > b0 + 0.001 && a0 < b1 - 0.001
    }
}
