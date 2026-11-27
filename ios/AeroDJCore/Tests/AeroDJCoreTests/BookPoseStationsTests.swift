import XCTest
@testable import AeroDJCore

/// #507 rest (#465 item 2), -Nova: the open-Duo Stations screen in book pose. It reads the same
/// hinge and vertical division the player does, through the player's gates
/// (`FoldAwareness.bookPoseFold`), so every tile, row and header button stays off the fold the
/// system reports (margins included). A page too narrow for a row of 44 pt targets stays empty.
/// No book-pose fold (no reading, flat or closed hinge, laptop pose, a phone) is today's
/// centred band, exactly.
final class BookPoseStationsTests: XCTestCase {
    private let book = (width: 820.0, height: 640.0)

    private func band(_ minX: Double, _ width: Double, height: Double = 640, active: Bool = true) -> FoldAwareness.Division {
        FoldAwareness.Division(minX: minX, minY: 0, width: width, height: height, isActive: active)
    }

    private func hinge(_ status: FoldAwareness.HingeStatus, _ angle: Double = 150) -> FoldAwareness.HingeSample {
        FoldAwareness.HingeSample(status: status, angleDegrees: angle)
    }

    private func stations(_ hinge: FoldAwareness.HingeSample?, _ divisions: [FoldAwareness.Division],
                          width: Double = 820, height: Double = 640) -> DuoStationsLayout.Geometry {
        DuoStationsLayout.bookGeometry(containerWidth: width, containerHeight: height,
                                       hinge: hinge, divisions: divisions)
    }

    private func assertNothingOnTheFold(_ g: DuoStationsLayout.Geometry, file: StaticString = #filePath, line: UInt = #line) {
        guard let fold = g.fold else { return XCTFail("no fold band", file: file, line: line) }
        for page in g.pages {
            XCTAssertFalse(RailDLayout.intersectsFold(minX: page.minX, maxX: page.maxX,
                                                      foldMinX: fold.minX, foldMaxX: fold.maxX),
                           "page \(page) on the fold \(fold)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(page.width, DuoStationsLayout.bookPageMinWidth, file: file, line: line)
            XCTAssertLessThan(page.maxX, g.railMinX, file: file, line: line)
        }
    }

    // MARK: Today's layout where there is no book-pose fold

    func testNoBookPoseFoldIsTodaysCentredBand() {
        let today = DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640)
        let offCentre = band(352, 64)
        // No reading (this SDK, the simulator).
        XCTAssertEqual(stations(nil, []), today)
        // Flat or closed: the existing layout, whatever division comes with it.
        XCTAssertEqual(stations(hinge(.fullyOpen, 180), [offCentre]), today)
        XCTAssertEqual(stations(hinge(.closed, 0), [offCentre]), today)
        // Laptop pose: a horizontal division is left alone.
        XCTAssertEqual(stations(hinge(.partiallyOpen), [band(0, 820, height: 28).with(minY: 306)]), today)
        // An inactive or short vertical region is not the fold.
        XCTAssertEqual(stations(hinge(.partiallyOpen), [band(352, 64, active: false)]), today)
        XCTAssertEqual(stations(hinge(.partiallyOpen), [band(352, 64, height: 200)]), today)
    }

    func testACentredReportedFoldDrawsTodaysPages() {
        // The capture band (396…424) and the device window's (951 × 669): the same pages as before.
        XCTAssertEqual(stations(hinge(.partiallyOpen), [band(396, 28)]),
                       DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640))
        let device = stations(hinge(.partiallyOpen), [band(461.5, 28, height: 669)], width: 951, height: 669)
        XCTAssertEqual(device, DuoStationsLayout.geometry(containerWidth: 951, containerHeight: 669,
                                                          foldMinX: 461.5, foldMaxX: 489.5))
        XCTAssertEqual(device.pose, .book)
    }

    // MARK: The reported fold

    func testTheReportedFoldWithItsMarginsMovesBothPages() {
        // A wider, off-centre band (the system's margins included): 352…416.
        let g = stations(hinge(.partiallyOpen), [band(352, 64)])
        XCTAssertEqual(g.pose, .book)
        XCTAssertEqual(g.fold, .init(minX: 352, maxX: 416))
        XCTAssertEqual(g.pages, [.init(minX: 24, maxX: 336), .init(minX: 432, maxX: 740)])
        assertNothingOnTheFold(g)
        // The SDK path read only the capture's forced band before; the same input matches it.
        XCTAssertEqual(g, DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640,
                                                     foldMinX: 352, foldMaxX: 416))
    }

    func testAMissingOrUnknownHingeStillClearsAnActiveVerticalFold() {
        let partly = stations(hinge(.partiallyOpen), [band(352, 64)])
        XCTAssertEqual(stations(nil, [band(352, 64)]), partly, "the region is the layout signal")
        XCTAssertEqual(stations(hinge(.unknown), [band(352, 64)]), partly)
    }

    func testTheAngleDoesNotMoveThePages() {
        let a = stations(hinge(.partiallyOpen, 30), [band(352, 64)])
        let b = stations(hinge(.partiallyOpen, 170), [band(352, 64)])
        XCTAssertEqual(a, b)
    }

    // MARK: A page that cannot hold a 44 pt target

    func testTheMinimumPageHoldsTwoTargetColumns() {
        XCTAssertEqual(DuoStationsLayout.bookPageMinWidth, 2 * 44 + 16)
        // Leading page exactly 104 (24…128): both pages kept.
        let edge = stations(hinge(.partiallyOpen), [band(144, 28)])
        XCTAssertEqual(edge.pose, .book)
        XCTAssertEqual(edge.pages.first, .init(minX: 24, maxX: 128))
        // One point less: the leading page stays empty.
        let under = stations(hinge(.partiallyOpen), [band(143, 28)])
        XCTAssertEqual(under.pages, [.init(minX: 187, maxX: 740)])
    }

    func testAFoldNearTheLeadingEdgeLeavesTheLeadingPageEmpty() {
        for division in [band(60, 40), band(0, 30), band(10, 60)] {
            let g = stations(hinge(.partiallyOpen), [division])
            XCTAssertEqual(g.pose, .portrait, "one page, drawn as the upright single page: \(division)")
            XCTAssertEqual(g.pages.count, 1)
            XCTAssertEqual(g.pages[0].minX, division.maxX + DuoStationsLayout.foldGutter)
            XCTAssertEqual(g.pages[0].maxX, 740)
            XCTAssertEqual(g.fold?.minX, max(0, division.minX))
            assertNothingOnTheFold(g)
        }
    }

    func testAFoldNearTheRailLeavesTheTrailingPageEmpty() {
        let g = stations(hinge(.partiallyOpen), [band(640, 40)])
        XCTAssertEqual(g.pose, .portrait)
        XCTAssertEqual(g.pages, [.init(minX: 24, maxX: 624)])
        XCTAssertEqual(g.fold, .init(minX: 640, maxX: 680))
        assertNothingOnTheFold(g)
        // A band under the rail is not one this screen can avoid: today's centred band.
        XCTAssertEqual(stations(hinge(.partiallyOpen), [band(770, 20)]),
                       DuoStationsLayout.geometry(containerWidth: 820, containerHeight: 640))
    }

    func testTheMorePanelStaysOffTheFoldWithOnlyTheLeadingPage() {
        let g = stations(hinge(.partiallyOpen), [band(640, 40)])
        let panel = DuoStationsLayout.morePanelFrame(g, containerWidth: 820)
        XCTAssertEqual(panel.trailingGap, 820 - 756 + 8)
        let minX = 820 - panel.trailingGap - panel.width
        XCTAssertGreaterThanOrEqual(minX, 680, "the panel opens over the crease: \(minX)")
        XCTAssertGreaterThanOrEqual(panel.width, 44)
        // Two pages: unchanged (the trailing page's leading edge).
        let two = stations(hinge(.partiallyOpen), [band(352, 64)])
        XCTAssertEqual(DuoStationsLayout.morePanelFrame(two, containerWidth: 820).width, 756 - 8 - 432)
    }

    // MARK: Phones, the closed Duo, upright

    func testPhonesAndTheClosedDuoNeverReadTheFold() {
        for (w, h) in [(390.0, 844.0), (844, 390), (430, 932), (932, 430), (375, 667)] {
            let division = band(w / 2 - 14, 28, height: h)
            XCTAssertNil(FoldAwareness.bookPoseFold(containerWidth: w, containerHeight: h,
                                                    hinge: hinge(.partiallyOpen), divisions: [division]),
                         "\(w) × \(h)")
            XCTAssertEqual(stations(hinge(.partiallyOpen), [division], width: w, height: h),
                           DuoStationsLayout.geometry(containerWidth: w, containerHeight: h), "\(w) × \(h)")
        }
    }

    func testUprightStaysOnePageBesideTheRail() {
        let upright = stations(hinge(.partiallyOpen), [band(306, 28, height: 820)], width: 640, height: 820)
        XCTAssertEqual(upright, DuoStationsLayout.geometry(containerWidth: 640, containerHeight: 820))
    }

    /// The Stations screen and the player agree on when there is a book-pose fold.
    func testTheFoldIsThePlayersFold() {
        let cases: [(FoldAwareness.HingeSample?, [FoldAwareness.Division])] = [
            (nil, []), (nil, [band(352, 64)]), (hinge(.partiallyOpen), [band(396, 28)]),
            (hinge(.fullyOpen, 180), [band(396, 28)]), (hinge(.closed, 0), [band(396, 28)]),
            (hinge(.unknown), [band(352, 64)]), (hinge(.partiallyOpen), [band(396, 28, active: false)]),
            (hinge(.partiallyOpen), [band(0, 820, height: 28)]),
        ]
        for (sample, divisions) in cases {
            let fold = FoldAwareness.bookPoseFold(containerWidth: 820, containerHeight: 640,
                                                  hinge: sample, divisions: divisions)
            let player = FoldAwareness.resolve(containerWidth: 820, containerHeight: 640, hinge: sample,
                                               divisions: divisions, artMin: 140, artMax: 420)
            XCTAssertEqual(fold != nil, player.isBookPose, "\(String(describing: sample)) \(divisions)")
        }
    }
}

private extension FoldAwareness.Division {
    func with(minY: Double) -> FoldAwareness.Division {
        FoldAwareness.Division(minX: minX, minY: minY, width: width, height: height, isActive: isActive)
    }
}
