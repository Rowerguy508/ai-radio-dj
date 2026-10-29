import XCTest
@testable import AeroDJCore

/// Seek follow-up (-Atlas; Fry's #159 nit): `isNearEnd()` defaults to the detector's end window.
final class EndWindowToleranceTests: XCTestCase {
    private func at(_ position: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(entryID: "e", isPlaying: false, position: position, duration: 200)
    }

    func testDefaultToleranceIsTheEndWindow() {
        let edge = 200 - PlaybackBoundaryDetector.endWindowSeconds
        XCTAssertTrue(at(edge).isNearEnd())
        XCTAssertFalse(at(edge - 0.01).isNearEnd())
        XCTAssertEqual(at(edge - 0.01).isNearEnd(),
                       at(edge - 0.01).isNearEnd(tolerance: PlaybackBoundaryDetector.endWindowSeconds))
    }

    func testEndWindowIsStillOneAndAHalfSeconds() {
        XCTAssertEqual(PlaybackBoundaryDetector.endWindowSeconds, 1.5)
    }
}
