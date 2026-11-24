import XCTest
@testable import AeroDJCore

final class StationCarouselArcTests: XCTestCase {
    func testCentredCardIsUntransformed() {
        XCTAssertEqual(StationCarouselArc.at(phase: 0, reduceMotion: false), .centred)
        XCTAssertEqual(StationCarouselArc.at(phase: 0, reduceMotion: true), .centred)
    }

    func testSideCardsSitLowerSmallerAndDimmer() {
        let edge = StationCarouselArc.at(phase: 1, reduceMotion: false)
        XCTAssertEqual(edge.scale, StationCarouselArc.edgeScale, accuracy: 1e-9)
        XCTAssertEqual(edge.rotationDegrees, StationCarouselArc.edgeRotationDegrees, accuracy: 1e-9)
        XCTAssertEqual(edge.yOffset, StationCarouselArc.edgeDrop, accuracy: 1e-9)
        XCTAssertEqual(edge.opacity, StationCarouselArc.edgeOpacity, accuracy: 1e-9)
    }

    func testArcIsSymmetricAndTiltsOutward() {
        let leading = StationCarouselArc.at(phase: -0.5, reduceMotion: false)
        let trailing = StationCarouselArc.at(phase: 0.5, reduceMotion: false)
        XCTAssertEqual(leading.scale, trailing.scale, accuracy: 1e-9)
        XCTAssertEqual(leading.yOffset, trailing.yOffset, accuracy: 1e-9)
        XCTAssertEqual(leading.opacity, trailing.opacity, accuracy: 1e-9)
        XCTAssertEqual(leading.rotationDegrees, -trailing.rotationDegrees, accuracy: 1e-9)
        XCTAssertLessThan(leading.rotationDegrees, 0, "Leading cards tilt counter-clockwise")
    }

    func testDropIsQuadraticSoTheRowBends() {
        let half = StationCarouselArc.at(phase: 0.5, reduceMotion: false).yOffset
        let full = StationCarouselArc.at(phase: 1, reduceMotion: false).yOffset
        XCTAssertEqual(half, full / 4, accuracy: 1e-9)
    }

    func testReduceMotionIsFlat() {
        for phase in stride(from: -1.0, through: 1.0, by: 0.25) {
            let arc = StationCarouselArc.at(phase: phase, reduceMotion: true)
            XCTAssertEqual(arc.scale, 1)
            XCTAssertEqual(arc.rotationDegrees, 0)
            XCTAssertEqual(arc.yOffset, 0)
            XCTAssertEqual(arc.opacity, StationCarouselArc.at(phase: phase, reduceMotion: false).opacity,
                           accuracy: 1e-9, "Only the opacity step stays")
        }
    }

    func testOutOfRangeAndNonFinitePhasesClamp() {
        XCTAssertEqual(StationCarouselArc.at(phase: 3, reduceMotion: false),
                       StationCarouselArc.at(phase: 1, reduceMotion: false))
        XCTAssertEqual(StationCarouselArc.at(phase: -7, reduceMotion: false),
                       StationCarouselArc.at(phase: -1, reduceMotion: false))
        XCTAssertEqual(StationCarouselArc.at(phase: .nan, reduceMotion: false), .centred)
        XCTAssertEqual(StationCarouselArc.at(phase: .infinity, reduceMotion: false), .centred)
    }

    // MARK: Open Duo (build 51: cards under the trailing toolbar, diagonal line on the centred card)

    func testOpenDuoIsBothOrientationsAndNeverAnIPhone() {
        XCTAssertTrue(StationCarouselLayout.isOpenDuo(containerWidth: 640, containerHeight: 820))
        XCTAssertTrue(StationCarouselLayout.isOpenDuo(containerWidth: 820, containerHeight: 640))
        let phones: [(Double, Double)] = [(320, 568), (375, 667), (390, 844), (393, 852), (402, 874),
                                          (430, 932), (440, 956), (568, 320), (667, 375), (844, 390),
                                          (932, 430), (956, 440), (340, 760), (0, 0), (.nan, 820)]
        for (w, h) in phones {
            XCTAssertFalse(StationCarouselLayout.isOpenDuo(containerWidth: w, containerHeight: h), "\(w) x \(h)")
            XCTAssertFalse(StationCarouselLayout.clipsRow(containerWidth: w, containerHeight: h), "\(w) x \(h)")
        }
        XCTAssertTrue(StationCarouselLayout.clipsRow(containerWidth: 640, containerHeight: 820))
    }

    func testIPhoneCurveIsUnchanged() {
        for phase in stride(from: -1.0, through: 1.0, by: 0.005) {
            XCTAssertEqual(StationCarouselArc.at(phase: phase, reduceMotion: false),
                           StationCarouselArc.at(phase: phase, reduceMotion: false, snapsCentre: false))
        }
        // A hair off centre is still a (tiny) transform without the snap.
        XCTAssertNotEqual(StationCarouselArc.at(phase: 0.004, reduceMotion: false), .centred)
    }

    func testOpenDuoCentredCardIsExactlyUntransformed() {
        for phase in [0.0, 0.0001, -0.0001, 0.004, -0.01, 0.0199, -0.0199] {
            XCTAssertEqual(StationCarouselArc.at(phase: phase, reduceMotion: false, snapsCentre: true), .centred,
                           "\(phase)")
        }
        for phase in [0.02, -0.02, 0.5, -1, 1] {
            XCTAssertEqual(StationCarouselArc.at(phase: phase, reduceMotion: false, snapsCentre: true),
                           StationCarouselArc.at(phase: phase, reduceMotion: false), "\(phase)")
        }
    }

    /// Clipping the row on the Duo must never cut a card's top or bottom: every phase stays
    /// inside the row's vertical padding, for every card size the carousel can draw.
    func testClippedRowNeverCutsACardVertically() {
        for cardWidth in stride(from: 200.0, through: 300.0, by: 20) {
            for extra in stride(from: 40.0, through: 180.0, by: 35) {
                let cardHeight = cardWidth + extra
                for phase in stride(from: -1.0, through: 1.0, by: 0.01) {
                    let y = StationCarouselLayout.cardVerticalExtent(cardWidth: cardWidth, cardHeight: cardHeight,
                                                                     phase: phase, snapsCentre: true)
                    XCTAssertGreaterThanOrEqual(y.minY, -StationCarouselLayout.rowTopPadding,
                                                "\(cardWidth) \(cardHeight) \(phase)")
                    XCTAssertLessThanOrEqual(y.maxY, cardHeight + StationCarouselLayout.rowBottomPadding,
                                             "\(cardWidth) \(cardHeight) \(phase)")
                }
            }
        }
        XCTAssertEqual(StationCarouselLayout.rowTopPadding, 8)
        XCTAssertEqual(StationCarouselLayout.rowBottomPadding, StationCarouselArc.edgeDrop + 16)
    }
}
