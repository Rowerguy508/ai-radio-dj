import XCTest
@testable import AeroDJCore

final class SplitViewLayoutTests: XCTestCase {
    func testSamplesCoverEverySplitWidth() {
        // Named on SplitViewLayout. A leading dot here is Sample, which does not
        // own the windows, and Linux then fails the test target.
        let expected: [(SplitViewLayout.Sample, SplitViewLayout.Span)] = [
            (SplitViewLayout.narrow, .compactNarrow),
            (SplitViewLayout.half, .half),
            (SplitViewLayout.wide, .twoThirds),
            (SplitViewLayout.full, .full),
        ]
        for (sample, span) in expected {
            let chrome = SplitViewLayout.chrome(hasRegularWidth: sample.hasRegularWidth,
                                                containerWidth: sample.width,
                                                containerHeight: sample.height,
                                                leadingInset: sample.leading,
                                                trailingInset: sample.trailing,
                                                preferredBarEdge: .trailing)
            XCTAssertEqual(chrome.span, span, sample.name)
            XCTAssertTrue(chrome.adapts, sample.name)
            XCTAssertTrue(chrome.leavesRoomForTouchTarget, sample.name)
            XCTAssertEqual(chrome.decisionText, "\(span.name) \(chrome.barEdge.name)")
            let outer = sample.leading > sample.trailing ? SplitViewLayout.BarEdge.leading : SplitViewLayout.BarEdge.trailing
            XCTAssertEqual(chrome.barEdge, outer, sample.name)
            let pad = SplitViewLayout.sidePadding(measuredLeading: sample.leading,
                                                  measuredTrailing: sample.trailing,
                                                  appliedLeading: 0, appliedTrailing: 0,
                                                  designInset: 16)
            XCTAssertTrue(pad.asymmetric, sample.name)
            XCTAssertEqual(pad.leading, 16 + sample.leading, accuracy: 0.001, sample.name)
            XCTAssertEqual(pad.trailing, 16 + sample.trailing, accuracy: 0.001, sample.name)
            let bar = span == .compactNarrow ? 0 : FoldedColumnLayout.duoBarWidth
            let room = sample.width - pad.leading - pad.trailing - bar
            XCTAssertGreaterThanOrEqual(room, SplitViewLayout.touchTarget, sample.name)
        }
    }

    func testTheLargerInsetIsTheOuterEdgeAndATieKeepsThePreferredSide() {
        XCTAssertEqual(SplitViewLayout.barEdge(leading: 28, trailing: 0, preferred: .trailing), .leading)
        XCTAssertEqual(SplitViewLayout.barEdge(leading: 0, trailing: 28, preferred: .leading), .trailing)
        XCTAssertEqual(SplitViewLayout.barEdge(leading: 16, trailing: 16, preferred: .trailing), .trailing)
        XCTAssertEqual(SplitViewLayout.barEdge(leading: 16, trailing: 16, preferred: .leading), .leading)
        XCTAssertEqual(SplitViewLayout.barEdge(leading: .nan, trailing: 4, preferred: .leading), .trailing)
    }

    func testSidePaddingUsesEachInsetAndDoesNotMirrorTheLargerOne() {
        let pad = SplitViewLayout.sidePadding(measuredLeading: 28, measuredTrailing: 0,
                                              appliedLeading: 0, appliedTrailing: 0,
                                              designInset: 16)
        XCTAssertEqual(pad.leading, 44, accuracy: 0.001)
        XCTAssertEqual(pad.trailing, 16, accuracy: 0.001)
        XCTAssertNotEqual(pad.leading, pad.trailing)
        // Already inside that safe area: the design gutter stays, and it stays symmetric.
        let applied = SplitViewLayout.sidePadding(measuredLeading: 28, measuredTrailing: 0,
                                                 appliedLeading: 28, appliedTrailing: 0,
                                                 designInset: 16)
        XCTAssertFalse(applied.asymmetric)
        XCTAssertEqual(applied.leading, 16, accuracy: 0.001)
        XCTAssertEqual(applied.trailing, 16, accuracy: 0.001)
        let phone = SplitViewLayout.sidePadding(measuredLeading: 0, measuredTrailing: 0,
                                               appliedLeading: 0, appliedTrailing: 0,
                                               designInset: 32)
        XCTAssertFalse(phone.asymmetric)
        XCTAssertEqual(phone.leading, 32, accuracy: 0.001)
        XCTAssertEqual(phone.trailing, 32, accuracy: 0.001)
    }

    func testFullScreenPhoneStaysPutIncludingLandscapeWithUnevenInsets() {
        let portrait = SplitViewLayout.chrome(hasRegularWidth: false, containerWidth: 390,
                                              containerHeight: 844, leadingInset: 0, trailingInset: 0,
                                              preferredBarEdge: .trailing)
        XCTAssertFalse(portrait.adapts)
        XCTAssertEqual(portrait.barEdge, .trailing)
        XCTAssertEqual(portrait.span, .compactNarrow)
        // A missing width class is passed as not regular, the same as the continuity layout.
        let missing = SplitViewLayout.chrome(hasRegularWidth: false, containerWidth: 430,
                                             containerHeight: 932, leadingInset: 0, trailingInset: 0.4,
                                             preferredBarEdge: .trailing)
        XCTAssertFalse(missing.adapts, "a sub-point difference is still a symmetric phone")
        XCTAssertEqual(missing.barEdge, .trailing)
        let landscape = SplitViewLayout.chrome(hasRegularWidth: false, containerWidth: 932,
                                               containerHeight: 430, leadingInset: 59, trailingInset: 20,
                                               preferredBarEdge: .trailing)
        XCTAssertFalse(landscape.adapts, "landscape iPhone keeps the centred column")
        XCTAssertEqual(landscape.barEdge, .trailing, "the uneven sensor housing does not move the phone bar")
    }

    func testTheUnfoldedDuoWithMatchingInsetsIsTheFullDisplay() {
        let duo = SplitViewLayout.chrome(hasRegularWidth: false, containerWidth: 640,
                                         containerHeight: 820, leadingInset: 0, trailingInset: 0,
                                         preferredBarEdge: .trailing)
        XCTAssertEqual(duo.span, .full)
        XCTAssertFalse(duo.adapts)
        XCTAssertEqual(duo.barEdge, .trailing)
        XCTAssertEqual(SplitViewLayout.sample(named: "half")?.width, 540)
        XCTAssertNil(SplitViewLayout.sample(named: "phone"))
    }

    func testStationsPreferTheLeadingEdgeUntilTheOuterSideIsTrailing() {
        let half = SplitViewLayout.half
        let staying = SplitViewLayout.chrome(hasRegularWidth: half.hasRegularWidth,
                                             containerWidth: half.width, containerHeight: half.height,
                                             leadingInset: half.leading, trailingInset: half.trailing,
                                             preferredBarEdge: .leading)
        XCTAssertEqual(staying.barEdge, .leading)
        let wide = SplitViewLayout.wide
        let moved = SplitViewLayout.chrome(hasRegularWidth: wide.hasRegularWidth,
                                           containerWidth: wide.width, containerHeight: wide.height,
                                           leadingInset: wide.leading, trailingInset: wide.trailing,
                                           preferredBarEdge: .leading)
        XCTAssertEqual(moved.span, .twoThirds)
        XCTAssertEqual(moved.barEdge, .trailing)
        XCTAssertEqual(moved.contentWidth, wide.width - wide.trailing, accuracy: 0.001)
    }
}
