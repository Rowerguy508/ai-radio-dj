import XCTest
import UIKit

/// Regular width: artwork and controls in one pane, the up-next timeline in the other.
/// The compact phone capture is a separate launch and must not show those panes.
final class ArrangementPaneTests: XCTestCase {
    private static let ax = "UICTContentSizeCategoryAccessibilityXXXL"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCompactCaptureDoesNotShowArrangementPanes() throws {
        let app = launch()
        let any = app.descendants(matching: .any)
        let layout = any.matching(NSPredicate(format: "identifier IN %@", ["layout.studio", "layout.compact"])).firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(any["arrangement.primary"].exists, "the existing capture stays off the two panes")
        XCTAssertFalse(any["arrangement.secondary"].exists)
        XCTAssertFalse(any["arrangement.split"].exists)
        XCTAssertFalse(any["arrangement.column"].exists)
    }

    @MainActor
    func testRegularWidthSplitsArtworkAndControlsFromTheTimeline() throws {
        try XCTSkipUnless(windowIsWide(), "The 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoArrangement")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        let container = any["capture.duoContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), "arrangement container missing\n\(app.debugDescription)")
        let primary = any["arrangement.primary"]
        let secondary = any["arrangement.secondary"]
        let timeline = app.buttons["arrangement.upNext"]
        let play = app.buttons["transport.playPause"]
        let skip = app.buttons["transport.skip"]
        let back = app.buttons["folded.back"]
        for (name, element) in [("primary", primary), ("secondary", secondary), ("timeline", timeline),
                                ("play", play), ("skip", skip), ("back", back)] {
            XCTAssertTrue(element.waitForExistence(timeout: 8), "\(name) missing\n\(app.debugDescription)")
        }
        XCTAssertFalse(any["arrangement.onAir"].exists, "a ready break is not On Air")
        XCTAssertFalse(any["folded.contentColumn"].exists, "regular width uses the two panes, not the compact-class columns")
        XCTAssertGreaterThanOrEqual(play.frame.width, 44)
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        XCTAssertGreaterThanOrEqual(skip.frame.width, 44)
        XCTAssertGreaterThanOrEqual(back.frame.width, 44)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        XCTAssertGreaterThanOrEqual(timeline.frame.width, 44)
        XCTAssertGreaterThanOrEqual(timeline.frame.height, 44)
        XCTAssertTrue(primary.frame.insetBy(dx: -1, dy: -1).contains(play.frame),
                      "play stays in the artwork and controls pane")
        XCTAssertTrue(secondary.frame.insetBy(dx: -1, dy: -1).contains(timeline.frame),
                      "the timeline stays in its own pane")
        XCTAssertFalse(primary.frame.insetBy(dx: 1, dy: 1).intersects(secondary.frame.insetBy(dx: 1, dy: 1)),
                       "the panes do not overlap")
        XCTAssertTrue(timeline.label.contains("Morning Light"))
        XCTAssertTrue(timeline.label.contains("DJ break after this song"))
        XCTAssertTrue(timeline.label.contains("Slow Burn"))
        save(app, "duo-arrangement")
        timeline.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "tapping the timeline opens the queue")
    }

    @MainActor
    func testAccessibilitySizeUsesOneColumn() throws {
        try XCTSkipUnless(windowIsWide(), "The 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoArrangement", contentSize: Self.ax)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["arrangement.column"].waitForExistence(timeout: 15),
                      "accessibility text uses one column\n\(app.debugDescription)")
        XCTAssertFalse(any["arrangement.split"].exists, "accessibility text does not keep the two-pane split")
        let play = app.buttons["transport.playPause"]
        let timeline = app.buttons["arrangement.upNext"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        XCTAssertTrue(timeline.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        XCTAssertGreaterThanOrEqual(timeline.frame.height, 44)
        XCTAssertGreaterThan(timeline.frame.minY, play.frame.maxY - 4,
                             "the timeline follows the controls in one column")
        XCTAssertFalse(any["arrangement.onAir"].exists)
        save(app, "duo-arrangement-ax")
    }

    // MARK: - Launch

    @MainActor
    private static var probedWide: Bool?

    @MainActor
    private func windowIsWide() -> Bool {
        if let probed = Self.probedWide { return probed }
        let app = launch()
        let any = app.descendants(matching: .any)
        let either = any.matching(NSPredicate(format: "identifier IN %@", ["layout.studio", "layout.compact"])).firstMatch
        XCTAssertTrue(either.waitForExistence(timeout: 15), app.debugDescription)
        let wide = any["layout.studio"].exists
        app.terminate()
        Self.probedWide = wide
        return wide
    }

    @MainActor
    private func launch(scenario: String? = nil, contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES"]
        if let scenario { app.launchArguments += ["-AeroDJStudioCaptureScenario", scenario] }
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launch()
        let loading = app.descendants(matching: .any)["capture.loading"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed,
                       "Studio capture still loading\n\(app.debugDescription)")
        let failed = app.descendants(matching: .any)["capture.failed"]
        if failed.exists { XCTFail(failed.label) }
        return app
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["STUDIO_SCREENSHOT_DIR"], !dir.isEmpty {
            let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)_\(device).png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
    }
}
