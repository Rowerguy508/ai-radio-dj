import XCTest

/// Integration tests for the playing screen in the Debug test station's capture mode
/// (`-AeroDJTestStation YES -AeroDJStudioCapture YES`): the real `PlayingScreen`, the test
/// station's `StudioPresentationModel` and the shared `PlaybackFixtures` snapshot.
///
/// The layout under test follows the device: an iPhone in portrait is the closed (compact)
/// player; an iPad's width is the open, two-zone Studio. Every test also saves a PNG
/// screenshot: as an XCTest attachment, and to `$STUDIO_SCREENSHOT_DIR` when CI sets it
/// (`TEST_RUNNER_STUDIO_SCREENSHOT_DIR`).
final class StudioScreenTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(segment: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES"]
        if let segment { app.launchArguments += ["-AeroDJStudioCaptureSegment", segment] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        return app
    }

    @MainActor
    private var isOpenLayout: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor
    func testClosedDuoIsImmersiveCompactPlayer() throws {
        try XCTSkipIf(isOpenLayout, "Closed layout is checked on an iPhone-width simulator")
        let app = launch()
        XCTAssertTrue(app.otherElements["layout.compact"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.otherElements["layout.studio"].exists)
        XCTAssertTrue(shows(app, "Morning Light"), "Now Playing shows the fixture song")
        XCTAssertTrue(shows(app, "TEST STATION"), "Capture mode is always labelled")
        XCTAssertTrue(app.buttons["transport.playPause"].isHittable)
        XCTAssertTrue(app.buttons["transport.skip"].isHittable)
        // Nothing is speaking, so nothing may say On Air.
        XCTAssertFalse(shows(app, "On Air"))
        save(app, "closed-compact")

        app.buttons["queue.affordance"].tap()
        XCTAssertTrue(app.segmentedControls["workspace.segment"].waitForExistence(timeout: 5))
        XCTAssertTrue(shows(app, "Slow Burn"), "Up Next shows the fixture queue")
        save(app, "closed-queue-sheet")
    }

    @MainActor
    func testOpenDuoIsTwoZoneControlRoom() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "queue")
        XCTAssertTrue(app.otherElements["layout.studio"].waitForExistence(timeout: 15))
        let zoneA = app.otherElements["studio.zoneA"], zoneB = app.otherElements["studio.zoneB"]
        XCTAssertTrue(zoneA.exists && zoneB.exists)
        XCTAssertLessThanOrEqual(zoneA.frame.maxX, zoneB.frame.minX, "Zones do not overlap")
        XCTAssertGreaterThanOrEqual(zoneA.frame.width, 320)
        XCTAssertGreaterThanOrEqual(zoneB.frame.width, 340)
        XCTAssertTrue(app.buttons["transport.playPause"].isHittable, "Now Playing stays in Zone A")
        XCTAssertTrue(shows(app, "Slow Burn"))
        save(app, "open-studio-queue")
    }

    @MainActor
    func testOpenDuoTunerKeepsNowPlaying() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "tune")
        XCTAssertTrue(app.otherElements["layout.studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["tune.form"].waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(app.sliders.count, 2, "Energy and discovery are real sliders")
        XCTAssertTrue(app.buttons["transport.playPause"].isHittable, "Now Playing persists while tuning")
        save(app, "open-studio-tune")
    }

    @MainActor
    func testOpenDuoConnectionsAreTruthful() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "connections")
        XCTAssertTrue(app.otherElements["layout.studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["connections.list"].waitForExistence(timeout: 10))
        XCTAssertTrue(shows(app, "Calendar"))
        // No placeholder "manage" control.
        XCTAssertFalse(shows(app, "Tap to manage"))
        save(app, "open-studio-connections")
    }

    /// Any element whose label contains `text` (SwiftUI combines some texts into one element).
    @MainActor
    private func shows(_ app: XCUIApplication, _ text: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch.exists
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
