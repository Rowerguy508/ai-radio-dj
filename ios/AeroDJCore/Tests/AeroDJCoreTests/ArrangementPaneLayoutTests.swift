import XCTest
@testable import AeroDJCore

/// Regular width puts artwork and controls in one pane and the up-next timeline
/// in the other. Compact width and the phone layouts stay on the existing player.
final class ArrangementPaneLayoutTests: XCTestCase {
    private let duoWidth = 640.0
    private let duoHeight = 820.0

    func testCompactWidthKeepsTheExistingPlayer() {
        let decision = ArrangementPaneLayout.resolve(
            hasRegularWidth: false, containerWidth: duoWidth, containerHeight: duoHeight,
            accessibilityTextSize: false)
        XCTAssertEqual(decision, .unchanged)
        let accessible = ArrangementPaneLayout.resolve(
            hasRegularWidth: false, containerWidth: duoWidth, containerHeight: duoHeight,
            accessibilityTextSize: true)
        XCTAssertEqual(accessible, .unchanged)
    }

    func testPhonePortraitAndLandscapeStayUnchangedEvenWhenRegular() {
        let portrait = ArrangementPaneLayout.resolve(
            hasRegularWidth: true, containerWidth: 390, containerHeight: 844,
            accessibilityTextSize: false)
        XCTAssertEqual(portrait, .unchanged)
        let landscape = ArrangementPaneLayout.resolve(
            hasRegularWidth: true, containerWidth: 844, containerHeight: 390,
            accessibilityTextSize: false)
        XCTAssertEqual(landscape, .unchanged)
        let accessiblePhone = ArrangementPaneLayout.resolve(
            hasRegularWidth: true, containerWidth: 390, containerHeight: 844,
            accessibilityTextSize: true)
        XCTAssertEqual(accessiblePhone, .unchanged)
    }

    func testANonFiniteContainerStaysUnchanged() {
        for width in [Double.nan, .infinity, 0, -20] {
            let decision = ArrangementPaneLayout.resolve(
                hasRegularWidth: true, containerWidth: width, containerHeight: duoHeight,
                accessibilityTextSize: false)
            XCTAssertEqual(decision, .unchanged, "width \(width)")
        }
    }

    func testRegularDuoSplitsArtworkAndControlsFromTheTimeline() throws {
        let metrics = try split(width: duoWidth, height: duoHeight)
        XCTAssertEqual(metrics.axis, .vertical)
        XCTAssertEqual(metrics.edgeInset, ArrangementPaneLayout.edgeInset)
        XCTAssertEqual(metrics.gutter, ArrangementPaneLayout.gutter)
        XCTAssertEqual(metrics.primary, .init(x: 16, y: 16, width: 608, height: 540))
        XCTAssertEqual(metrics.secondary, .init(x: 16, y: 572, width: 608, height: 232))
        XCTAssertLessThanOrEqual(metrics.primary.maxY, metrics.secondary.y)
        XCTAssertEqual(metrics.secondary.y - metrics.primary.maxY, metrics.gutter, accuracy: 0.001)
        assertFills(metrics, width: duoWidth, height: duoHeight)
        XCTAssertGreaterThanOrEqual(metrics.primary.height, ArrangementPaneLayout.hitTarget)
        XCTAssertGreaterThanOrEqual(metrics.secondary.height, ArrangementPaneLayout.hitTarget)
        XCTAssertEqual(ArrangementPaneLayout.hitTarget, 44)
    }

    func testAWiderContainerSplitsLeadingAndTrailing() throws {
        let metrics = try split(width: 800, height: 760)
        XCTAssertEqual(metrics.axis, .horizontal)
        XCTAssertEqual(metrics.primary, .init(x: 16, y: 16, width: 526, height: 728))
        XCTAssertEqual(metrics.secondary, .init(x: 558, y: 16, width: 226, height: 728))
        XCTAssertLessThanOrEqual(metrics.primary.maxX, metrics.secondary.x)
        XCTAssertEqual(metrics.secondary.x - metrics.primary.maxX, metrics.gutter, accuracy: 0.001)
        assertFills(metrics, width: 800, height: 760)
        XCTAssertGreaterThanOrEqual(metrics.primary.width, ArrangementPaneLayout.hitTarget)
        XCTAssertGreaterThanOrEqual(metrics.secondary.width, ArrangementPaneLayout.hitTarget)
    }

    func testAccessibilitySizesUseOneColumn() {
        let decision = ArrangementPaneLayout.resolve(
            hasRegularWidth: true, containerWidth: duoWidth, containerHeight: duoHeight,
            accessibilityTextSize: true)
        guard case .singleColumn(let metrics) = decision else {
            return XCTFail("expected one column, got \(decision)")
        }
        XCTAssertEqual(metrics.axis, .vertical)
        XCTAssertEqual(metrics.primary.width, metrics.secondary.width)
        XCTAssertEqual(metrics.primary.x, metrics.secondary.x)
        XCTAssertGreaterThan(metrics.secondary.y, metrics.primary.y)
        XCTAssertGreaterThanOrEqual(metrics.primary.height, ArrangementPaneLayout.hitTarget)
        XCTAssertGreaterThanOrEqual(metrics.secondary.height, ArrangementPaneLayout.hitTarget)
        assertFills(metrics, width: duoWidth, height: duoHeight)
    }

    func testTheSameInputsResolveTheSameFrames() {
        let first = ArrangementPaneLayout.resolve(
            hasRegularWidth: true, containerWidth: duoWidth, containerHeight: duoHeight,
            accessibilityTextSize: false)
        let second = ArrangementPaneLayout.resolve(
            hasRegularWidth: true, containerWidth: duoWidth, containerHeight: duoHeight,
            accessibilityTextSize: false)
        XCTAssertEqual(first, second)
    }

    func testTheLiveMarkIsTheOnAirLabelAndNothingElse() {
        XCTAssertNil(ArrangementPaneLayout.liveMark(onAirLabel: nil))
        XCTAssertNil(ArrangementPaneLayout.liveMark(onAirLabel: ""))
        XCTAssertNil(ArrangementPaneLayout.liveMark(onAirLabel: " "))
        XCTAssertEqual(ArrangementPaneLayout.liveMark(onAirLabel: "On Air"), "On Air")

        let states: [DJStudioState] = [
            .idle,
            .preparing(includesBriefing: false),
            .preparing(includesBriefing: true),
            .ready(includesBriefing: false, seconds: 30),
            .ready(includesBriefing: true, seconds: 12),
            .speaking(includesBriefing: false),
            .speaking(includesBriefing: true),
            .failed(.voiceFailed),
            .failed(.budgetReached),
            .failed(.consentReviewRequired(pendingCount: 2)),
        ]
        for state in states {
            XCTAssertEqual(ArrangementPaneLayout.liveMark(onAirLabel: state.onAirLabel), state.onAirLabel, "\(state)")
            XCTAssertEqual(state.onAirLabel != nil, state.isOnAir, "\(state)")
        }
        XCTAssertEqual(DJStudioState.speaking(includesBriefing: false).onAirLabel, "On Air")
        XCTAssertNil(DJStudioState.ready(includesBriefing: false, seconds: 30).onAirLabel)
    }

    // MARK: - Helpers

    private func split(width: Double, height: Double) throws -> ArrangementPaneLayout.Metrics {
        let decision = ArrangementPaneLayout.resolve(
            hasRegularWidth: true, containerWidth: width, containerHeight: height,
            accessibilityTextSize: false)
        guard case .split(let metrics) = decision else {
            XCTFail("expected a split, got \(decision)")
            throw SplitError.notSplit
        }
        return metrics
    }

    private func assertFills(_ metrics: ArrangementPaneLayout.Metrics, width: Double, height: Double) {
        let primary = metrics.primary
        let secondary = metrics.secondary
        XCTAssertGreaterThanOrEqual(primary.x, 0)
        XCTAssertGreaterThanOrEqual(primary.y, 0)
        XCTAssertLessThanOrEqual(max(primary.maxX, secondary.maxX), width + 0.001)
        XCTAssertLessThanOrEqual(max(primary.maxY, secondary.maxY), height + 0.001)
        XCTAssertFalse(overlaps(primary, secondary))
        let span = metrics.edgeInset * 2 + metrics.gutter
        switch metrics.axis {
        case .horizontal:
            XCTAssertEqual(primary.width + secondary.width + span, width, accuracy: 0.001)
            XCTAssertEqual(primary.height + metrics.edgeInset * 2, height, accuracy: 0.001)
        case .vertical:
            XCTAssertEqual(primary.height + secondary.height + span, height, accuracy: 0.001)
            XCTAssertEqual(primary.width + metrics.edgeInset * 2, width, accuracy: 0.001)
        }
    }

    private func overlaps(_ a: ArrangementPaneLayout.Frame, _ b: ArrangementPaneLayout.Frame) -> Bool {
        a.maxX > b.x + 0.001 && a.x < b.maxX - 0.001 && a.maxY > b.y + 0.001 && a.y < b.maxY - 0.001
    }

    private enum SplitError: Error { case notSplit }
}
