import XCTest
@testable import AeroDJCore

/// #499: every split width on iPad and Duo container sizes, through the pure decision.
/// Sizes are points of the window, never a device check. Spans are the point bands in
/// `SplitViewLayout.Span`, so "half" of a 13 in iPad lands in the two-thirds band.
final class SplitViewDeviceWidthsTests: XCTestCase {
    private struct Window {
        let name: String
        let width: Double
        let height: Double
        let widthClass: SplitViewLayout.WidthClass?
        let span: SplitViewLayout.Span
    }

    /// One slice of a split per row: compact narrow, half, two-thirds and full width.
    private let splits: [Window] = [
        // iPad 13 in, landscape (1376 × 1032).
        Window(name: "iPad13L narrow", width: 375, height: 1032, widthClass: .compact, span: .compactNarrow),
        Window(name: "iPad13L half", width: 678, height: 1032, widthClass: .regular, span: .twoThirds),
        Window(name: "iPad13L twoThirds", width: 981, height: 1032, widthClass: .regular, span: .full),
        // iPad 11 in, landscape (1194 × 834).
        Window(name: "iPad11L narrow", width: 320, height: 834, widthClass: .compact, span: .compactNarrow),
        Window(name: "iPad11L half", width: 590, height: 834, widthClass: .compact, span: .half),
        Window(name: "iPad11L twoThirds", width: 868, height: 834, widthClass: .regular, span: .twoThirds),
        // iPad 11 in, portrait (834 × 1194).
        Window(name: "iPad11P narrow", width: 320, height: 1194, widthClass: .compact, span: .compactNarrow),
        Window(name: "iPad11P twoThirds", width: 504, height: 1194, widthClass: .compact, span: .half),
        // Duo, portrait (640 × 820, compact class).
        Window(name: "DuoP half", width: 320, height: 820, widthClass: .compact, span: .compactNarrow),
        // Duo, landscape (820 × 640, compact class). Shorter than duoMinHeight, still a split.
        Window(name: "DuoL narrow", width: 320, height: 640, widthClass: .compact, span: .compactNarrow),
        Window(name: "DuoL half", width: 410, height: 640, widthClass: .compact, span: .compactNarrow),
        Window(name: "DuoL twoThirds", width: 500, height: 640, widthClass: .compact, span: .half),
        // The capture's half sample has a missing width class: it stays compact.
        Window(name: "missing class half", width: 540, height: 760, widthClass: nil, span: .half),
    ]

    /// Full width, not split. Matching insets keep the bar where the screen has it.
    private let fullScreens: [Window] = [
        Window(name: "iPad13L full", width: 1376, height: 1032, widthClass: .regular, span: .full),
        Window(name: "iPad13P full", width: 1032, height: 1376, widthClass: .regular, span: .full),
        Window(name: "iPad11L full", width: 1194, height: 834, widthClass: .regular, span: .full),
        Window(name: "DuoP full", width: 640, height: 820, widthClass: .compact, span: .full),
        Window(name: "DuoP full, missing class", width: 640, height: 820, widthClass: nil, span: .full),
        Window(name: "DuoL full", width: 820, height: 640, widthClass: .compact, span: .twoThirds),
    ]

    private func chrome(_ window: Window, leading: Double, trailing: Double,
                        preferred: SplitViewLayout.BarEdge) -> SplitViewLayout.Chrome {
        SplitViewLayout.chrome(widthClass: window.widthClass, containerWidth: window.width,
                               containerHeight: window.height, leadingInset: leading,
                               trailingInset: trailing, preferredBarEdge: preferred)
    }

    func testEverySplitWidthPutsTheBarOnTheOuterEdgeWhicheverSideTheScreenPrefers() {
        for window in splits {
            for preferred in [SplitViewLayout.BarEdge.leading, .trailing] {
                let lead = chrome(window, leading: 28, trailing: 0, preferred: preferred)
                XCTAssertTrue(lead.adapts, window.name)
                XCTAssertEqual(lead.span, window.span, window.name)
                XCTAssertEqual(lead.barEdge, .leading, "\(window.name) prefers \(preferred.name)")
                let trail = chrome(window, leading: 0, trailing: 28, preferred: preferred)
                XCTAssertTrue(trail.adapts, window.name)
                XCTAssertEqual(trail.barEdge, .trailing, "\(window.name) prefers \(preferred.name)")
            }
        }
    }

    func testEachInsetIsReadOnItsOwnSide() {
        for window in splits {
            let both = chrome(window, leading: 20, trailing: 8, preferred: .trailing)
            XCTAssertTrue(both.adapts, window.name)
            XCTAssertEqual(both.barEdge, .leading, window.name)
            XCTAssertEqual(both.leading, 20, accuracy: 0.001, window.name)
            XCTAssertEqual(both.trailing, 8, accuracy: 0.001, window.name)
            XCTAssertEqual(both.contentWidth, window.width - 28, accuracy: 0.001, window.name)
            let pad = SplitViewLayout.sidePadding(measuredLeading: 20, measuredTrailing: 8,
                                                  appliedLeading: 0, appliedTrailing: 0, designInset: 16)
            XCTAssertEqual(pad.leading, 36, accuracy: 0.001)
            XCTAssertEqual(pad.trailing, 24, accuracy: 0.001)
            // Swapped: the outer edge follows the larger inset, not a mirrored pair.
            let swapped = chrome(window, leading: 8, trailing: 20, preferred: .leading)
            XCTAssertEqual(swapped.barEdge, .trailing, window.name)
            XCTAssertEqual(swapped.leading, 8, accuracy: 0.001, window.name)
            XCTAssertEqual(swapped.trailing, 20, accuracy: 0.001, window.name)
        }
    }

    func testEverySplitWidthLeavesRoomForA44PointTargetBesideTheBar() {
        XCTAssertGreaterThanOrEqual(SplitViewLayout.touchTarget, 44)
        for window in splits {
            for (lead, trail) in [(28.0, 0.0), (0.0, 28.0), (20.0, 8.0)] {
                let result = chrome(window, leading: lead, trailing: trail, preferred: .trailing)
                XCTAssertTrue(result.leavesRoomForTouchTarget, window.name)
                let pad = SplitViewLayout.sidePadding(measuredLeading: lead, measuredTrailing: trail,
                                                      appliedLeading: 0, appliedTrailing: 0,
                                                      designInset: FoldedColumnLayout.duoEdgeInset)
                // A narrow split keeps the phone column and has no symbol bar.
                let bar = result.span == .compactNarrow ? 0 : FoldedColumnLayout.duoBarWidth
                let room = window.width - pad.leading - pad.trailing - bar
                XCTAssertGreaterThanOrEqual(room, SplitViewLayout.touchTarget, window.name)
                let rail = SplitViewLayout.railFrame(containerWidth: window.width,
                                                     leadingInset: lead, trailingInset: trail)
                XCTAssertEqual(rail.leading, lead, accuracy: 0.001, window.name)
                XCTAssertEqual(rail.trailing, trail, accuracy: 0.001, window.name)
                XCTAssertGreaterThanOrEqual(rail.width, SplitViewLayout.touchTarget, window.name)
            }
        }
    }

    func testATieKeepsTheBarWhereThatScreenAlreadyPutsIt() {
        for window in splits + fullScreens {
            for inset in [0.0, 20.0] {
                for preferred in [SplitViewLayout.BarEdge.leading, .trailing] {
                    let tie = chrome(window, leading: inset, trailing: inset, preferred: preferred)
                    XCTAssertFalse(tie.adapts, window.name)
                    XCTAssertEqual(tie.barEdge, preferred, "\(window.name) tie at \(inset)")
                    XCTAssertEqual(tie.span, window.span, window.name)
                }
            }
        }
    }

    func testFullWidthWindowsKeepTheirSpan() {
        for window in fullScreens {
            XCTAssertEqual(chrome(window, leading: 0, trailing: 0, preferred: .trailing).span,
                           window.span, window.name)
        }
        // iPad full width with a leading-only inset still puts the bar on that side.
        let pad = chrome(fullScreens[0], leading: 20, trailing: 0, preferred: .trailing)
        XCTAssertTrue(pad.adapts)
        XCTAssertEqual(pad.barEdge, .leading)
        XCTAssertEqual(pad.span, .full)
    }

    func testAMissingWidthClassIsCompact() {
        XCTAssertFalse(SplitViewLayout.hasRegularWidth(nil))
        XCTAssertFalse(SplitViewLayout.hasRegularWidth(.compact))
        XCTAssertTrue(SplitViewLayout.hasRegularWidth(.regular))
        let windows = splits + fullScreens
        for window in windows {
            for (lead, trail) in [(0.0, 0.0), (28.0, 0.0), (0.0, 28.0)] {
                let missing = SplitViewLayout.chrome(widthClass: nil, containerWidth: window.width,
                                                     containerHeight: window.height, leadingInset: lead,
                                                     trailingInset: trail, preferredBarEdge: .trailing)
                let compact = SplitViewLayout.chrome(hasRegularWidth: false, containerWidth: window.width,
                                                     containerHeight: window.height, leadingInset: lead,
                                                     trailingInset: trail, preferredBarEdge: .trailing)
                XCTAssertEqual(missing, compact, window.name)
            }
        }
        // The unfolded Duo is the full display only as compact (or missing); regular 640 is a band.
        let duoMissing = SplitViewLayout.chrome(widthClass: nil, containerWidth: 640, containerHeight: 820,
                                                leadingInset: 0, trailingInset: 0, preferredBarEdge: .trailing)
        let duoRegular = SplitViewLayout.chrome(widthClass: .regular, containerWidth: 640, containerHeight: 820,
                                                leadingInset: 0, trailingInset: 0, preferredBarEdge: .trailing)
        XCTAssertEqual(duoMissing.span, .full)
        XCTAssertEqual(duoRegular.span, .twoThirds)
    }

    /// Full-screen iPhone, portrait and landscape, either width class and any inset pair:
    /// the decision never adapts and the bar stays where that screen puts it today.
    func testAFullScreenIPhoneKeepsTodaysLayout() {
        let phones: [(String, Double, Double)] = [
            ("SE portrait", 375, 667), ("SE landscape", 667, 375),
            ("6.1 portrait", 390, 844), ("6.1 landscape", 844, 390),
            ("Max portrait", 430, 932), ("Max landscape", 932, 430),
        ]
        let insets: [(Double, Double)] = [(0, 0), (47, 47), (59, 59), (59, 0), (0, 59), (59, 20)]
        for (name, width, height) in phones {
            let portrait = height > width
            for (lead, trail) in insets {
                // A portrait phone has no horizontal insets; skip the landscape pairs there.
                if portrait, lead != 0 || trail != 0 { continue }
                for widthClass in [SplitViewLayout.WidthClass.compact, .regular, nil] {
                    for preferred in [SplitViewLayout.BarEdge.leading, .trailing] {
                        let result = SplitViewLayout.chrome(widthClass: widthClass, containerWidth: width,
                                                            containerHeight: height, leadingInset: lead,
                                                            trailingInset: trail, preferredBarEdge: preferred)
                        let label = "\(name) \(lead)/\(trail) \(String(describing: widthClass))"
                        XCTAssertFalse(result.adapts, label)
                        XCTAssertEqual(result.barEdge, preferred, label)
                    }
                }
            }
        }
    }

    /// The Duo in landscape is shorter than duoMinHeight. Its full screen keeps today's
    /// placement even with uneven insets; a split slice of it (taller than wide) adapts.
    func testTheDuoInLandscapeStaysPutFullScreenAndAdaptsInASplit() {
        let full = SplitViewLayout.chrome(widthClass: .compact, containerWidth: 820, containerHeight: 640,
                                          leadingInset: 28, trailingInset: 0, preferredBarEdge: .trailing)
        XCTAssertFalse(full.adapts)
        XCTAssertEqual(full.barEdge, .trailing)
        let slice = SplitViewLayout.chrome(widthClass: .compact, containerWidth: 410, containerHeight: 640,
                                           leadingInset: 28, trailingInset: 0, preferredBarEdge: .trailing)
        XCTAssertTrue(slice.adapts)
        XCTAssertEqual(slice.barEdge, .leading)
    }

    /// The #574 capture slices: before (pre-#499 guard) keeps the preferred side, after
    /// moves the bar to the outer, leading edge.
    func testTheDuoLandscapeCaptureSlices() {
        XCTAssertEqual(SplitViewLayout.samples.map(\.name), ["narrow", "half", "wide", "full"])
        let expected: [(SplitViewLayout.Sample, SplitViewLayout.Span)] = [
            (SplitViewLayout.duoLandscape320, .compactNarrow),
            (SplitViewLayout.duoLandscape410, .compactNarrow),
            (SplitViewLayout.duoLandscape500, .half),
        ]
        XCTAssertEqual(SplitViewLayout.duoLandscapeSamples, expected.map(\.0))
        for (sample, span) in expected {
            XCTAssertEqual(SplitViewLayout.sample(named: sample.name), sample)
            XCTAssertEqual(sample.height, 640)
            XCTAssertFalse(sample.hasRegularWidth)
            XCTAssertGreaterThan(sample.leading, sample.trailing)
            let after = SplitViewLayout.chrome(widthClass: .compact, containerWidth: sample.width,
                                               containerHeight: sample.height, leadingInset: sample.leading,
                                               trailingInset: sample.trailing, preferredBarEdge: .trailing)
            XCTAssertTrue(after.adapts, sample.name)
            XCTAssertEqual(after.barEdge, .leading, sample.name)
            XCTAssertEqual(after.span, span, sample.name)
            #if DEBUG
            let before = SplitViewLayout.chromeWithPre499Guard(
                widthClass: .compact, containerWidth: sample.width, containerHeight: sample.height,
                leadingInset: sample.leading, trailingInset: sample.trailing, preferredBarEdge: .trailing)
            XCTAssertFalse(before.adapts, sample.name)
            XCTAssertEqual(before.barEdge, .trailing, sample.name)
            XCTAssertEqual(before.span, span, sample.name)
            #endif
        }
    }

    #if DEBUG
    /// The capture-only "before" is exactly the guard at 74414959.
    func testThePre499CaptureGuardMatchesTheOldRule() {
        func old(_ regular: Bool, _ width: Double, _ height: Double, _ lead: Double, _ trail: Double,
                 _ preferred: SplitViewLayout.BarEdge) -> (Bool, SplitViewLayout.BarEdge) {
            let landscapePhone = height < FoldedColumnLayout.duoMinHeight
            let adapts = abs(lead - trail) > 0.5 && !landscapePhone && width > 0 && height > 0
            let edge = adapts ? SplitViewLayout.barEdge(leading: lead, trailing: trail, preferred: preferred)
                : preferred
            return (adapts, edge)
        }
        let widths: [Double] = [0, 320, 410, 500, 540, 640, 680, 820, 932, 1376]
        let heights: [Double] = [0, 390, 640, 715, 716, 760, 820, 1032]
        let insets: [(Double, Double)] = [(0, 0), (28, 0), (0, 28), (20, 8), (59, 59)]
        for width in widths {
            for height in heights {
                for (lead, trail) in insets {
                    for widthClass in [SplitViewLayout.WidthClass.compact, .regular, nil] {
                        for preferred in [SplitViewLayout.BarEdge.leading, .trailing] {
                            let got = SplitViewLayout.chromeWithPre499Guard(
                                widthClass: widthClass, containerWidth: width, containerHeight: height,
                                leadingInset: lead, trailingInset: trail, preferredBarEdge: preferred)
                            let want = old(widthClass == .regular, width, height, lead, trail, preferred)
                            let label = "\(width)x\(height) \(lead)/\(trail)"
                            XCTAssertEqual(got.adapts, want.0, label)
                            XCTAssertEqual(got.barEdge, want.1, label)
                        }
                    }
                }
            }
        }
    }
    #endif
}
