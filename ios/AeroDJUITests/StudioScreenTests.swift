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
    private func launch(segment: String? = nil, scenario: String? = nil, largeText: Bool = false,
                        dark: Bool = false, contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES"]
        if let segment { app.launchArguments += ["-AeroDJStudioCaptureSegment", segment] }
        if let scenario { app.launchArguments += ["-AeroDJStudioCaptureScenario", scenario] }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        } else if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        if dark { app.launchArguments += ["-AeroDJStudioCaptureDark", "YES"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        // The capture view loads the station before rendering. Never screenshot on a timer:
        // wait for loading to end, and fail by name if the capture could not set up.
        let loading = app.descendants(matching: .any)["capture.loading"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed,
                       "Studio capture still loading after 20 s (scenario \(scenario ?? "playing"))")
        let failed = app.descendants(matching: .any)["capture.failed"]
        if failed.exists { XCTFail(failed.label) }
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

    // MARK: Appearance and text size (closed)

    @MainActor
    func testClosedDarkAppearance() throws {
        try XCTSkipIf(isOpenLayout, "Closed layout is checked on an iPhone-width simulator")
        let app = launch(dark: true)
        XCTAssertTrue(app.otherElements["layout.compact"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["transport.playPause"].isHittable)
        save(app, "closed-dark")
    }

    @MainActor
    func testLargeAccessibilityTextKeepsTransportReachable() throws {
        let app = launch(largeText: true)
        // Accessibility sizes: compact when closed, the stacked Studio when open (no two zones).
        let layout = isOpenLayout ? "layout.studioStacked" : "layout.compact"
        // Any element type: the stacked Studio is a ScrollView, which XCUITest surfaces as a
        // scroll view, not "other" (same as the compact empty state).
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15),
                      "\(layout) expected at accessibility text size:\n\(app.debugDescription)")
        if isOpenLayout { XCTAssertFalse(app.descendants(matching: .any)["layout.studio"].exists, "no two zones at AX sizes") }
        XCTAssertTrue(shows(app, "Morning Light"))
        let play = app.buttons["transport.playPause"]
        XCTAssertTrue(isOpenLayout ? play.exists : play.isHittable, "Play/pause stays reachable at AX sizes")
        save(app, isOpenLayout ? "open-large-text" : "closed-large-text")
    }

    @MainActor
    func testOpenDarkAppearance() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "tune", dark: true)
        XCTAssertTrue(app.otherElements["layout.studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["tune.form"].waitForExistence(timeout: 10))
        save(app, "open-studio-tune-dark")
    }

    // MARK: States

    @MainActor
    func testClosedEmptyLoadingErrorAndDeniedStates() throws {
        try XCTSkipIf(isOpenLayout, "Closed layout is checked on an iPhone-width simulator")
        let cases: [(scenario: String, expect: String, transport: Bool)] = [
            ("empty", "Nothing playing", false),
            ("loading", "Connecting to Apple Music", false),
            ("error", "DJ voice unavailable", true),  // speechFailed: caption, music continues
            // The player reported the DJ break failed (DJStudioState.swift:62); music continues.
            ("playbackFailed", "couldn't play", true),
            ("denied", "Apple Music access is off", false),
        ]
        for c in cases {
            let app = launch(scenario: c.scenario)
            // Any element type: without a track the container may not surface as "other".
            XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15), c.scenario)
            XCTAssertTrue(shows(app, c.expect), "\(c.scenario) shows \(c.expect)")
            // Transport appears only when there is a session it can control.
            XCTAssertEqual(app.buttons["transport.playPause"].exists, c.transport, c.scenario)
            if c.scenario == "denied" { XCTAssertTrue(app.buttons["Open Settings"].exists) }
            save(app, "closed-state-\(c.scenario)")
            app.terminate()
        }
    }

    @MainActor
    func testSourceRevokedShowsNoConnected() throws {
        let app = launch(scenario: "revoked")
        XCTAssertTrue(app.scrollViews["connections.list"].waitForExistence(timeout: 15))
        let badge = app.descendants(matching: .any)["connections.badge.calendar"]
        if badge.exists { XCTAssertFalse(badge.label.contains("Connected"), "A revoked calendar never shows Connected") }
        XCTAssertTrue(shows(app, "removes any DJ speech"), "Revocation copy is shown")
        save(app, isOpenLayout ? "open-connections-revoked" : "closed-connections-revoked")
    }

    @MainActor
    func testStationConfigChangeIsPendingNotActive() throws {
        let app = launch(scenario: "config")
        XCTAssertTrue(app.scrollViews["tune.form"].waitForExistence(timeout: 15))
        // Energy changed: honest status, never "Active" for a setting nothing reads yet.
        let indicators = app.descendants(matching: .any).matching(identifier: "tune.indicator")
        XCTAssertGreaterThan(indicators.count, 0)
        let labels = indicators.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.localizedCaseInsensitiveContains("pending") || $0.localizedCaseInsensitiveContains("next") },
                      "A changed setting is marked pending: \(labels)")
        save(app, isOpenLayout ? "open-tune-config-change" : "closed-tune-config-change")
    }

    // MARK: Dark appearance (fixtures only; additive — light tests above are unchanged)

    /// AX5 is `accessibilityExtraExtraExtraLarge`.
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    @MainActor
    func testClosedQueueSheetDark() throws {
        try XCTSkipIf(isOpenLayout, "Closed layout is checked on an iPhone-width simulator")
        let app = launch(dark: true)
        XCTAssertTrue(app.otherElements["layout.compact"].waitForExistence(timeout: 15))
        app.buttons["queue.affordance"].tap()
        XCTAssertTrue(app.segmentedControls["workspace.segment"].waitForExistence(timeout: 5))
        XCTAssertTrue(shows(app, "Slow Burn"), "Up Next shows the fixture queue")
        save(app, "closed-queue-sheet-dark")
    }

    @MainActor
    func testOpenQueueDark() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "queue", dark: true)
        XCTAssertTrue(app.otherElements["layout.studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(shows(app, "Slow Burn"))
        save(app, "open-studio-queue-dark")
    }

    @MainActor
    func testClosedConnectionsDark() throws {
        try XCTSkipIf(isOpenLayout, "Closed layout is checked on an iPhone-width simulator")
        let app = launch(segment: "connections", dark: true)
        XCTAssertTrue(app.scrollViews["connections.list"].waitForExistence(timeout: 15))
        XCTAssertTrue(shows(app, "Calendar"))
        save(app, "closed-connections-dark")
    }

    @MainActor
    func testOpenConnectionsDark() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "connections", dark: true)
        XCTAssertTrue(app.otherElements["layout.studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["connections.list"].waitForExistence(timeout: 10))
        XCTAssertTrue(shows(app, "Calendar"))
        save(app, "open-studio-connections-dark")
    }

    @MainActor
    func testStationListDark() throws {
        let app = launch(scenario: "stations", dark: true)
        let calm = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Morning Calm")).firstMatch
        XCTAssertTrue(calm.waitForExistence(timeout: 15), "Fixture station list")
        XCTAssertTrue(shows(app, "Late Night"))
        XCTAssertFalse(shows(app, "Morning Light"), "The station list is not the player")
        save(app, isOpenLayout ? "open-station-list-dark" : "closed-station-list-dark")
    }

    @MainActor
    func testClosedStatesDark() throws {
        try XCTSkipIf(isOpenLayout, "Closed layout is checked on an iPhone-width simulator")
        try assertStatesDark(prefix: "closed-state")
    }

    @MainActor
    func testOpenStatesDark() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        try assertStatesDark(prefix: "open-state")
    }

    @MainActor
    private func assertStatesDark(prefix: String) throws {
        let cases: [(scenario: String, expect: String, transport: Bool)] = [
            ("empty", "Nothing playing", false),
            ("loading", "Connecting to Apple Music", false),
            ("error", "DJ voice unavailable", true),
            ("playbackFailed", "couldn't play", true),
            ("denied", "Apple Music access is off", false),
        ]
        for c in cases {
            let app = launch(scenario: c.scenario, dark: true)
            let layout = isOpenLayout ? "layout.studio" : "layout.compact"
            XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15), c.scenario)
            XCTAssertTrue(shows(app, c.expect), "\(c.scenario) shows \(c.expect)")
            XCTAssertEqual(app.buttons["transport.playPause"].exists, c.transport, c.scenario)
            if c.scenario == "denied" { XCTAssertTrue(app.buttons["Open Settings"].exists) }
            save(app, "\(prefix)-\(c.scenario)-dark")
            app.terminate()
        }
    }

    @MainActor
    func testAX5DarkAppearance() throws {
        let app = launch(dark: true, contentSize: Self.ax5)
        let layout = isOpenLayout ? "layout.studioStacked" : "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15),
                      "\(layout) expected at AX5:\n\(app.debugDescription)")
        if isOpenLayout {
            XCTAssertFalse(app.descendants(matching: .any)["layout.studio"].exists, "no two zones at AX sizes")
        }
        XCTAssertTrue(shows(app, "Morning Light"))
        let play = app.buttons["transport.playPause"]
        XCTAssertTrue(isOpenLayout ? play.exists : play.isHittable, "Play/pause stays reachable at AX5")
        save(app, isOpenLayout ? "open-ax5-dark" : "closed-ax5-dark")
    }

    // MARK: Recorded walkthrough (CI records the simulator screen while this runs)

    @MainActor
    func testRecordedWalkthrough() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STUDIO_WALKTHROUGH"] == "1",
                          "Runs only in the CI recording step")
        let app = launch()
        let pause = { Thread.sleep(forTimeInterval: 1.2) }
        if isOpenLayout {
            XCTAssertTrue(app.otherElements["layout.studio"].waitForExistence(timeout: 15))
        } else {
            XCTAssertTrue(app.otherElements["layout.compact"].waitForExistence(timeout: 15))
        }
        pause()
        app.buttons["transport.playPause"].tap(); pause()
        app.buttons["transport.playPause"].tap(); pause()
        if !isOpenLayout {
            app.buttons["queue.affordance"].tap()
            XCTAssertTrue(app.segmentedControls["workspace.segment"].waitForExistence(timeout: 5))
        }
        pause()
        let segments = app.segmentedControls["workspace.segment"]
        for name in ["Tune", "Connections", "Queue"] where segments.buttons[name].exists {
            segments.buttons[name].tap(); pause()
            if name == "Tune" { app.scrollViews["tune.form"].swipeUp(); pause(); app.scrollViews["tune.form"].swipeDown(); pause() }
        }
        if !isOpenLayout, app.buttons["Done"].exists { app.buttons["Done"].tap(); pause() }
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
