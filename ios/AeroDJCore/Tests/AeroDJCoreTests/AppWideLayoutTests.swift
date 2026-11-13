import XCTest
@testable import AeroDJCore

final class AppWideLayoutTests: XCTestCase {
    private let phones: [(String, AppWideLayout.Input)] = [
        ("iPhone SE portrait", .init(hasRegularWidth: false, containerWidth: 375, containerHeight: 667)),
        ("iPhone portrait", .init(hasRegularWidth: false, containerWidth: 393, containerHeight: 852)),
        ("Pro Max portrait", .init(hasRegularWidth: false, containerWidth: 440, containerHeight: 956)),
        ("iPhone landscape", .init(hasRegularWidth: false, containerWidth: 852, containerHeight: 393)),
        ("Pro Max landscape", .init(hasRegularWidth: false, containerWidth: 956, containerHeight: 440)),
        ("narrow Split View", AppWideLayout.splitNarrow),
        ("compact resize probe", .init(hasRegularWidth: false, containerWidth: 652, containerHeight: 680)),
    ]

    func testEveryPhoneSizeAndNarrowSplitKeepTheScreenAsItWas() {
        for (name, input) in phones {
            XCTAssertFalse(AppWideLayout.isWide(input), name)
            for screen in AppWideLayout.Screen.allCases {
                let decision = AppWideLayout.decide(input, for: screen)
                XCTAssertEqual(decision.mode, .phone, "\(name) \(screen)")
                XCTAssertFalse(decision.adapts, "\(name) \(screen)")
                XCTAssertEqual(decision.columns, 1, "\(name) \(screen)")
                XCTAssertEqual(decision.sideInset, 0, "\(name) \(screen)")
                XCTAssertEqual(decision.gutter, 0, "\(name) \(screen)")
                XCTAssertEqual(decision.readableWidth, input.containerWidth, "\(name) \(screen)")
            }
        }
    }

    func testTheUnfoldedDuoGetsReadableColumns() {
        let duo = AppWideLayout.duoWide
        XCTAssertTrue(AppWideLayout.isWide(duo))
        let library = AppWideLayout.decide(duo, for: .library)
        XCTAssertEqual(library.mode, .wide)
        XCTAssertEqual(library.readableWidth, 560)
        XCTAssertEqual(library.sideInset, 40)
        XCTAssertEqual(library.columns, 2)
        XCTAssertEqual(library.gutter, AppWideLayout.columnGutter)
        XCTAssertEqual(library.decisionText, "wide 2 40")

        let stations = AppWideLayout.decide(duo, for: .stations)
        XCTAssertEqual(stations.sideInset, 0, "the grid is under its cap at 640")
        XCTAssertEqual(stations.columns, 3)

        let settings = AppWideLayout.decide(duo, for: .settings)
        XCTAssertEqual(settings.columns, 1, "Settings stays one readable column")
        XCTAssertEqual(settings.sideInset, 40)
        XCTAssertEqual(settings.readableWidth, 560)

        let onboarding = AppWideLayout.decide(duo, for: .onboarding)
        XCTAssertEqual(onboarding.readableWidth, 560, "LocalAreaPrompt holds a 560 pt column")
        XCTAssertEqual(onboarding.sideInset, 40)
        XCTAssertEqual(onboarding.columns, 1, "onboarding is always one column")
        XCTAssertEqual(onboarding.decisionText, "wide 1 40")
    }

    func testEveryColumnLeavesRoomForItsContentAndATouchTarget() {
        let wide: [AppWideLayout.Input] = [
            AppWideLayout.duoWide,
            .init(hasRegularWidth: true, containerWidth: 540, containerHeight: 760),   // Split half
            .init(hasRegularWidth: true, containerWidth: 680, containerHeight: 760),   // Split two-thirds
            .init(hasRegularWidth: true, containerWidth: 540, containerHeight: 620),   // iPad form sheet
            .init(hasRegularWidth: true, containerWidth: 1024, containerHeight: 1366), // iPad full
        ]
        for input in wide {
            for screen in AppWideLayout.Screen.allCases {
                let d = AppWideLayout.decide(input, for: screen)
                XCTAssertEqual(d.mode, .wide, "\(input) \(screen)")
                XCTAssertLessThanOrEqual(d.readableWidth, AppWideLayout.readableMaxWidth(screen))
                XCTAssertEqual(d.readableWidth + 2 * d.sideInset, input.containerWidth, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(d.columns, 1)
                XCTAssertLessThanOrEqual(d.columns, AppWideLayout.maxColumns)
                let inner = d.readableWidth - 2 * AppWideLayout.screenGutter(screen)
                let column = (inner - Double(d.columns - 1) * d.gutter) / Double(d.columns)
                if d.columns > 1 {
                    XCTAssertGreaterThanOrEqual(column, AppWideLayout.minColumnWidth(screen), "\(input) \(screen)")
                }
                XCTAssertGreaterThanOrEqual(column, StudioLayoutMetrics.touchTargetMin, "\(input) \(screen)")
            }
        }
    }

    func testSplitHalfAndIPadUseTheSameRules() {
        let half = AppWideLayout.Input(hasRegularWidth: true, containerWidth: 540, containerHeight: 760)
        XCTAssertEqual(AppWideLayout.decide(half, for: .library).columns, 2)
        XCTAssertEqual(AppWideLayout.decide(half, for: .library).sideInset, 0, "540 is under the 560 cap")
        let pad = AppWideLayout.Input(hasRegularWidth: true, containerWidth: 1024, containerHeight: 1366)
        XCTAssertEqual(AppWideLayout.decide(pad, for: .stations).columns, 4, "capped at maxColumns")
        XCTAssertEqual(AppWideLayout.decide(pad, for: .stations).readableWidth, 960)
        XCTAssertEqual(AppWideLayout.decide(pad, for: .library).sideInset, 232)
        // A regular sheet shorter than the Duo still adapts; height only gates compact.
        let sheet = AppWideLayout.Input(hasRegularWidth: true, containerWidth: 540, containerHeight: 620)
        XCTAssertTrue(AppWideLayout.isWide(sheet))
        XCTAssertFalse(AppWideLayout.isWide(.init(hasRegularWidth: false, containerWidth: 540, containerHeight: 620)))
    }

    func testAccessibilityTextSizesUseOneColumnButKeepTheReadableWidth() {
        let duo = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 640, containerHeight: 820,
                                      accessibilityTextSize: true)
        for screen in AppWideLayout.Screen.allCases {
            let d = AppWideLayout.decide(duo, for: screen)
            XCTAssertEqual(d.mode, .wide, "\(screen)")
            XCTAssertEqual(d.columns, 1, "\(screen)")
            XCTAssertEqual(d.gutter, 0, "\(screen)")
        }
        XCTAssertEqual(AppWideLayout.decide(duo, for: .library).sideInset, 40)
    }

    func testTheWidthThresholdsAreTheFoldedColumnOnes() {
        let justUnder = AppWideLayout.Input(hasRegularWidth: true,
                                            containerWidth: FoldedColumnLayout.wideMinWidth - 0.5,
                                            containerHeight: 900)
        XCTAssertFalse(AppWideLayout.isWide(justUnder))
        let atWidth = AppWideLayout.Input(hasRegularWidth: false, containerWidth: FoldedColumnLayout.wideMinWidth,
                                          containerHeight: FoldedColumnLayout.duoMinHeight)
        XCTAssertTrue(AppWideLayout.isWide(atWidth))
        let short = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 640,
                                        containerHeight: FoldedColumnLayout.duoMinHeight - 1)
        XCTAssertFalse(AppWideLayout.isWide(short))
    }

    /// `LocalAreaPrompt` is a medium-detent sheet: its measured height is its content, so the
    /// vertical size class replaces the height test. Landscape iPhones stay the phone path.
    func testContentSizedSheetsUseTheVerticalSizeClassForHeight() {
        let duoSheet = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 640, containerHeight: 380,
                                           hasRegularHeight: true)
        XCTAssertTrue(AppWideLayout.isWide(duoSheet))
        XCTAssertEqual(AppWideLayout.decide(duoSheet, for: .onboarding).decisionText, "wide 1 40")
        let landscapePhone = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 852, containerHeight: 300,
                                                 hasRegularHeight: false)
        XCTAssertEqual(AppWideLayout.decide(landscapePhone, for: .onboarding).mode, .phone)
        let portraitPhone = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 440, containerHeight: 300,
                                                hasRegularHeight: true)
        XCTAssertEqual(AppWideLayout.decide(portraitPhone, for: .onboarding).mode, .phone)
        let narrowSplit = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 340, containerHeight: 300,
                                              hasRegularHeight: true)
        XCTAssertEqual(AppWideLayout.decide(narrowSplit, for: .onboarding).mode, .phone)
        let padSheet = AppWideLayout.Input(hasRegularWidth: true, containerWidth: 540, containerHeight: 300,
                                           hasRegularHeight: true)
        XCTAssertEqual(AppWideLayout.decide(padSheet, for: .onboarding).mode, .wide)
        XCTAssertEqual(AppWideLayout.decide(padSheet, for: .onboarding).sideInset, 0, "under the 560 cap")
    }

    func testNonFiniteAndZeroContainersArePhone() {
        for input in [AppWideLayout.Input(hasRegularWidth: true, containerWidth: .nan, containerHeight: 800),
                      AppWideLayout.Input(hasRegularWidth: true, containerWidth: .infinity, containerHeight: 800),
                      AppWideLayout.Input(hasRegularWidth: true, containerWidth: 800, containerHeight: 0),
                      AppWideLayout.Input(hasRegularWidth: false, containerWidth: 0, containerHeight: 0)] {
            XCTAssertEqual(AppWideLayout.decide(input, for: .stations).mode, .phone, "\(input)")
        }
    }

    /// Item 2 and item 4 plug in here. Until they land, the slots default to nil and a value
    /// in them changes nothing, on the phone path or the wide one.
    func testFoldAndArrangementSlotsDefaultToNilAndChangeNothingYet() {
        XCTAssertNil(AppWideLayout.duoWide.foldDivision)
        XCTAssertNil(AppWideLayout.duoWide.arrangement)
        // Same shape as #510's `FoldAwareness.Division`, so the forward-merge is a typealias.
        let fold = AppWideLayout.FoldDivision(minX: 306, minY: 0, width: 28, height: 820, isActive: true)
        XCTAssertTrue(fold.isVertical)
        XCTAssertEqual(fold.maxX, 334)
        XCTAssertEqual(fold.maxY, 820)
        XCTAssertFalse(AppWideLayout.FoldDivision(minX: 0, minY: 400, width: 640, height: 20, isActive: true).isVertical,
                       "a horizontal band is the laptop crease, not a book fold")
        for base in [AppWideLayout.duoWide, AppWideLayout.splitNarrow] {
            var seamed = base
            seamed.foldDivision = AppWideLayout.FoldDivision(minX: 306, minY: 0, width: 28, height: 820, isActive: true)
            seamed.arrangement = .twoPane
            for screen in AppWideLayout.Screen.allCases {
                XCTAssertEqual(AppWideLayout.decide(seamed, for: screen), AppWideLayout.decide(base, for: screen),
                               "\(screen): TODO(#465 item 2/4) is a no-op until those PRs land")
            }
        }
    }
}
