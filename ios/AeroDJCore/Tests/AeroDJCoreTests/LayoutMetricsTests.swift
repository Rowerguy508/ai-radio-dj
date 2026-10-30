import XCTest
@testable import AeroDJCore

/// The iPad gate (`LayoutMetrics`). Only an iPad at regular width gets an iPad value; every
/// other combination is `nil`, which means "keep the existing iPhone code path". -Nova
final class LayoutMetricsTests: XCTestCase {

    func testIPadRegularGetsTheReadableColumn() {
        let m = LayoutMetrics(widthClass: .regular, idiom: .pad)
        XCTAssertEqual(m.readableMaxWidth, 640)
        XCTAssertEqual(LayoutMetrics.iPadReadableMaxWidth, 640)
        XCTAssertTrue(m.usesIPadLayout)
    }

    /// iPad Split View and Slide Over are compact: they must take the iPhone path, unchanged.
    func testIPadCompactTakesThePhonePath() {
        XCTAssertNil(LayoutMetrics(widthClass: .compact, idiom: .pad).readableMaxWidth)
        XCTAssertFalse(LayoutMetrics(widthClass: .compact, idiom: .pad).usesIPadLayout)
    }

    /// A missing size class (SwiftUI nil) is never treated as regular.
    func testUnspecifiedWidthClassTakesThePhonePath() {
        XCTAssertNil(LayoutMetrics(widthClass: .unspecified, idiom: .pad).readableMaxWidth)
        XCTAssertNil(LayoutMetrics(widthClass: .unspecified, idiom: .phone).readableMaxWidth)
    }

    /// The idiom gate. An iPhone Plus/Max in landscape and the unfolded Duo report a regular
    /// width class; neither may get an iPad value.
    func testPhoneAtRegularWidthKeepsThePhonePath() {
        let m = LayoutMetrics(widthClass: .regular, idiom: .phone)
        XCTAssertNil(m.readableMaxWidth)
        XCTAssertFalse(m.usesIPadLayout)
    }

    func testPhoneCompactKeepsThePhonePath() {
        XCTAssertNil(LayoutMetrics(widthClass: .compact, idiom: .phone).readableMaxWidth)
    }

    /// Exhaustive: exactly one of the six combinations is iPad.
    func testExactlyOneCombinationIsIPad() {
        var iPad: [(LayoutWidthClass, LayoutIdiom)] = []
        for w in [LayoutWidthClass.compact, .regular, .unspecified] {
            for i in [LayoutIdiom.phone, .pad] where LayoutMetrics(widthClass: w, idiom: i).usesIPadLayout {
                iPad.append((w, i))
            }
        }
        XCTAssertEqual(iPad.count, 1)
        XCTAssertEqual(iPad.first?.0, .regular)
        XCTAssertEqual(iPad.first?.1, .pad)
    }

    /// The readable column always fits the Studio switch width, so capping the stacked Studio
    /// never makes it narrower than the two-zone minimum it replaces.
    func testReadableColumnIsWiderThanAZoneAndNarrowerThanTheSwitch() {
        XCTAssertGreaterThan(LayoutMetrics.iPadReadableMaxWidth, StudioLayoutMetrics.zoneBMinWidth)
        XCTAssertLessThan(LayoutMetrics.iPadReadableMaxWidth, StudioLayoutMetrics.studioMinWidth)
    }
}
