import XCTest
@testable import AeroDJCore

final class HeaderMorphTests: XCTestCase {
    func testProgressFollowsScrollAndClamps() {
        XCTAssertEqual(HeaderMorph.progress(scrolled: 0, collapseDistance: 80), 0)
        XCTAssertEqual(HeaderMorph.progress(scrolled: 40, collapseDistance: 80), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HeaderMorph.progress(scrolled: 200, collapseDistance: 80), 1)
        XCTAssertEqual(HeaderMorph.progress(scrolled: -60, collapseDistance: 80), 0, "Overscroll stays expanded")
    }

    func testProgressRejectsBadInput() {
        XCTAssertEqual(HeaderMorph.progress(scrolled: 40, collapseDistance: 0), 0, "Unmeasured header")
        XCTAssertEqual(HeaderMorph.progress(scrolled: .nan, collapseDistance: 80), 0)
        XCTAssertEqual(HeaderMorph.progress(scrolled: 40, collapseDistance: .infinity), 0)
    }

    func testEndpoints() {
        XCTAssertEqual(HeaderMorph.at(progress: 0, reduceMotion: false), .expanded)
        let collapsed = HeaderMorph.at(progress: 1, reduceMotion: false)
        XCTAssertEqual(collapsed.largeOpacity, 0)
        XCTAssertEqual(collapsed.largeScale, HeaderMorph.collapsedScale, accuracy: 1e-9)
        XCTAssertEqual(collapsed.inlineOpacity, 1)
        XCTAssertEqual(collapsed.inlineYOffset, 0)
    }

    func testTitlesHandOffWithoutOverlap() {
        for step in 0...20 {
            let m = HeaderMorph.at(progress: Double(step) / 20, reduceMotion: false)
            if m.inlineOpacity > 0 {
                XCTAssertLessThan(m.largeOpacity, 0.5, "Inline bar appears only once the large title has mostly faded (\(m.progress))")
            }
        }
        XCTAssertEqual(HeaderMorph.at(progress: HeaderMorph.inlineStart, reduceMotion: false).inlineOpacity, 0)
    }

    func testMorphIsMonotonic() {
        var last = HeaderMorph.at(progress: 0, reduceMotion: false)
        for step in 1...50 {
            let m = HeaderMorph.at(progress: Double(step) / 50, reduceMotion: false)
            XCTAssertLessThanOrEqual(m.largeOpacity, last.largeOpacity)
            XCTAssertLessThanOrEqual(m.largeScale, last.largeScale)
            XCTAssertGreaterThanOrEqual(m.inlineOpacity, last.inlineOpacity)
            XCTAssertLessThanOrEqual(m.inlineYOffset, last.inlineYOffset)
            last = m
        }
    }

    func testReduceMotionIsACrossfade() {
        let before = HeaderMorph.at(progress: 0.49, reduceMotion: true)
        let after = HeaderMorph.at(progress: 0.5, reduceMotion: true)
        XCTAssertEqual(before.largeOpacity, 1)
        XCTAssertEqual(before.inlineOpacity, 0)
        XCTAssertEqual(after.largeOpacity, 0)
        XCTAssertEqual(after.inlineOpacity, 1)
        for p in [0.0, 0.3, 0.7, 1.0] {
            let m = HeaderMorph.at(progress: p, reduceMotion: true)
            XCTAssertEqual(m.largeScale, 1, "No scale under Reduce Motion")
            XCTAssertEqual(m.inlineYOffset, 0, "No rise under Reduce Motion")
        }
    }
}
