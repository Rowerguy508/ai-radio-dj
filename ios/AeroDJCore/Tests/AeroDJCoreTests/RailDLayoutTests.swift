import XCTest
@testable import AeroDJCore

/// Mockup D (owner: "Yes, build it"): the layout math for the full trailing rail, its vertical
/// song-position bar, the closed screen and the open Duo arrangements. -Nova
final class RailDLayoutTests: XCTestCase {

    // MARK: Rail

    func testRailIsFiftySixPointsAndEveryPlateIsFortyFour() {
        XCTAssertEqual(RailDLayout.railWidth, 56)
        XCTAssertEqual(RailDLayout.trailingInset, 8)
        XCTAssertEqual(RailDLayout.railCornerRadius, 28)
        XCTAssertGreaterThanOrEqual(DuoRailLayout.controlSize, 44)
        XCTAssertGreaterThanOrEqual(RailDLayout.thumbHitSide, 44)
        XCTAssertGreaterThanOrEqual(RailDLayout.minTrackLength, 44)
        XCTAssertLessThanOrEqual(RailDLayout.scrubberWidth, RailDLayout.railWidth)
    }

    func testClosedSlotsAreMoreTransportQueueSleepScrubberLiveDot() {
        XCTAssertEqual(RailDLayout.slots(hasCollapse: false, showsTransport: true, showsScrubber: true),
                       [.more, .playPause, .skip, .queue, .sleepTimer, .scrubber, .liveDot])
        // The open rail keeps Atlas's Collapse chevron on top.
        XCTAssertEqual(RailDLayout.slots(hasCollapse: true, showsTransport: true, showsScrubber: true).first, .collapse)
        // No track: no transport, no bar; Queue, Sleep and the dot stay.
        XCTAssertEqual(RailDLayout.slots(hasCollapse: false, showsTransport: false, showsScrubber: false),
                       [.more, .queue, .sleepTimer, .liveDot])
    }

    func testClosedPhoneRailLeavesALongTrack() {
        // 390 × 844 iPhone: reader 763, rail glass 747 (8 pt top and bottom), as the mock.
        let rail = RailDLayout.closedRailHeight(containerHeight: 763)
        XCTAssertEqual(rail, 747)
        let slots = RailDLayout.slots(hasCollapse: false, showsTransport: true, showsScrubber: true)
        XCTAssertTrue(RailDLayout.fits(railHeight: rail, slots: slots))
        XCTAssertGreaterThan(RailDLayout.trackLength(railHeight: rail, slots: slots), 300)
        XCTAssertEqual(RailDLayout.trackLength(railHeight: rail, slots: slots),
                       rail - RailDLayout.fixedHeight(slots), accuracy: 0.001)
    }

    func testOpenRailsFitEveryCapturedFrame() {
        let open = RailDLayout.slots(hasCollapse: true, showsTransport: true, showsScrubber: true)
        // Portrait 820 tall less 24 / 20 safe areas, landscape 566, and the sidebar detail.
        for height in [776.0, 566, 520] {
            XCTAssertTrue(RailDLayout.fits(railHeight: height - 16, slots: open), "\(height)")
        }
    }

    func testAShortRailReportsItDoesNotFitInsteadOfShrinkingAPlate() {
        let slots = RailDLayout.slots(hasCollapse: true, showsTransport: true, showsScrubber: true)
        XCTAssertFalse(RailDLayout.fits(railHeight: RailDLayout.fixedHeight(slots) + 43, slots: slots))
        XCTAssertTrue(RailDLayout.fits(railHeight: RailDLayout.fixedHeight(slots) + 44, slots: slots))
        XCTAssertEqual(RailDLayout.trackLength(railHeight: 10, slots: slots), 0)
        XCTAssertEqual(RailDLayout.trackLength(railHeight: .nan, slots: slots), 0)
        XCTAssertFalse(RailDLayout.fits(railHeight: .infinity, slots: slots))
    }

    // MARK: Vertical bar

    func testDraggingDownSeeksForward() {
        let chrome = RailDLayout.scrubberChrome
        let element = 400 + chrome
        let top = RailDLayout.timeLabelHeight + RailDLayout.timeGap
        XCTAssertEqual(RailDLayout.position(atElementY: top, elementHeight: element, duration: 200), 0)
        XCTAssertEqual(RailDLayout.position(atElementY: top + 200, elementHeight: element, duration: 200), 100, accuracy: 0.001)
        XCTAssertEqual(RailDLayout.position(atElementY: top + 400, elementHeight: element, duration: 200), 200, accuracy: 0.001)
        // Above the track (the elapsed label) clamps to 0; below it clamps to the end.
        XCTAssertEqual(RailDLayout.position(atElementY: 0, elementHeight: element, duration: 200), 0)
        XCTAssertEqual(RailDLayout.position(atElementY: element, elementHeight: element, duration: 200), 200)
        // No room for a track: nothing to seek to.
        XCTAssertEqual(RailDLayout.position(atElementY: 10, elementHeight: chrome, duration: 200), 0)
    }

    func testThumbOffsetClamps() {
        XCTAssertEqual(RailDLayout.thumbOffset(fraction: 0.5, trackLength: 300), 150)
        XCTAssertEqual(RailDLayout.thumbOffset(fraction: -1, trackLength: 300), 0)
        XCTAssertEqual(RailDLayout.thumbOffset(fraction: 2, trackLength: 300), 300)
        XCTAssertEqual(RailDLayout.thumbOffset(fraction: .nan, trackLength: 300), 0)
        XCTAssertEqual(RailDLayout.thumbOffset(fraction: 0.5, trackLength: 0), 0)
    }

    func testDragIsClaimedOnlyAfterAShortMostlyVerticalMove() {
        XCTAssertEqual(RailDLayout.dragClaimDistance, 10)
        XCTAssertFalse(RailDLayout.claimsDrag(translationX: 0, translationY: 9))
        XCTAssertTrue(RailDLayout.claimsDrag(translationX: 0, translationY: 10))
        XCTAssertTrue(RailDLayout.claimsDrag(translationX: 4, translationY: -12))
        XCTAssertFalse(RailDLayout.claimsDrag(translationX: 30, translationY: 12), "a sideways swipe")
        XCTAssertFalse(RailDLayout.claimsDrag(translationX: .nan, translationY: 40))
    }

    // MARK: Closed screen

    func testClosedPhoneArtAndType() {
        XCTAssertEqual(RailDLayout.closedTitlePointSize, 40)
        XCTAssertEqual(RailDLayout.closedArtistPointSize, 17)
        XCTAssertEqual(RailDLayout.titleGrowth, 8)
        XCTAssertEqual(RailDLayout.closedArtReserveBelow, FoldedOuterLayout.artReserveBelowWithRail - 40 + 8)
        // 390 × 763: width-limited at 278, the mock's art.
        XCTAssertEqual(RailDLayout.closedArtSide(containerWidth: 390, containerHeight: 763, minSide: 140, maxSide: 420), 278)
        // A short container is height-limited and gains the scrubber row less the bigger type.
        let short = RailDLayout.closedArtSide(containerWidth: 390, containerHeight: 400, minSide: 140, maxSide: 420)
        let before = FoldedOuterLayout.artSideBesideRail(containerWidth: 390, containerHeight: 400, minSide: 140, maxSide: 420)
        XCTAssertEqual(short, before + 32)
        // The floor wins.
        XCTAssertEqual(RailDLayout.closedArtSide(containerWidth: 200, containerHeight: 200, minSide: 140, maxSide: 420), 140)
    }

    func testClosedMenuLeavesQueueToTheRail() {
        XCTAssertEqual(FoldedOuterLayout.closedMoreItems(showsWorkspaceButtons: true, canRate: true, queueOnRail: true),
                       [.tune, .rating])
        XCTAssertEqual(FoldedOuterLayout.closedMoreItems(showsWorkspaceButtons: true, canRate: true),
                       [.queue, .tune, .rating], "default unchanged")
    }

    func testTransportHeightOnlyFeedsTheArtReserve() {
        // Kept at 80: nothing draws it, but the closed art reserve still subtracts it.
        XCTAssertEqual(FoldedOuterLayout.transportHeight, 80)
        XCTAssertEqual(FoldedOuterLayout.artReserveBelowWithRail,
                       FoldedOuterLayout.artReserveBelow - (FoldedOuterLayout.transportHeight + 8))
        XCTAssertLessThanOrEqual(FoldedOuterLayout.playOuterSide, FoldedOuterLayout.transportHeight)
    }

    // MARK: Open Duo

    private let fold = FoldAwareness.Division(minX: 396, minY: 0, width: 28, height: 640, isActive: true)

    func testArrangementPortraitSpreadCentred() {
        XCTAssertEqual(RailDLayout.openArrangement(containerWidth: 640, containerHeight: 776, hinge: nil, divisions: []), .portrait)
        XCTAssertEqual(RailDLayout.openArrangement(containerWidth: 600, containerHeight: 600, hinge: nil, divisions: []), .portrait)
        // Unknown hinge, no division (this SDK): the conservative L1 spread.
        XCTAssertEqual(RailDLayout.openArrangement(containerWidth: 820, containerHeight: 566, hinge: nil, divisions: []), .spread)
        XCTAssertEqual(RailDLayout.openArrangement(
            containerWidth: 820, containerHeight: 566,
            hinge: .init(status: .partiallyOpen, angleDegrees: 150), divisions: [fold]), .spread)
        XCTAssertEqual(RailDLayout.openArrangement(
            containerWidth: 820, containerHeight: 566,
            hinge: .init(status: .unknown, angleDegrees: 0), divisions: []), .spread)
        // Known flat: L2.
        XCTAssertEqual(RailDLayout.openArrangement(
            containerWidth: 820, containerHeight: 566,
            hinge: .init(status: .fullyOpen, angleDegrees: 180), divisions: []), .centred)
        var inactive = fold
        inactive.isActive = false
        XCTAssertEqual(RailDLayout.openArrangement(containerWidth: 820, containerHeight: 640, hinge: nil, divisions: [inactive]), .centred)
        // A laptop crease is not a book fold.
        let crease = FoldAwareness.Division(minX: 0, minY: 300, width: 820, height: 28, isActive: false)
        XCTAssertEqual(RailDLayout.openArrangement(containerWidth: 820, containerHeight: 640, hinge: nil, divisions: [crease]), .spread)
        XCTAssertEqual(RailDLayout.openArrangement(containerWidth: .nan, containerHeight: 640, hinge: nil, divisions: []), .portrait)
    }

    func testSpreadArtIsTheMocksThreeFortyEight() {
        // 820 × 566 reader: left half 380 (16…396), art 380 − 32 = 348.
        XCTAssertEqual(RailDLayout.spreadArtSide(leftWidth: 380, containerHeight: 566, minSide: 140, maxSide: 420), 348)
        // A short window is height-limited.
        XCTAssertEqual(RailDLayout.spreadArtSide(leftWidth: 380, containerHeight: 400, minSide: 140, maxSide: 420), 400 - 52 - 48)
        XCTAssertEqual(RailDLayout.spreadArtSide(leftWidth: 100, containerHeight: 100, minSide: 140, maxSide: 420), 140)
    }

    func testSpreadTypeStartsAfterTheFoldAndNothingTouchesIt() {
        let metrics = FoldedColumnLayout.duoHorizontal(containerWidth: 820, containerHeight: 566,
                                                       artMin: 140, artMax: 420)
        let foldMinX = metrics.edgeInset + metrics.leftWidth
        let foldMaxX = foldMinX + metrics.foldGutter
        XCTAssertEqual(foldMinX, 396)
        XCTAssertEqual(foldMaxX, 424)
        XCTAssertEqual(foldMaxX + RailDLayout.spreadTrailingInset, 448, "the mock's type x")
        // The art, centred in the left half, ends before the fold; the type starts after it.
        let art = RailDLayout.spreadArtSide(leftWidth: metrics.leftWidth, containerHeight: 566, minSide: 140, maxSide: 420)
        let artMinX = metrics.edgeInset + (metrics.leftWidth - art) / 2
        XCTAssertFalse(RailDLayout.intersectsFold(minX: artMinX, maxX: artMinX + art, foldMinX: foldMinX, foldMaxX: foldMaxX))
        XCTAssertFalse(RailDLayout.intersectsFold(minX: 448, maxX: 700, foldMinX: foldMinX, foldMaxX: foldMaxX))
        XCTAssertTrue(RailDLayout.intersectsFold(minX: 380, maxX: 400, foldMinX: foldMinX, foldMaxX: foldMaxX))
        XCTAssertFalse(RailDLayout.intersectsFold(minX: 424, maxX: 470, foldMinX: foldMinX, foldMaxX: foldMaxX), "touching is clear")
    }

    func testCentredArt() {
        let side = RailDLayout.centredArtSide(playerWidth: 732, containerHeight: 566, minSide: 140, maxSide: 420)
        XCTAssertEqual(side, 566 - 52 - 216)
        XCTAssertEqual(RailDLayout.centredArtSide(playerWidth: 732, containerHeight: 300, minSide: 140, maxSide: 420), 140)
    }

    func testSidebarColumnKeepsTheChipRoom() {
        // Portrait detail 640 − 290 = 350: 16 + column + 12 + 56 + 8.
        XCTAssertEqual(RailDLayout.railColumnWidth(detailWidth: 350), 258)
        // Build 51's 16 / 16 / 16 left 246; D gives the column 12 pt more.
        XCTAssertEqual(RailDLayout.railColumnWidth(detailWidth: 350) - (350 - 16 * 2 - 56 - 16), 12)
        XCTAssertEqual(RailDLayout.railColumnWidth(detailWidth: 50), 0)
        XCTAssertEqual(RailDLayout.railColumnWidth(detailWidth: .infinity), 0)
        XCTAssertLessThan(RailDLayout.railColumnWidth(detailWidth: 350), RailDLayout.largeTitleMinColumn, "28 pt title")
        XCTAssertGreaterThanOrEqual(RailDLayout.railColumnWidth(detailWidth: 820 - 320 + 44), 0)
        // The system-drawn bar (Atlas's guard) takes no column width.
        XCTAssertEqual(RailDLayout.railColumnWidth(detailWidth: 350, barWidth: 0), 314)
    }

    /// Atlas's #552 metrics and D's column agree on the art: same reserve, same clamp; D's
    /// column is 12 pt wider (16 / 12 / 8 against 16 / 16 / 16).
    func testRailColumnArtUsesAtlassReserve() {
        for (w, h, ax) in [(500.0, 640.0, false), (500, 640, true), (715, 1180, false), (320, 1180, false), (350, 776, false)] {
            let atlas = FoldedColumnLayout.railColumnMetrics(containerWidth: w, containerHeight: h, barWidth: 56,
                                                             accessibilityTextSize: ax, artMin: 140, artMax: 420)
            let column = RailDLayout.railColumnWidth(detailWidth: w)
            XCTAssertEqual(column, atlas.column + 12, "\(w)")
            let art = RailDLayout.railColumnArtSide(column: column, containerHeight: h, accessibilityTextSize: ax,
                                                    artMin: 140, artMax: 420)
            XCTAssertGreaterThanOrEqual(art, atlas.artSide, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(art, atlas.artSide + 12, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(art, column)
        }
    }

    // MARK: Source guards (the app target is not built on Linux)

    private func iosSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testRailScrubberIsOneAdjustableElementWithStableIDs() throws {
        let source = try iosSource("AeroDJ/RailDComponents.swift")
        XCTAssertTrue(source.contains("\"playback.progress\""), "Atlas's transport guard finds the bar by this id")
        XCTAssertTrue(source.contains("\"folded.railScrubber\""))
        XCTAssertTrue(source.contains("\"Song position\""))
        XCTAssertTrue(source.contains(".accessibilityAdjustableAction"))
        XCTAssertTrue(source.contains("RailDLayout.claimsDrag("))
        XCTAssertTrue(source.contains("PlaybackTimeFormat.accessibilityValue"))
    }

    func testOpenLayoutsDropTheHorizontalScrubber() throws {
        let player = try iosSource("AeroDJ/FoldedPlayer.swift")
        for (start, end) in [("private func wideContent(", "/// A still wash behind the art"),
                             ("private func railColumnBody(", "/// Build 51 (-Atlas): the collapsed rail"),
                             ("private func spreadContent(", "/// L2 (fold inactive")] {
            let a = try XCTUnwrap(player.range(of: start), start)
            let b = try XCTUnwrap(player.range(of: end, range: a.upperBound..<player.endIndex), end)
            XCTAssertFalse(player[a.lowerBound..<b.lowerBound].contains("PlaybackScrubber("), start)
        }
        XCTAssertTrue(player.contains("scrubber: railScrubber"))
        XCTAssertTrue(player.contains("RailDLayout.openArrangement("))
        XCTAssertTrue(player.contains("@Environment(\\.foldPoseOverride)"))
    }

    func testFoldOverrideIsCaptureOnly() throws {
        let capture = try iosSource("AeroDJ/RailDCapture.swift")
        XCTAssertTrue(capture.hasPrefix("#if DEBUG") || capture.contains("\n#if DEBUG"))
        let player = try iosSource("AeroDJ/FoldedPlayer.swift")
        XCTAssertFalse(player.contains(".environment(\\.foldPoseOverride"), "the app never sets it")
    }
}
