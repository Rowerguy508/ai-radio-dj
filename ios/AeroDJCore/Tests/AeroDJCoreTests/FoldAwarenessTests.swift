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
    func testTheOpenDuoBookColumnIsExactly290AndFitsABalancedTransportRow() throws {
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

    // MARK: - #548 book pose: the collapsed column carries the closed Rail D (owner, Nov 17)

    /// The Studio landscape capture (820 x 640, fold 396…424, `RailDCaptureContainer.foldBand`)
    /// and the 640 x 820 centred fold: the column and the rail both sit inside the book span,
    /// off the fold, rail on the trailing side, 56 pt wide, 12 pt from the column.
    func testTheBookColumnCarriesTheClosedRailOffTheFold() throws {
        let frames: [(width: Double, height: Double, fold: FoldAwareness.Division)] = [
            (820, 640, vertical(minX: 396, width: 28, height: 640)),
            (640, 820, vertical(minX: 306, width: 28, height: 820)),
            (640, 820, vertical(minX: 200, width: 48, height: 820)),
            (640, 820, vertical(minX: 440, width: 48, height: 820)),
        ]
        for frame in frames {
            let label = "\(frame.width)x\(frame.height) fold \(frame.fold.minX)"
            let book = try XCTUnwrap(bookColumn(width: frame.width, height: frame.height, divisions: [frame.fold]), label)
            let split = try XCTUnwrap(FoldAwareness.bookRailColumn(book), label)
            XCTAssertEqual(split.railWidth, FoldedOuterLayout.closedRailWidth, label)
            XCTAssertEqual(split.railWidth, RailDLayout.railWidth, "the closed screen's rail")
            XCTAssertEqual(split.columnMinX, book.minX, accuracy: 0.001, label)
            XCTAssertEqual(split.railMaxX, book.maxX, accuracy: 0.001, "the rail closes the book span: \(label)")
            XCTAssertEqual(split.railMinX - split.columnMaxX, FoldAwareness.bookRailGap, accuracy: 0.001, label)
            XCTAssertGreaterThan(split.railMinX, split.columnMaxX, "rail trailing of the column: \(label)")
            XCTAssertLessThanOrEqual(split.artSide, split.columnWidth, label)
            for (minX, maxX) in [(split.columnMinX, split.columnMaxX), (split.railMinX, split.railMaxX)] {
                XCTAssertFalse(rangesOverlap(minX, maxX, frame.fold.minX, frame.fold.maxX), "on the fold: \(label)")
                XCTAssertGreaterThanOrEqual(minX, FoldedColumnLayout.duoEdgeInset - 0.001, label)
                XCTAssertLessThanOrEqual(maxX, frame.width - FoldedColumnLayout.duoEdgeInset + 0.001, label)
            }
        }
    }

    /// The book rail is the closed rail with no Collapse: every 44 pt plate and at least a
    /// 44 pt song-position track fit at the open Duo's heights, so the bar is in the rail.
    func testTheBookRailFitsEveryPlateAndTheSongPositionBar() {
        let slots = RailDLayout.slots(hasCollapse: false, showsTransport: true, showsScrubber: true)
        XCTAssertEqual(slots, [.more, .playPause, .skip, .queue, .sleepTimer, .scrubber, .liveDot])
        XCTAssertGreaterThanOrEqual(RailDLayout.controlSize, StudioLayoutMetrics.touchTargetMin)
        XCTAssertGreaterThanOrEqual(RailDLayout.minTrackLength, StudioLayoutMetrics.touchTargetMin)
        for height in [640.0, 820.0] {
            let rail = RailDLayout.closedRailHeight(containerHeight: height)
            XCTAssertTrue(RailDLayout.fits(railHeight: rail, slots: slots), "\(height)")
            XCTAssertGreaterThanOrEqual(RailDLayout.trackLength(railHeight: rail, slots: slots),
                                        RailDLayout.minTrackLength, "\(height)")
        }
    }

    /// At the 260 pt minimum side the content column keeps 260 - 56 - 12 = 192 pt. A span with
    /// no room for a column beside the rail gives no split (the caller keeps the centred column).
    func testTheBookRailColumnAtTheMinimumAndBelow() throws {
        let atMin = vertical(minX: 580 / 2 - 14, width: 28, height: height)
        let book = try XCTUnwrap(bookColumn(width: 580, divisions: [atMin]))
        let split = try XCTUnwrap(FoldAwareness.bookRailColumn(book))
        XCTAssertEqual(split.columnWidth, 192, accuracy: 0.001)

        let gap = FoldAwareness.bookRailGap
        let rail = FoldedOuterLayout.closedRailWidth
        XCTAssertNil(FoldAwareness.bookRailColumn(.init(minX: 16, width: rail + gap, artSide: 100)))
        let sliver = try XCTUnwrap(FoldAwareness.bookRailColumn(.init(minX: 16, width: rail + gap + 1, artSide: 100)))
        XCTAssertEqual(sliver.columnWidth, 1, accuracy: 0.001)
        XCTAssertEqual(sliver.artSide, 1, accuracy: 0.001, "the art is clamped to the column")
        XCTAssertNil(FoldAwareness.bookRailColumn(.init(minX: 16, width: .nan, artSide: 100)))
    }

    /// Full open (flat, `railDLandscapeCentred`) and no fold reading: no book column. #460: the
    /// collapsed Duo then takes `flatRailColumn` (below), not integration's pinned column.
    func testOutsideBookPoseThereIsNoBookRail() {
        let band = vertical(minX: 396, width: 28, height: 640)
        XCTAssertNil(bookColumn(width: 820, height: 640, status: .fullyOpen, divisions: []))
        XCTAssertNil(bookColumn(width: 820, height: 640, status: .fullyOpen, divisions: [band]))
        XCTAssertNil(bookColumn(width: 820, height: 640, status: .partiallyOpen, divisions: []))
    }

    // MARK: - #460 flat open Duo: the collapsed column keeps Rail D on the right (-Nova)

    /// The open Duo's collapsed frames outside book pose: upright (640 x 820, and its reader
    /// under the navigation bar), sideways (820 x 640 and 820 x 576), the owner's device window
    /// (951 x 669), and the sidebar-open details (350 pt upright beside the 290 pt sidebar,
    /// 500 pt sideways beside the 320 pt one). The pinned column's width is centred, split into
    /// the content column and the 56 pt closed rail on its trailing side, inside one
    /// `duoEdgeInset` of both edges, and the rail fits every plate and the song-position bar.
    func testTheFlatCollapsedColumnCarriesRailDOnTheRight() throws {
        let frames: [(width: Double, height: Double)] = [
            (640, 820), (640, 764), (820, 640), (820, 576), (951, 669), (350, 764), (500, 576),
        ]
        let slots = RailDLayout.slots(hasCollapse: false, showsTransport: true, showsScrubber: true)
        for frame in frames {
            let label = "\(frame.width)x\(frame.height)"
            let m = centredColumn(width: frame.width, height: frame.height)
            let split = try XCTUnwrap(FoldAwareness.flatRailColumn(containerWidth: frame.width,
                                                                   containerHeight: frame.height,
                                                                   column: m.column, artSide: m.artSide), label)
            XCTAssertEqual(split.railWidth, RailDLayout.railWidth, "the closed screen's rail: \(label)")
            XCTAssertEqual(split.railMinX - split.columnMaxX, FoldAwareness.bookRailGap, accuracy: 0.001, label)
            XCTAssertGreaterThan(split.railMinX, split.columnMaxX, "rail trailing of the column: \(label)")
            XCTAssertGreaterThan(split.railMinX + split.railWidth / 2, frame.width / 2, "rail on the right: \(label)")
            XCTAssertEqual(split.columnMinX, frame.width - split.railMaxX, accuracy: 0.001, "centred: \(label)")
            XCTAssertGreaterThanOrEqual(split.columnMinX, FoldedColumnLayout.duoEdgeInset - 0.001, label)
            XCTAssertLessThanOrEqual(split.railMaxX, frame.width - FoldedColumnLayout.duoEdgeInset + 0.001, label)
            XCTAssertGreaterThanOrEqual(split.columnWidth, StudioLayoutMetrics.touchTargetMin, label)
            XCTAssertLessThanOrEqual(split.artSide, split.columnWidth, label)
            XCTAssertLessThanOrEqual(split.columnWidth + FoldAwareness.bookRailGap + split.railWidth,
                                     m.column + 0.001, "never wider than the pinned column: \(label)")
            let rail = RailDLayout.closedRailHeight(containerHeight: frame.height)
            XCTAssertTrue(RailDLayout.fits(railHeight: rail, slots: slots), label)
        }
    }

    /// Sizes only. Narrower than `railColumnMinWidth`, or longer than `openDuoMaxSide` on either
    /// side (every full-screen iPad), keeps the pinned column; so does a bad measurement.
    func testTheFlatRailColumnIsOnlyForOpenDuoSizes() {
        func flat(_ width: Double, _ height: Double, column: Double = 360) -> FoldAwareness.BookRailColumn? {
            FoldAwareness.flatRailColumn(containerWidth: width, containerHeight: height, column: column, artSide: 200)
        }
        for (width, height) in [(1024.0, 1366.0), (1366, 1024), (1180, 820), (820, 1180), (1133, 744), (744, 1133)] {
            XCTAssertNil(flat(width, height), "full-screen iPad \(width)x\(height)")
        }
        XCTAssertNotNil(flat(FoldedColumnLayout.railColumnMinWidth, 764))
        XCTAssertNil(flat(FoldedColumnLayout.railColumnMinWidth - 0.5, 764))
        XCTAssertNotNil(flat(640, FoldedColumnLayout.openDuoMaxSide))
        XCTAssertNil(flat(640, FoldedColumnLayout.openDuoMaxSide + 0.5))
        XCTAssertNil(flat(.nan, 820))
        XCTAssertNil(flat(640, .infinity))
        XCTAssertNil(flat(640, 820, column: 0))
        XCTAssertNil(flat(640, 0))
        XCTAssertNil(flat(640, 820, column: FoldedOuterLayout.closedRailWidth + FoldAwareness.bookRailGap),
                     "no room for a column beside the rail")
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
