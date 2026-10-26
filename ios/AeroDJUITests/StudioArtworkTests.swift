import XCTest

/// Presentation coverage added beside Fry's `StudioScreenTests`. It does not replace that
/// file. Launch arguments and accessibility identifiers are the ones the capture harness
/// and the existing tests already use.
///
/// What this adds: the station ident on empty / loading / denied / speech-failed screens
/// (including the open layout, dark, and an accessibility text size), and a real tuner
/// tap that must show Pending while other song-picking settings stay Saved.
final class StudioArtworkTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(segment: String? = nil, scenario: String? = nil, largeText: Bool = false,
                        dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES"]
        if let segment { app.launchArguments += ["-AeroDJStudioCaptureSegment", segment] }
        if let scenario { app.launchArguments += ["-AeroDJStudioCaptureScenario", scenario] }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        if dark { app.launchArguments += ["-AeroDJStudioCaptureDark", "YES"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        return app
    }

    @MainActor
    private var isOpenLayout: Bool { UIDevice.current.userInterfaceIdiom == .pad }

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

    /// Open layout only. Closed empty / loading / error / denied are already shot by
    /// `StudioScreenTests`; this records the same states in the two-zone Studio.
    @MainActor
    func testOpenEmptyLoadingErrorAndDeniedStates() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let cases: [(scenario: String, expect: String, transport: Bool)] = [
            ("empty", "Nothing playing", false),
            ("loading", "Connecting to Apple Music", false),
            ("error", "DJ voice unavailable", true),
            ("denied", "Apple Music access is off", false),
        ]
        for c in cases {
            let app = launch(scenario: c.scenario)
            XCTAssertTrue(app.descendants(matching: .any)["layout.studio"].waitForExistence(timeout: 15), c.scenario)
            if c.scenario != "error" {
                XCTAssertTrue(app.descendants(matching: .any)["empty.stage"].waitForExistence(timeout: 5), c.scenario)
            }
            XCTAssertTrue(shows(app, c.expect), "\(c.scenario) shows \(c.expect)")
            XCTAssertFalse(shows(app, "On Air"), "\(c.scenario) is not live")
            XCTAssertEqual(app.buttons["transport.playPause"].exists, c.transport, c.scenario)
            if c.scenario == "denied" { XCTAssertTrue(app.buttons["Open Settings"].exists) }
            if c.scenario == "error" { XCTAssertTrue(shows(app, "Music continues")) }
            save(app, "open-state-\(c.scenario)")
            app.terminate()
        }
    }

    @MainActor
    func testEmptyStateDarkAppearance() throws {
        let app = launch(scenario: "empty", dark: true)
        let layout = isOpenLayout ? "layout.studio" : "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["empty.stage"].waitForExistence(timeout: 5))
        XCTAssertTrue(shows(app, "Nothing playing"))
        XCTAssertFalse(app.buttons["transport.playPause"].exists)
        save(app, isOpenLayout ? "open-state-empty-dark" : "closed-state-empty-dark")
    }

    @MainActor
    func testEmptyStateAtAccessibilitySize() throws {
        let app = launch(scenario: "empty", largeText: true)
        let layout = isOpenLayout ? "layout.studioStacked" : "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15),
                      "\(layout) expected:\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Nothing playing"))
        XCTAssertFalse(app.buttons["transport.playPause"].exists)
        save(app, isOpenLayout ? "open-state-empty-large-text" : "closed-state-empty-large-text")
    }

    /// Taps a real genre chip. Song picking still doesn't use it, so the row goes Pending
    /// and at least one untouched song-picking row stays Saved.
    @MainActor
    func testAdjustingGenreShowsPendingNotActive() throws {
        let app = launch(segment: "tune")
        let layout = isOpenLayout ? "layout.studio" : "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15))
        let form = app.scrollViews["tune.form"]
        XCTAssertTrue(form.waitForExistence(timeout: 8))

        // "rock" is the fourth chip (after pop, indie, indie pop), so it is on screen
        // before the moods and sliders.
        let rock = app.buttons["rock"]
        var tapped = false
        for _ in 0..<4 {
            if rock.exists && rock.isHittable {
                rock.tap()
                tapped = true
                break
            }
            form.swipeUp()
        }
        XCTAssertTrue(tapped, "Genre chip should be tappable in the tuner")

        var labels: [String] = []
        var becamePending = false
        for _ in 0..<16 {
            labels = app.descendants(matching: .any).matching(identifier: "tune.indicator")
                .allElementsBoundByIndex.map(\.label)
            if labels.contains(where: { $0.localizedCaseInsensitiveContains("pending") }) {
                becamePending = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(becamePending, "Changing a genre marks it pending: \(labels)")
        XCTAssertTrue(labels.contains { $0.localizedCaseInsensitiveContains("saved") },
                      "An untouched song-picking setting stays saved: \(labels)")
        XCTAssertTrue(shows(app, "Applies after this song"))
        save(app, isOpenLayout ? "open-tune-adjusted" : "closed-tune-adjusted")
    }
}
