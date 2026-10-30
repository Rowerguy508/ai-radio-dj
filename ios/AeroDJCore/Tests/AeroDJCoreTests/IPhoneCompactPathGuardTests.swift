import XCTest
@testable import AeroDJCore

/// iPhone guard (iPad support, -Nova). Pins every layout value the iPhone path reads from
/// AeroDJCore at the value it had on integration/device-duo 6307545. If one of these fails,
/// an iPhone layout moved: that needs the owner's say-so, not a test update in passing.
/// The app-side tokens (FoldedStyle etc.) are pinned by ios/scripts/check-iphone-compact-path.sh.
final class IPhoneCompactPathGuardTests: XCTestCase {

    // MARK: Values

    func testStudioLayoutMetricsAreUnchanged() {
        let m = StudioLayoutMetrics.self
        XCTAssertEqual(m.gutter, 24)
        XCTAssertEqual(m.edgeInset, 16)
        XCTAssertEqual(m.zoneAMinWidth, 320)
        XCTAssertEqual(m.zoneBMinWidth, 340)
        XCTAssertEqual(m.touchTargetMin, 44)
        XCTAssertEqual(m.studioMinWidth, 716)
        XCTAssertEqual(m.lowHeight, 480)
        XCTAssertEqual(m.paneEdgeInset, 8)
        XCTAssertEqual(m.paneGutter, 12)
    }

    func testFoldedColumnLayoutIsUnchanged() {
        let f = FoldedColumnLayout.self
        XCTAssertEqual(f.wideMinWidth, 500)
        XCTAssertEqual(f.columnMaxWidth, 560)
        XCTAssertEqual(f.columnMinWidth, 360)
        XCTAssertEqual(f.edgeInset, 32)
        XCTAssertEqual(f.headerHeight, 44)
        XCTAssertEqual(f.Spacing.headerToArt, 8)
        XCTAssertEqual(f.Spacing.artToTitle, 24)
        XCTAssertEqual(f.Spacing.titleToStatus, 12)
        XCTAssertEqual(f.Spacing.statusToControls, 24)
        XCTAssertEqual(f.Spacing.betweenControls, 16)
        XCTAssertEqual(f.Spacing.transportToToolbar, 24)
    }

    func testStudioCornerRadiiAreUnchanged() {
        XCTAssertEqual(StudioCornerRadius.panel, 30)
        XCTAssertEqual(StudioCornerRadius.card, 22)
        XCTAssertEqual(StudioCornerRadius.field, 14)
        XCTAssertEqual(StudioCornerRadius.panelPadding, 16)
    }

    // MARK: Decisions at iPhone widths

    /// Portrait iPhone widths (SE 320 … Pro Max 440). Every one is compact and narrow.
    static let portraitWidths: [Double] = [320, 375, 390, 393, 402, 414, 428, 430, 440]
    /// Landscape iPhone container widths (SE 667 … Pro Max 956).
    static let landscapeWidths: [Double] = [568, 667, 736, 812, 844, 852, 874, 896, 926, 932, 956]

    func testPortraitIPhoneIsTheNarrowCompactPlayer() {
        for w in Self.portraitWidths {
            for regular in [false, true] {
                for ax in [false, true] {
                    XCTAssertEqual(StudioLayoutMode.resolve(hasRegularWidth: regular, containerWidth: w,
                                                            accessibilityTextSize: ax), .compact, "w \(w)")
                }
            }
            XCTAssertFalse(FoldedColumnLayout.isWide(containerWidth: w), "w \(w)")
            XCTAssertNil(StudioZoneWidths.allocatePanes(containerWidth: w), "w \(w)")
        }
    }

    /// Compact-class landscape iPhones stay on the listen player (wide column), never the Studio.
    func testCompactLandscapeIPhoneIsTheWideListenPlayer() {
        for w in Self.landscapeWidths {
            XCTAssertEqual(StudioLayoutMode.resolve(hasRegularWidth: false, containerWidth: w,
                                                    accessibilityTextSize: false), .compact, "w \(w)")
            XCTAssertTrue(FoldedColumnLayout.isWide(containerWidth: w), "w \(w)")
        }
    }

    /// Regular-class phones (Plus/Max landscape, the unfolded Duo) keep today's width rule:
    /// the Studio from 716 pt, stacked at accessibility sizes. Nothing iPad-only applies.
    func testRegularWidthPhoneKeepsTheWidthRule() {
        for w in Self.landscapeWidths {
            let want: StudioLayoutMode = w >= 716 ? .studio : .compact
            XCTAssertEqual(StudioLayoutMode.resolve(hasRegularWidth: true, containerWidth: w,
                                                    accessibilityTextSize: false), want, "w \(w)")
            let wantAX: StudioLayoutMode = w >= 716 ? .studioStacked : .compact
            XCTAssertEqual(StudioLayoutMode.resolve(hasRegularWidth: true, containerWidth: w,
                                                    accessibilityTextSize: true), wantAX, "w \(w)")
        }
        XCTAssertNil(LayoutMetrics(widthClass: .regular, idiom: .phone).readableMaxWidth)
    }

    /// Exact zone widths at the regular-width phone sizes, as drawn (`allocatePanes`).
    func testRegularPhoneZoneWidthsAreUnchanged() {
        let cases: [(Double, Double, Double)] = [
            (812, 392, 392), (844, 408, 408), (852, 412, 412), (874, 423, 423),
            (896, 434, 434), (926, 449, 449), (932, 452, 452), (956, 464, 464),
        ]
        for (w, a, b) in cases {
            let z = StudioZoneWidths.allocatePanes(containerWidth: w)
            XCTAssertEqual(z?.zoneA, a, "w \(w)")
            XCTAssertEqual(z?.zoneB, b, "w \(w)")
            XCTAssertEqual(z?.edgeInset, 8)
            XCTAssertEqual(z?.gutter, 12)
        }
    }

    /// The wide listen column at landscape phone sizes (FoldedPlayer's own arguments:
    /// reserve 380, or 620 at accessibility sizes; art 140…420).
    func testWideColumnMetricsAtLandscapePhoneSizesAreUnchanged() {
        let cases: [(w: Double, h: Double, reserve: Double, art: Double, column: Double)] = [
            (667, 331, 380, 140, 360),
            (852, 349, 380, 140, 360),
            (932, 386, 380, 140, 360),
            (956, 396, 380, 140, 360),
            (932, 386, 620, 140, 360),
            (640, 820, 380, 388, 388),
            (640, 820, 620, 148, 360),
        ]
        for c in cases {
            let m = FoldedColumnLayout.metrics(containerWidth: c.w, containerHeight: c.h,
                                               reserveBelowArt: c.reserve, artMin: 140, artMax: 420)
            XCTAssertEqual(m.artSide, c.art, "\(c)")
            XCTAssertEqual(m.column, c.column, "\(c)")
        }
    }

    /// The compact path never reads an iPad value, whatever the width.
    func testCompactWidthNeverGetsAnIPadValue() {
        for w in Self.portraitWidths + Self.landscapeWidths + [1024, 1366] {
            _ = w
            XCTAssertNil(LayoutMetrics(widthClass: .compact, idiom: .phone).readableMaxWidth)
            XCTAssertNil(LayoutMetrics(widthClass: .compact, idiom: .pad).readableMaxWidth)
        }
    }
}
