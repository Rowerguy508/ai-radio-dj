import XCTest
@testable import AeroDJCore

final class AppWideLayoutTests: XCTestCase {
    private let phones: [(String, AppWideLayout.Input)] = [
        ("iPhone SE portrait", .init(hasRegularWidth: false, containerWidth: 375, containerHeight: 667)),
        ("iPhone portrait", .init(hasRegularWidth: false, containerWidth: 393, containerHeight: 852)),
        ("Pro Max portrait", .init(hasRegularWidth: false, containerWidth: 440, containerHeight: 956)),
        ("iPhone landscape", .init(hasRegularWidth: false, containerWidth: 852, containerHeight: 393)),
        // Plus and Max iPhones in landscape are regular width, compact height (#512 B1).
        ("Pro Max landscape", .init(hasRegularWidth: true, containerWidth: 956, containerHeight: 440,
                                    hasRegularHeight: false)),
        ("older Pro Max / Plus landscape", .init(hasRegularWidth: true, containerWidth: 932, containerHeight: 430,
                                                 hasRegularHeight: false)),
        ("Plus landscape", .init(hasRegularWidth: true, containerWidth: 926, containerHeight: 428,
                                 hasRegularHeight: false)),
        ("Pro Max landscape, no vertical class", .init(hasRegularWidth: true, containerWidth: 956,
                                                       containerHeight: 440)),
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
            .init(hasRegularWidth: true, containerWidth: 540, containerHeight: 760, hasRegularHeight: true),   // Split half
            .init(hasRegularWidth: true, containerWidth: 680, containerHeight: 760, hasRegularHeight: true),   // Split two-thirds
            .init(hasRegularWidth: true, containerWidth: 540, containerHeight: 620, hasRegularHeight: true),   // iPad form sheet
            .init(hasRegularWidth: true, containerWidth: 1024, containerHeight: 1366, hasRegularHeight: true), // iPad full
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
        let half = AppWideLayout.Input(hasRegularWidth: true, containerWidth: 540, containerHeight: 760,
                                       hasRegularHeight: true)
        XCTAssertEqual(AppWideLayout.decide(half, for: .library).columns, 2)
        XCTAssertEqual(AppWideLayout.decide(half, for: .library).sideInset, 0, "540 is under the 560 cap")
        let pad = AppWideLayout.Input(hasRegularWidth: true, containerWidth: 1024, containerHeight: 1366,
                                      hasRegularHeight: true)
        XCTAssertEqual(AppWideLayout.decide(pad, for: .stations).columns, 4, "capped at maxColumns")
        XCTAssertEqual(AppWideLayout.decide(pad, for: .stations).readableWidth, 960)
        XCTAssertEqual(AppWideLayout.decide(pad, for: .library).sideInset, 232)
        // A regular sheet shorter than the Duo still adapts; height only gates compact.
        let sheet = AppWideLayout.Input(hasRegularWidth: true, containerWidth: 540, containerHeight: 620,
                                        hasRegularHeight: true)
        XCTAssertTrue(AppWideLayout.isWide(sheet), "the vertical class, not the sheet's height, decides")
        // Without a vertical class the height decides, and a 620 pt sheet is not tall.
        XCTAssertFalse(AppWideLayout.isWide(.init(hasRegularWidth: true, containerWidth: 540, containerHeight: 620)))
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
                                           hasRegularHeight: true, heightIsContent: true)
        XCTAssertTrue(AppWideLayout.isWide(duoSheet))
        XCTAssertEqual(AppWideLayout.decide(duoSheet, for: .onboarding).decisionText, "wide 1 40")
        // Without the flag the same 380 pt measurement is just short, and compact: phone.
        var measured = duoSheet
        measured.heightIsContent = false
        XCTAssertFalse(AppWideLayout.isWide(measured))
        // A missing vertical class on a content-sized sheet counts as compact.
        XCTAssertFalse(AppWideLayout.isWide(.init(hasRegularWidth: true, containerWidth: 900, containerHeight: 380,
                                                  heightIsContent: true)))
        let landscapePhone = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 852, containerHeight: 300,
                                                 hasRegularHeight: false, heightIsContent: true)
        XCTAssertEqual(AppWideLayout.decide(landscapePhone, for: .onboarding).mode, .phone)
        let portraitPhone = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 440, containerHeight: 300,
                                                hasRegularHeight: true, heightIsContent: true)
        XCTAssertEqual(AppWideLayout.decide(portraitPhone, for: .onboarding).mode, .phone)
        let narrowSplit = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 340, containerHeight: 300,
                                              hasRegularHeight: true, heightIsContent: true)
        XCTAssertEqual(AppWideLayout.decide(narrowSplit, for: .onboarding).mode, .phone)
        let padSheet = AppWideLayout.Input(hasRegularWidth: true, containerWidth: 540, containerHeight: 300,
                                           hasRegularHeight: true, heightIsContent: true)
        XCTAssertEqual(AppWideLayout.decide(padSheet, for: .onboarding).mode, .wide)
        XCTAssertEqual(AppWideLayout.decide(padSheet, for: .onboarding).sideInset, 0, "under the 560 cap")
    }

    /// #515 B1 (Fry): Plus and Max iPhones in landscape are regular width and compact height.
    /// A full-width onboarding sheet there is the phone path with no inset, at every
    /// landscape width the fixtures use (956 Pro Max, 932 older Pro Max / Plus, 926 Plus).
    func testPlusAndMaxLandscapeOnboardingSheetsStayThePhonePath() {
        for width in [956.0, 932, 926] {
            let sheet = AppWideLayout.Input(hasRegularWidth: true, containerWidth: width, containerHeight: 380,
                                            hasRegularHeight: false, heightIsContent: true)
            XCTAssertFalse(AppWideLayout.isWide(sheet), "\(width)")
            let decision = AppWideLayout.decide(sheet, for: .onboarding)
            XCTAssertEqual(decision.mode, .phone, "\(width)")
            XCTAssertEqual(decision.sideInset, 0, "\(width)")
            XCTAssertEqual(decision.columns, 1, "\(width)")
            XCTAssertEqual(decision.readableWidth, width, "\(width)")
        }
        // Compact-width landscape too (every other iPhone).
        let compact = AppWideLayout.Input(hasRegularWidth: false, containerWidth: 852, containerHeight: 380,
                                          hasRegularHeight: false, heightIsContent: true)
        XCTAssertEqual(AppWideLayout.decide(compact, for: .onboarding).sideInset, 0)
    }

    /// #512 B1 (Fry, via #515): regular width counts only with regular height. Plus and Max
    /// iPhones in landscape stay the phone path for every screen; the Duo, iPad and Split
    /// View results are unchanged.
    func testRegularWidthNeedsRegularHeight() {
        for width in [956.0, 932, 926] {
            let phone = AppWideLayout.Input(hasRegularWidth: true, containerWidth: width, containerHeight: 430,
                                            hasRegularHeight: false)
            for screen in AppWideLayout.Screen.allCases {
                let d = AppWideLayout.decide(phone, for: screen)
                XCTAssertEqual(d.mode, .phone, "\(width) \(screen)")
                XCTAssertEqual(d.sideInset, 0, "\(width) \(screen)")
                XCTAssertEqual(d.columns, 1, "\(width) \(screen)")
            }
        }
        // The vertical class wins over a tall measured height for regular width.
        XCTAssertFalse(AppWideLayout.isWide(.init(hasRegularWidth: true, containerWidth: 956, containerHeight: 900,
                                                  hasRegularHeight: false)))
        // Compact width keeps the height test whatever the vertical class says: the 652 × 680
        // resize probe is vertically regular on an iPad and stays phone; the Duo stays wide.
        XCTAssertFalse(AppWideLayout.isWide(.init(hasRegularWidth: false, containerWidth: 652, containerHeight: 680,
                                                  hasRegularHeight: true)))
        var duo = AppWideLayout.duoWide
        duo.hasRegularHeight = true
        XCTAssertEqual(AppWideLayout.decide(duo, for: .library).decisionText, "wide 2 40")
        XCTAssertEqual(AppWideLayout.decide(duo, for: .stations).decisionText, "wide 3 0")
        XCTAssertEqual(AppWideLayout.decide(duo, for: .settings).decisionText, "wide 1 40")
        var narrow = AppWideLayout.splitNarrow
        narrow.hasRegularHeight = true
        XCTAssertEqual(AppWideLayout.decide(narrow, for: .library).mode, .phone)
    }

    func testNonFiniteAndZeroContainersArePhone() {
        for input in [AppWideLayout.Input(hasRegularWidth: true, containerWidth: .nan, containerHeight: 800),
                      AppWideLayout.Input(hasRegularWidth: true, containerWidth: .infinity, containerHeight: 800),
                      AppWideLayout.Input(hasRegularWidth: true, containerWidth: 800, containerHeight: 0),
                      AppWideLayout.Input(hasRegularWidth: false, containerWidth: 0, containerHeight: 0)] {
            XCTAssertEqual(AppWideLayout.decide(input, for: .stations).mode, .phone, "\(input)")
        }
    }

    func testFoldDivisionIsTypealiasedToFoldAwarenessDivision() {
        let division: FoldAwareness.Division = AppWideLayout.FoldDivision(
            minX: 306, minY: 0, width: 28, height: 820, isActive: true)
        XCTAssertTrue(division.isVertical)
        XCTAssertEqual(division.maxX, 334)
        XCTAssertEqual(division.maxY, 820)
    }

    /// #465 item 2: single-column screens (Settings, onboarding, and AX text sizes) move off a
    /// centred vertical fold onto the leading side on a tie, or the wider side when asymmetric.
    func testSingleColumnScreensKeepOffVerticalFold() {
        let centredFold = AppWideLayout.FoldDivision(minX: 306, minY: 0, width: 28, height: 820, isActive: true)
        var duo = AppWideLayout.duoWide
        duo.foldDivision = centredFold

        for screen in [AppWideLayout.Screen.settings, .onboarding] {
            let d = AppWideLayout.decide(duo, for: screen)
            XCTAssertEqual(d.mode, .wide, "\(screen)")
            XCTAssertEqual(d.columns, 1, "\(screen)")
            XCTAssertEqual(d.gutter, 0, "\(screen)")
            XCTAssertEqual(d.leadingInset + d.readableWidth + d.trailingInset, duo.containerWidth, accuracy: 0.001)
            XCTAssertLessThanOrEqual(d.leadingInset + d.readableWidth, centredFold.minX,
                                     "\(screen) tie picks leading side strictly before the fold")
            XCTAssertEqual(d.readableWidth, 306, accuracy: 0.001)
            XCTAssertEqual(d.leadingInset, 0, accuracy: 0.001)
            XCTAssertEqual(d.trailingInset, 334, accuracy: 0.001)
        }

        // Accessibility text size turns Library and Stations single-column and keeps them off the fold.
        var axDuo = duo
        axDuo.accessibilityTextSize = true
        for screen in AppWideLayout.Screen.allCases {
            let d = AppWideLayout.decide(axDuo, for: screen)
            XCTAssertEqual(d.columns, 1, "\(screen)")
            XCTAssertLessThanOrEqual(d.leadingInset + d.readableWidth, centredFold.minX, "\(screen)")
        }

        // Asymmetric fold with a wider trailing side puts Settings on the trailing side.
        var offCentre = AppWideLayout.duoWide
        let leftFold = AppWideLayout.FoldDivision(minX: 220, minY: 0, width: 24, height: 820, isActive: true)
        offCentre.foldDivision = leftFold
        let trailingSettings = AppWideLayout.decide(offCentre, for: .settings)
        XCTAssertEqual(trailingSettings.columns, 1)
        XCTAssertGreaterThanOrEqual(trailingSettings.leadingInset, leftFold.maxX)
        XCTAssertEqual(trailingSettings.readableWidth, 640 - 244, accuracy: 0.001)
        XCTAssertEqual(trailingSettings.leadingInset + trailingSettings.readableWidth + trailingSettings.trailingInset,
                       640, accuracy: 0.001)
    }

    /// #465 item 2: multi-column screens (Library, Stations) place 2 equal columns straddling
    /// the fold so the column gap covers `[fold.minX, fold.maxX]` and no card enters the crease.
    func testMultiColumnScreensPlaceColumnGapAcrossFold() {
        let fold = AppWideLayout.FoldDivision(minX: 306, minY: 0, width: 28, height: 820, isActive: true)
        var duo = AppWideLayout.duoWide
        duo.foldDivision = fold

        for screen in [AppWideLayout.Screen.library, .stations] {
            let d = AppWideLayout.decide(duo, for: screen)
            XCTAssertEqual(d.mode, .wide, "\(screen)")
            XCTAssertEqual(d.columns, 2, "\(screen)")
            XCTAssertGreaterThanOrEqual(d.gutter, fold.width, "\(screen)")
            XCTAssertEqual(d.leadingInset + d.readableWidth + d.trailingInset, duo.containerWidth, accuracy: 0.001)

            let pad = AppWideLayout.screenGutter(screen)
            let inner = d.readableWidth - 2 * pad
            let colWidth = (inner - d.gutter) / 2
            let col1End = d.leadingInset + pad + colWidth
            let col2Start = col1End + d.gutter
            XCTAssertGreaterThanOrEqual(colWidth, AppWideLayout.minColumnWidth(screen), "\(screen)")
            XCTAssertLessThanOrEqual(col1End, fold.minX + 0.001, "\(screen) column 1 clears fold")
            XCTAssertGreaterThanOrEqual(col2Start, fold.maxX - 0.001, "\(screen) column 2 clears fold")
        }

        // Narrower fold than columnGutter (16 pt) still keeps the 16 pt gutter centred on the fold.
        var thinDuo = AppWideLayout.duoWide
        let thinFold = AppWideLayout.FoldDivision(minX: 315, minY: 0, width: 10, height: 820, isActive: true)
        thinDuo.foldDivision = thinFold
        let thinLib = AppWideLayout.decide(thinDuo, for: .library)
        XCTAssertEqual(thinLib.columns, 2)
        XCTAssertEqual(thinLib.gutter, AppWideLayout.columnGutter)
        let pad = AppWideLayout.screenGutter(.library)
        let colWidth = (thinLib.readableWidth - 2 * pad - thinLib.gutter) / 2
        XCTAssertLessThanOrEqual(thinLib.leadingInset + pad + colWidth, thinFold.minX + 0.001)
        XCTAssertGreaterThanOrEqual(thinLib.leadingInset + pad + colWidth + thinLib.gutter, thinFold.maxX - 0.001)

        // Asymmetric fold where the narrower side can't fit a Library column (240 pt) falls back
        // to 1 column on the wider side, still strictly off the fold.
        var asym = AppWideLayout.duoWide
        let asymFold = AppWideLayout.FoldDivision(minX: 220, minY: 0, width: 24, height: 820, isActive: true)
        asym.foldDivision = asymFold
        let asymLib = AppWideLayout.decide(asym, for: .library)
        XCTAssertEqual(asymLib.columns, 1)
        XCTAssertGreaterThanOrEqual(asymLib.leadingInset, asymFold.maxX)
        XCTAssertEqual(asymLib.leadingInset + asymLib.readableWidth + asymLib.trailingInset, 640, accuracy: 0.001)
    }

    func testInactiveHorizontalAndPhoneFoldsLeaveLayoutUnchanged() {
        let inactive = AppWideLayout.FoldDivision(minX: 306, minY: 0, width: 28, height: 820, isActive: false)
        let laptop = AppWideLayout.FoldDivision(minX: 0, minY: 400, width: 640, height: 20, isActive: true)
        let short = AppWideLayout.FoldDivision(minX: 306, minY: 0, width: 28, height: 100, isActive: true)

        for fold in [inactive, laptop, short] {
            var input = AppWideLayout.duoWide
            input.foldDivision = fold
            for screen in AppWideLayout.Screen.allCases {
                XCTAssertEqual(AppWideLayout.decide(input, for: screen),
                               AppWideLayout.decide(AppWideLayout.duoWide, for: screen),
                               "\(fold) \(screen)")
            }
        }

        // Phone path always ignores foldDivision.
        var narrow = AppWideLayout.splitNarrow
        narrow.foldDivision = AppWideLayout.FoldDivision(minX: 160, minY: 0, width: 20, height: 760, isActive: true)
        for screen in AppWideLayout.Screen.allCases {
            XCTAssertEqual(AppWideLayout.decide(narrow, for: screen),
                           AppWideLayout.decide(AppWideLayout.splitNarrow, for: screen))
        }
    }

    func testActiveBookFoldRespectsHingeStatusAndSpan() {
        let fold = AppWideLayout.FoldDivision(minX: 306, minY: 0, width: 28, height: 820, isActive: true)
        XCTAssertEqual(
            AppWideLayout.activeBookFold(in: [fold],
                                         hinge: .init(status: .partiallyOpen, angleDegrees: 110),
                                         containerWidth: 640, containerHeight: 820),
            fold)
        XCTAssertEqual(
            AppWideLayout.activeBookFold(in: [fold], hinge: nil,
                                         containerWidth: 640, containerHeight: 820),
            fold)
        XCTAssertNil(
            AppWideLayout.activeBookFold(in: [fold],
                                         hinge: .init(status: .fullyOpen, angleDegrees: 180),
                                         containerWidth: 640, containerHeight: 820))
        XCTAssertNil(
            AppWideLayout.activeBookFold(in: [fold],
                                         hinge: .init(status: .closed, angleDegrees: 0),
                                         containerWidth: 640, containerHeight: 820))
    }

    /// Pins today's `decide` output across the containers item 10 covers: iPhone,
    /// the closed Duo, the open Duo (portrait and landscape), iPad, and Split View
    /// widths. This is a behaviour pin, not a fail-first assertion: `decide` already
    /// ignores `arrangement`, so the numbers must stay the same after that unused
    /// input is removed. iPhone, the closed Duo, and narrow Split View stay the
    /// phone path, so iPhone snapshots stay byte-identical. -Nova
    func testDecideOutputIsPinnedAcrossTheContainerMatrix() {
        struct Pin: Equatable {
            var mode: AppWideLayout.Mode
            var sideInset: Double
            var readableWidth: Double
            var columns: Int
            var gutter: Double
        }
        func phone(_ width: Double) -> Pin {
            Pin(mode: .phone, sideInset: 0, readableWidth: width, columns: 1, gutter: 0)
        }
        func wide(_ inset: Double, _ readable: Double, _ columns: Int, _ gutter: Double) -> Pin {
            Pin(mode: .wide, sideInset: inset, readableWidth: readable, columns: columns, gutter: gutter)
        }
        func pin(_ decision: AppWideLayout.Decision) -> Pin {
            Pin(mode: decision.mode, sideInset: decision.sideInset, readableWidth: decision.readableWidth,
                columns: decision.columns, gutter: decision.gutter)
        }

        let cases: [(String, AppWideLayout.Input, [AppWideLayout.Screen: Pin])] = [
            ("iPhone SE portrait",
             .init(hasRegularWidth: false, containerWidth: 375, containerHeight: 667, hasRegularHeight: true),
             [.library: phone(375), .stations: phone(375), .settings: phone(375), .onboarding: phone(375)]),
            ("iPhone portrait",
             .init(hasRegularWidth: false, containerWidth: 393, containerHeight: 852, hasRegularHeight: true),
             [.library: phone(393), .stations: phone(393), .settings: phone(393), .onboarding: phone(393)]),
            ("Pro Max portrait",
             .init(hasRegularWidth: false, containerWidth: 440, containerHeight: 956, hasRegularHeight: true),
             [.library: phone(440), .stations: phone(440), .settings: phone(440), .onboarding: phone(440)]),
            ("iPhone landscape",
             .init(hasRegularWidth: false, containerWidth: 852, containerHeight: 393, hasRegularHeight: false),
             [.library: phone(852), .stations: phone(852), .settings: phone(852), .onboarding: phone(852)]),
            ("Pro Max landscape",
             .init(hasRegularWidth: true, containerWidth: 956, containerHeight: 440, hasRegularHeight: false),
             [.library: phone(956), .stations: phone(956), .settings: phone(956), .onboarding: phone(956)]),
            ("closed Duo",
             .init(hasRegularWidth: false, containerWidth: 390, containerHeight: 844, hasRegularHeight: true),
             [.library: phone(390), .stations: phone(390), .settings: phone(390), .onboarding: phone(390)]),
            ("open Duo portrait, compact width",
             AppWideLayout.duoWide,
             [.library: wide(40, 560, 2, 16), .stations: wide(0, 640, 3, 16),
              .settings: wide(40, 560, 1, 0), .onboarding: wide(40, 560, 1, 0)]),
            ("open Duo portrait, regular width",
             .init(hasRegularWidth: true, containerWidth: 640, containerHeight: 820, hasRegularHeight: true),
             [.library: wide(40, 560, 2, 16), .stations: wide(0, 640, 3, 16),
              .settings: wide(40, 560, 1, 0), .onboarding: wide(40, 560, 1, 0)]),
            ("open Duo landscape, regular height",
             .init(hasRegularWidth: true, containerWidth: 820, containerHeight: 640, hasRegularHeight: true),
             [.library: wide(130, 560, 2, 16), .stations: wide(0, 820, 4, 16),
              .settings: wide(130, 560, 1, 0), .onboarding: wide(130, 560, 1, 0)]),
            ("open Duo landscape, no vertical class",
             .init(hasRegularWidth: true, containerWidth: 820, containerHeight: 640),
             [.library: phone(820), .stations: phone(820), .settings: phone(820), .onboarding: phone(820)]),
            ("open Duo landscape, compact width",
             .init(hasRegularWidth: false, containerWidth: 820, containerHeight: 640, hasRegularHeight: true),
             [.library: phone(820), .stations: phone(820), .settings: phone(820), .onboarding: phone(820)]),
            ("iPad portrait",
             .init(hasRegularWidth: true, containerWidth: 1024, containerHeight: 1366, hasRegularHeight: true),
             [.library: wide(232, 560, 2, 16), .stations: wide(32, 960, 4, 16),
              .settings: wide(232, 560, 1, 0), .onboarding: wide(232, 560, 1, 0)]),
            ("iPad landscape",
             .init(hasRegularWidth: true, containerWidth: 1366, containerHeight: 1024, hasRegularHeight: true),
             [.library: wide(403, 560, 2, 16), .stations: wide(203, 960, 4, 16),
              .settings: wide(403, 560, 1, 0), .onboarding: wide(403, 560, 1, 0)]),
            ("iPad form sheet",
             .init(hasRegularWidth: true, containerWidth: 540, containerHeight: 620, hasRegularHeight: true),
             [.library: wide(0, 540, 2, 16), .stations: wide(0, 540, 2, 16),
              .settings: wide(0, 540, 1, 0), .onboarding: wide(0, 540, 1, 0)]),
            ("split narrow",
             AppWideLayout.splitNarrow,
             [.library: phone(340), .stations: phone(340), .settings: phone(340), .onboarding: phone(340)]),
            ("split half",
             .init(hasRegularWidth: true, containerWidth: 540, containerHeight: 760, hasRegularHeight: true),
             [.library: wide(0, 540, 2, 16), .stations: wide(0, 540, 2, 16),
              .settings: wide(0, 540, 1, 0), .onboarding: wide(0, 540, 1, 0)]),
            ("split two-thirds",
             .init(hasRegularWidth: true, containerWidth: 680, containerHeight: 760, hasRegularHeight: true),
             [.library: wide(60, 560, 2, 16), .stations: wide(0, 680, 3, 16),
              .settings: wide(60, 560, 1, 0), .onboarding: wide(60, 560, 1, 0)]),
            ("split full",
             .init(hasRegularWidth: true, containerWidth: 1024, containerHeight: 1366, hasRegularHeight: true),
             [.library: wide(232, 560, 2, 16), .stations: wide(32, 960, 4, 16),
              .settings: wide(232, 560, 1, 0), .onboarding: wide(232, 560, 1, 0)]),
        ]

        XCTAssertEqual(cases.count, 18, "the matrix lists every container the pin covers")
        for (name, input, expected) in cases {
            XCTAssertEqual(Set(expected.keys), Set(AppWideLayout.Screen.allCases), name)
            for screen in AppWideLayout.Screen.allCases {
                XCTAssertEqual(pin(AppWideLayout.decide(input, for: screen)), expected[screen]!,
                               "\(name) \(screen)")
            }
            // Accessibility keeps the same mode, inset and readable width; columns collapse to 1.
            var accessible = input
            accessible.accessibilityTextSize = true
            for screen in AppWideLayout.Screen.allCases {
                let decision = AppWideLayout.decide(accessible, for: screen)
                let base = expected[screen]!
                XCTAssertEqual(decision.mode, base.mode, "\(name) \(screen) a11y mode")
                XCTAssertEqual(decision.sideInset, base.sideInset, accuracy: 0.001, "\(name) \(screen) a11y inset")
                XCTAssertEqual(decision.readableWidth, base.readableWidth, accuracy: 0.001,
                               "\(name) \(screen) a11y readable")
                XCTAssertEqual(decision.columns, 1, "\(name) \(screen) a11y columns")
                XCTAssertEqual(decision.gutter, 0, "\(name) \(screen) a11y gutter")
            }
        }
    }

    /// Fail-first API-shape check: `Input` still carries the unused `arrangement`
    /// slot today, so this fails on the pre-change tree and passes once the seam
    /// is removed. `foldDivision` (item 2) stays. -Nova
    func testDecideInputHasNoArrangementSlot() {
        let labels = Mirror(reflecting: AppWideLayout.Input(
            hasRegularWidth: false, containerWidth: 640, containerHeight: 820
        )).children.compactMap(\.label)
        XCTAssertFalse(labels.contains("arrangement"),
                       "decide must not take an arrangement; the item 4 seam is unused")
        XCTAssertTrue(labels.contains("foldDivision"),
                      "the item 2 fold seam stays until that wiring lands")
    }
}
