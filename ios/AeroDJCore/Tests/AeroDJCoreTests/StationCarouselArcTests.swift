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
}
