import XCTest
@testable import AeroDJCore

/// #499 evidence table (-Nova). `SplitViewDeviceWidthsTests` (#574) samples one slice per span;
/// this walks every Split View and Slide Over width the owner listed, on every full-screen iPad
/// window it fits, in both orientations, with compact, regular and missing width classes, and
/// checks the same rules through every decision a split slice reaches. Window points only, never
/// a device check: a "window" here is just a width and a height.
final class SplitViewWidthTableTests: XCTestCase {
    /// The slice widths under test (Split View, Slide Over, and full widths).
    private let sliceWidths: [Double] = [320, 375, 438, 507, 551, 678, 694, 744, 768, 778, 790,
                                         834, 981, 1024]

    /// Full-screen iPad windows, portrait then landscape. Every height is at least 744 pt.
    private let fullScreens: [(width: Double, height: Double)] = [
        (744, 1133), (1133, 744),
        (768, 1024), (1024, 768),
        (810, 1080), (1080, 810),
        (820, 1180), (1180, 820),
        (834, 1194), (1194, 834),
        (1024, 1366), (1366, 1024),
        (1032, 1376), (1376, 1032),
    ]

    private struct Slice {
        let width: Double
        let height: Double
        var label: String { "\(Int(width))×\(Int(height))" }
    }

    /// Each listed width that fits a full-screen window, at that window's height, plus every
    /// full-screen window itself.
    private var slices: [Slice] {
        var out: [Slice] = []
        for screen in fullScreens {
            for width in sliceWidths where width <= screen.width {
                out.append(Slice(width: width, height: screen.height))
            }
            out.append(Slice(width: screen.width, height: screen.height))
        }
        return out
    }

    private let classes: [SplitViewLayout.WidthClass?] = [.compact, .regular, nil]

    private func expectedSpan(_ slice: Slice, _ widthClass: SplitViewLayout.WidthClass?) -> SplitViewLayout.Span {
        if widthClass != .regular, slice.width >= 600, slice.height >= FoldedColumnLayout.duoMinHeight {
            return .full
        }
        switch slice.width {
        case ..<420: return .compactNarrow
        case ..<620: return .half
        case ..<900: return .twoThirds
        default: return .full
        }
    }

    func testEveryListedWidthIsInTheTable() {
        let covered = Set(slices.map(\.width))
        for width in sliceWidths {
            XCTAssertTrue(covered.contains(width), "\(width) has no window in the table")
        }
        // Both orientations of every listed full screen.
        for screen in fullScreens {
            XCTAssertTrue(fullScreens.contains { $0.width == screen.height && $0.height == screen.width })
        }
    }

    func testSpanFollowsTheWidthBandsAndTheMissingClassStaysCompact() {
        for slice in slices {
            for widthClass in classes {
                let chrome = SplitViewLayout.chrome(widthClass: widthClass, containerWidth: slice.width,
                                                    containerHeight: slice.height, leadingInset: 0,
                                                    trailingInset: 0, preferredBarEdge: .trailing)
                XCTAssertEqual(chrome.span, expectedSpan(slice, widthClass),
                               "\(slice.label) \(String(describing: widthClass))")
            }
            let missing = SplitViewLayout.chrome(widthClass: nil, containerWidth: slice.width,
                                                 containerHeight: slice.height, leadingInset: 20,
                                                 trailingInset: 0, preferredBarEdge: .trailing)
            let compact = SplitViewLayout.chrome(widthClass: .compact, containerWidth: slice.width,
                                                 containerHeight: slice.height, leadingInset: 20,
                                                 trailingInset: 0, preferredBarEdge: .trailing)
            XCTAssertEqual(missing, compact, slice.label)
        }
    }

    /// Uneven insets: the bar goes to the side with the larger inset, whatever the screen
    /// prefers, and each inset is kept on its own side. Matching insets keep the preferred side.
    func testOuterEdgeFollowsTheLargerInsetAndATieKeepsThePreferredSide() {
        let uneven: [(Double, Double, SplitViewLayout.BarEdge)] = [
            (28, 0, .leading), (0, 28, .trailing), (20, 8, .leading), (8, 20, .trailing),
        ]
        for slice in slices {
            for widthClass in classes {
                for preferred in [SplitViewLayout.BarEdge.leading, .trailing] {
                    let label = "\(slice.label) \(String(describing: widthClass)) prefers \(preferred.name)"
                    for (lead, trail, edge) in uneven {
                        let chrome = SplitViewLayout.chrome(widthClass: widthClass, containerWidth: slice.width,
                                                            containerHeight: slice.height, leadingInset: lead,
                                                            trailingInset: trail, preferredBarEdge: preferred)
                        XCTAssertTrue(chrome.adapts, "\(label) \(lead)/\(trail)")
                        XCTAssertEqual(chrome.barEdge, edge, "\(label) \(lead)/\(trail)")
                        XCTAssertEqual(chrome.leading, lead, accuracy: 0.001, label)
                        XCTAssertEqual(chrome.trailing, trail, accuracy: 0.001, label)
                        XCTAssertEqual(chrome.contentWidth, slice.width - lead - trail, accuracy: 0.001, label)
                    }
                    for inset in [0.0, 20.0, 24.0] {
                        let tie = SplitViewLayout.chrome(widthClass: widthClass, containerWidth: slice.width,
                                                         containerHeight: slice.height, leadingInset: inset,
                                                         trailingInset: inset, preferredBarEdge: preferred)
                        XCTAssertFalse(tie.adapts, "\(label) tie \(inset)")
                        XCTAssertEqual(tie.barEdge, preferred, "\(label) tie \(inset)")
                    }
                }
            }
        }
    }

    /// A 44 pt target fits beside the bar at every width, and the split host's rail frame
    /// keeps at least that much.
    func testEveryWidthLeavesRoomForA44PointTarget() {
        XCTAssertGreaterThanOrEqual(SplitViewLayout.touchTarget, 44)
        for slice in slices {
            for widthClass in classes {
                for (lead, trail) in [(28.0, 0.0), (0.0, 28.0), (20.0, 8.0)] {
                    let label = "\(slice.label) \(String(describing: widthClass)) \(lead)/\(trail)"
                    let chrome = SplitViewLayout.chrome(widthClass: widthClass, containerWidth: slice.width,
                                                        containerHeight: slice.height, leadingInset: lead,
                                                        trailingInset: trail, preferredBarEdge: .trailing)
                    XCTAssertTrue(chrome.leavesRoomForTouchTarget, label)
                    let pad = SplitViewLayout.sidePadding(measuredLeading: lead, measuredTrailing: trail,
                                                          appliedLeading: 0, appliedTrailing: 0,
                                                          designInset: FoldedColumnLayout.duoEdgeInset)
                    let bar = chrome.span == .compactNarrow ? 0 : FoldedColumnLayout.duoBarWidth
                    XCTAssertGreaterThanOrEqual(slice.width - pad.leading - pad.trailing - bar,
                                                SplitViewLayout.touchTarget, label)
                    let rail = SplitViewLayout.railFrame(containerWidth: slice.width, leadingInset: lead,
                                                         trailingInset: trail)
                    XCTAssertGreaterThanOrEqual(rail.width, SplitViewLayout.touchTarget, label)
                }
            }
        }
    }

    /// Rail D on a split slice is only the Duo's landscape slices (under 716 pt tall). No iPad
    /// window in either orientation is that short, so every slice here keeps its column.
    func testNoIPadSliceTakesTheDuoLandscapeRailD() {
        for slice in slices {
            for (lead, trail) in [(28.0, 0.0), (0.0, 28.0), (20.0, 8.0), (0.0, 0.0)] {
                XCTAssertFalse(SplitViewLayout.keepsRailD(containerWidth: slice.width, containerHeight: slice.height,
                                                          leadingInset: lead, trailingInset: trail),
                               "\(slice.label) \(lead)/\(trail)")
            }
        }
    }

    /// Library, Stations, Settings and onboarding: under 500 pt is today's phone screen; 500 pt
    /// and wider is the wide layout on every iPad window (vertically regular), with the
    /// readable band centred inside the slice and never wider than it.
    func testAppWideScreensAtEveryWidth() {
        for slice in slices {
            for regularWidth in [false, true] {
                for regularHeight in [Bool?.some(true), nil] {
                    let input = AppWideLayout.Input(hasRegularWidth: regularWidth, containerWidth: slice.width,
                                                    containerHeight: slice.height, hasRegularHeight: regularHeight)
                    for screen in AppWideLayout.Screen.allCases {
                        let label = "\(slice.label) regular:\(regularWidth) \(screen.rawValue)"
                        let decision = AppWideLayout.decide(input, for: screen)
                        if slice.width < FoldedColumnLayout.wideMinWidth {
                            XCTAssertEqual(decision.mode, .phone, label)
                            XCTAssertEqual(decision.readableWidth, slice.width, accuracy: 0.001, label)
                            XCTAssertEqual(decision.columns, 1, label)
                            continue
                        }
                        XCTAssertEqual(decision.mode, .wide, label)
                        XCTAssertLessThanOrEqual(decision.readableWidth, slice.width + 0.001, label)
                        XCTAssertLessThanOrEqual(decision.readableWidth,
                                                 AppWideLayout.readableMaxWidth(screen) + 0.001, label)
                        XCTAssertEqual(decision.leadingInset + decision.readableWidth + decision.trailingInset,
                                       slice.width, accuracy: 0.001, label)
                        XCTAssertEqual(decision.leadingInset, decision.trailingInset, accuracy: 0.001, label)
                        XCTAssertGreaterThanOrEqual(decision.columns, 1, label)
                        XCTAssertLessThanOrEqual(decision.columns, AppWideLayout.maxColumns, label)
                        let inner = decision.readableWidth - AppWideLayout.screenGutter(screen) * 2
                        let columns = Double(decision.columns)
                        let column = (inner - decision.gutter * (columns - 1)) / columns
                        XCTAssertGreaterThanOrEqual(column, SplitViewLayout.touchTarget, label)
                        if decision.columns > 1 {
                            XCTAssertGreaterThanOrEqual(column + 0.001, AppWideLayout.minColumnWidth(screen), label)
                        }
                    }
                }
            }
        }
    }

    /// The Library's two-pane book layout never opens inside a split (uneven insets), and the
    /// tuner's two panes never open inside the Studio's split pane, at any width.
    func testTwoPaneLayoutsStayOneColumnInsideASplit() {
        for slice in slices {
            let library = LibraryDuoLayout.decide(.init(containerWidth: slice.width, containerHeight: slice.height,
                                                         hasSplitInsets: true))
            XCTAssertEqual(library.mode, .singleColumn, slice.label)
            let tuner = StationTunerLayout.decide(.init(containerWidth: slice.width, containerHeight: slice.height,
                                                        isInSplitPane: true))
            XCTAssertEqual(tuner.mode, .singleColumn, slice.label)
        }
    }
}
