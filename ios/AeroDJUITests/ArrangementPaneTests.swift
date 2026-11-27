import XCTest
import UIKit

/// Regular width used to draw artwork and controls in one pane and the up-next timeline in
/// the other (#514). Since #542 the 2.0 rail layout is drawn there instead, and no capture
/// shows the arrangement panes.
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

    /// #542 (2.0 design, after build 49): regular width at 640 × 820 is the rail layout
    /// (`FoldedPlayer` + `DuoVerticalRail`), not the two panes. `ArrangementListenPlayer`
    /// is no longer routed by `PlayingScreen`.
    @MainActor
    func testRegularWidthDuoIsTheRailNotTwoPanes() throws {
        try XCTSkipUnless(windowIsWide(), "The 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoArrangement")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        let container = any["capture.duoContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), "Duo container missing\n\(app.debugDescription)")
        let play = app.buttons["transport.playPause"]
        let skip = app.buttons["transport.skip"]
        for (name, element) in [("track column", any["folded.trackColumn"]),
                                ("content column", any["folded.contentColumn"]),
                                ("rail", any["folded.systemBar"]), ("play", play), ("skip", skip)] {
            XCTAssertTrue(element.waitForExistence(timeout: 8), "\(name) missing\n\(app.debugDescription)")
        }
        XCTAssertFalse(any["arrangement.split"].exists, "regular width no longer uses the two panes")
        XCTAssertFalse(any["arrangement.primary"].exists)
        XCTAssertFalse(any["arrangement.secondary"].exists)
        XCTAssertFalse(any["layout.studio"].exists)
        assertAtLeastPoints(play.frame.width, 44)
        assertAtLeastPoints(play.frame.height, 44)
        assertAtLeastPoints(skip.frame.width, 44)
        save(app, "duo-regular-rail")
    }

    /// Accessibility text at 640 × 820 regular: still the rail (the Studio gate needs
    /// 716 pt), never the arrangement's single column.
    @MainActor
    func testAccessibilitySizeAtTheDuoIsNotTheArrangement() throws {
        try XCTSkipUnless(windowIsWide(), "The 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoArrangement", contentSize: Self.ax)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["transport.playPause"].waitForExistence(timeout: 8))
        XCTAssertFalse(any["arrangement.column"].exists, "the arrangement is not routed")
        XCTAssertFalse(any["arrangement.split"].exists)
        save(app, "duo-regular-rail-ax")
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
        // #542: a wide iPad window is the rail layout (`folded.systemBar`), or the Studio.
        let wide = any["layout.studio"].exists || any["folded.systemBar"].waitForExistence(timeout: 5)
        app.terminateIfRunning()
        Self.probedWide = wide
        return wide
    }

    @MainActor
    private func launch(scenario: String? = nil, contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES"]
        if let scenario { app.launchArguments += ["-AeroDJStudioCaptureScenario", scenario] }
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launchUntilAccessible(readyIdentifiers: ["transport.playPause", "capture.failed"], in: self)
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
