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

    // MARK: - #507 collapsed rail: the centred column moves off the fold

    func testTheCollapsedColumnAvoidsACentredFoldOnTheOpenDuo() throws {
        for gutter in [FoldedColumnLayout.duoFoldGutter, 40.0] {
            let fold = vertical(minX: width / 2 - gutter / 2, width: gutter, height: height)
            let today = centredColumn(width: width, height: height)
            // Today's column, centred on the container, crosses the crease.
            let todayMinX = (width - today.column) / 2
            XCTAssertTrue(rangesOverlap(todayMinX, todayMinX + today.column, fold.minX, fold.maxX), "\(gutter)")
            let column = try XCTUnwrap(bookColumn(divisions: [fold]), "\(gutter)")
            assertColumnClear(column, of: fold, containerWidth: width)
            XCTAssertLessThanOrEqual(column.maxX, fold.minX + 0.001, "a symmetric fold keeps the leading side")
            XCTAssertLessThanOrEqual(column.width, today.column)
            XCTAssertLessThanOrEqual(column.artSide, column.width)
        }
    }

    /// 640 x 820 with the 28 pt centred fold: the leading side is 640 / 2 - 14 - 16 = 290 pt.
    /// The column takes all of it, and the transport row still fits with 44 pt targets.
    /// `TransportRow` (app target) draws Play at 68 and Skip at 52, with a 52 pt balancing
    /// slot when there is no Tune; those literals are the AeroDJCore constants
    /// `FoldedOuterLayout.playSide` / `skipSide` (pinned by LiquidGlassTransportTests).
    func testTheOpenDuoColumnIsAbout290AndHoldsTheTransportTargets() throws {
        let fold = vertical(minX: width / 2 - 14, width: 28, height: height)
        let column = try XCTUnwrap(bookColumn(divisions: [fold]))
        XCTAssertEqual(column.width, 290, accuracy: 0.001)
        XCTAssertEqual(column.minX, FoldedColumnLayout.duoEdgeInset, accuracy: 0.001)
        assertColumnClear(column, of: fold, containerWidth: width)

        let play = FoldedOuterLayout.playSide
        let skip = FoldedOuterLayout.skipSide
        XCTAssertGreaterThanOrEqual(play, StudioLayoutMetrics.touchTargetMin)
        XCTAssertGreaterThanOrEqual(skip, StudioLayoutMetrics.touchTargetMin)
        // Balanced row (the collapsed column passes `balancesSides: true`): slot, Play, Skip.
        let balancedRow = skip + play + skip
        XCTAssertGreaterThanOrEqual(column.width, balancedRow)
        XCTAssertGreaterThanOrEqual(column.width, FoldAwareness.bookColumnMinSideWidth)
    }

    /// The narrow 500 x 820 frame: a centred fold leaves 220 or 214 pt a side, under the
    /// minimum, so the column stays centred exactly as today.
    func testTheNarrowFrameKeepsTheCentredColumn() {
        for gutter in [28.0, 40.0] {
            let fold = vertical(minX: 250 - gutter / 2, width: gutter, height: height)
            XCTAssertLessThan((500 - 2 * FoldedColumnLayout.duoEdgeInset - gutter) / 2,
                              FoldAwareness.bookColumnMinSideWidth)
            XCTAssertNil(bookColumn(width: 500, divisions: [fold]), "\(gutter)")
        }
    }

    /// A centred 28 pt fold leaves (W - 32 - 28) / 2 a side: 580 pt gives exactly 260, 579 gives 259.5.
    func testTheMinimumSideWidthBoundary() throws {
        XCTAssertEqual(FoldAwareness.bookColumnMinSideWidth, 260)
        let atMin = vertical(minX: 580 / 2 - 14, width: 28, height: height)
        let moved = try XCTUnwrap(bookColumn(width: 580, divisions: [atMin]))
        XCTAssertEqual(moved.width, 260, accuracy: 0.001)
        XCTAssertEqual(moved.minX, FoldedColumnLayout.duoEdgeInset, accuracy: 0.001, "a tie keeps the leading side")
        assertColumnClear(moved, of: atMin, containerWidth: 580)

        let under = vertical(minX: 579 / 2 - 14, width: 28, height: height)
        XCTAssertNil(bookColumn(width: 579, divisions: [under]))
    }

    func testTheCollapsedColumnTakesTheWiderSideOfAnOffCentreFold() throws {
        let leadingFold = vertical(minX: 200, width: 48, height: height)
        let trailing = try XCTUnwrap(bookColumn(divisions: [leadingFold]))
        XCTAssertGreaterThanOrEqual(trailing.minX, leadingFold.maxX - 0.001)
        assertColumnClear(trailing, of: leadingFold, containerWidth: width)

        let trailingFold = vertical(minX: 440, width: 48, height: height)
        let leading = try XCTUnwrap(bookColumn(divisions: [trailingFold]))
        XCTAssertLessThanOrEqual(leading.maxX, trailingFold.minX + 0.001)
        assertColumnClear(leading, of: trailingFold, containerWidth: width)
        // The preferred column fits the wide side, so it keeps its width there.
        XCTAssertEqual(leading.width, centredColumn(width: width, height: height).column, accuracy: 0.001)
    }

    func testTheCollapsedColumnIgnoresTheAngle() {
        let fold = vertical(minX: 306, width: 28, height: height)
        XCTAssertEqual(bookColumn(angle: 20, divisions: [fold]), bookColumn(angle: 160, divisions: [fold]))
    }

    func testNoFoldLeavesTheCollapsedColumnUnchanged() {
        let fold = vertical(minX: 306, width: 28, height: height)
        var inactive = fold
        inactive.isActive = false
        let laptop = FoldAwareness.Division(minX: 0, minY: 400, width: width, height: 32, isActive: true)
        XCTAssertNil(bookColumn(divisions: []))
        XCTAssertNil(bookColumn(divisions: [inactive]))
        XCTAssertNil(bookColumn(divisions: [laptop]))
        XCTAssertNil(bookColumn(divisions: [vertical(minX: 300, width: 20, height: 200)]))
        for status in [FoldAwareness.HingeStatus.fullyOpen, .closed] {
            XCTAssertNil(bookColumn(status: status, divisions: [fold]), "\(status)")
        }
        XCTAssertNotNil(bookColumn(status: nil, divisions: [fold]), "the region alone is the signal")
        XCTAssertNotNil(bookColumn(status: .unknown, divisions: [fold]))
        // Phone portrait, iPhone landscape (the centred-column placement) and a bad size.
        XCTAssertNil(bookColumn(width: 390, height: 844, divisions: [vertical(minX: 180, width: 30, height: 844)]))
        XCTAssertNil(bookColumn(width: 844, height: 390, divisions: [vertical(minX: 400, width: 28, height: 390)]))
        XCTAssertNil(bookColumn(width: .nan, divisions: [fold]))
    }

    private func centredColumn(width: Double, height: Double) -> (artSide: Double, column: Double) {
        FoldedColumnLayout.metrics(containerWidth: width, containerHeight: height, reserveBelowArt: 380,
                                   artMin: artMin, artMax: artMax)
    }

    private func bookColumn(width: Double? = nil, height: Double? = nil,
                            status: FoldAwareness.HingeStatus? = .partiallyOpen, angle: Double = 120,
                            divisions: [FoldAwareness.Division]) -> FoldAwareness.BookColumn? {
        let containerWidth = width ?? self.width
        let containerHeight = height ?? self.height
        let today = centredColumn(width: containerWidth.isFinite ? containerWidth : 640, height: containerHeight)
        return FoldAwareness.bookColumn(
            containerWidth: containerWidth, containerHeight: containerHeight,
            hinge: status.map { FoldAwareness.HingeSample(status: $0, angleDegrees: angle) },
            divisions: divisions, column: today.column, artSide: today.artSide)
    }

    /// The whole column (art, transport, scrubber, toolbar) is on one side of the fold and
    /// inside the edge insets.
    private func assertColumnClear(_ column: FoldAwareness.BookColumn, of fold: FoldAwareness.Division,
                                   containerWidth: Double, line: UInt = #line) {
        XCTAssertFalse(rangesOverlap(column.minX, column.maxX, fold.minX, fold.maxX), line: line)
        XCTAssertGreaterThanOrEqual(column.minX, FoldedColumnLayout.duoEdgeInset - 0.001, line: line)
        XCTAssertLessThanOrEqual(column.maxX, containerWidth - FoldedColumnLayout.duoEdgeInset + 0.001, line: line)
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
