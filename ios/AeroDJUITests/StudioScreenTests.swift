import XCTest
import UIKit

/// Integration tests for the playing screen in the Debug test station's capture mode
/// (`-AeroDJTestStation YES -AeroDJStudioCapture YES`): the real `PlayingScreen`, the test
/// station's `StudioPresentationModel` and the shared `PlaybackFixtures` snapshot.
///
/// The layout under test follows the device: an iPhone in portrait is the closed (compact)
/// player; an iPad's full window is the open layout, which since #542 is the 2.0 rail
/// (`FoldedPlayer` + `DuoVerticalRail`, `folded.systemBar`) rather than the two-zone Studio.
/// Accessibility text sizes on iPad keep the stacked Studio. Every test also saves a PNG
/// screenshot: as an XCTest attachment, and to `$STUDIO_SCREENSHOT_DIR` when CI sets it
/// (`TEST_RUNNER_STUDIO_SCREENSHOT_DIR`).
final class StudioScreenTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(segment: String? = nil, scenario: String? = nil, largeText: Bool = false,
                        dark: Bool = false, contentSize: String? = nil, reduceMotion: Bool = false,
                        restoreStationID: String? = nil,
                        musicAuthStatus: String? = nil,
                        orientation: UIDeviceOrientation = .portrait,
                        splitExample: String? = nil) -> XCUIApplication {
        // Probe the layout before this test's own launch: the probe launches and terminates
        // its own app, so it must never run while the test's app is up.
        _ = isOpenLayout
        return startApp(segment: segment, scenario: scenario, largeText: largeText, dark: dark,
                        contentSize: contentSize, reduceMotion: reduceMotion,
                        restoreStationID: restoreStationID, musicAuthStatus: musicAuthStatus,
                        orientation: orientation, splitExample: splitExample)
    }

    @MainActor
    private func startApp(segment: String? = nil, scenario: String? = nil, largeText: Bool = false,
                          dark: Bool = false, contentSize: String? = nil, reduceMotion: Bool = false,
                          restoreStationID: String? = nil,
                          musicAuthStatus: String? = nil,
                          orientation: UIDeviceOrientation = .portrait,
                          splitExample: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJResetContinuity", "YES"]
        if let segment { app.launchArguments += ["-AeroDJStudioCaptureSegment", segment] }
        if let scenario { app.launchArguments += ["-AeroDJStudioCaptureScenario", scenario] }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        } else if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        if dark { app.launchArguments += ["-AeroDJStudioCaptureDark", "YES"] }
        if reduceMotion { app.launchArguments += ["-AeroDJReduceMotion", "YES"] }
        if let restoreStationID {
            app.launchArguments += ["-AeroDJRestoreStationID", restoreStationID]
        }
        // DEBUG capture override for MusicAuthorization.currentStatus (default notDetermined).
        if let musicAuthStatus {
            app.launchArguments += ["-AeroDJMusicAuthStatus", musicAuthStatus]
        }
        if let splitExample {
            app.launchArguments += ["-AeroDJSplitExample", splitExample]
        }
        XCUIDevice.shared.orientation = orientation
        app.launch()
        // The capture view loads the station before rendering. Never screenshot on a timer:
        // wait for loading to end, and fail by name if the capture could not set up.
        let scenarioName = scenario ?? "playing"
        if scenarioName == "shell" {
            // Shell replaces capture.loading with capture.shell once auth is settled.
            // Waiting on the positive ready marker avoids a stale ProgressView match on iPad.
            let shell = app.descendants(matching: .any)["capture.shell"]
            XCTAssertTrue(shell.waitForExistence(timeout: 20),
                          "Studio capture shell did not appear after 20 s (scenario shell)\n\(visibleIdentifiers(app))\n\(app.debugDescription)")
        } else {
            let loading = app.descendants(matching: .any)["capture.loading"]
            let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
            XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed,
                           "Studio capture still loading after 20 s (scenario \(scenarioName))\n\(visibleIdentifiers(app))\n\(app.debugDescription)")
        }
        let failed = app.descendants(matching: .any)["capture.failed"]
        if failed.exists { XCTFail(failed.label) }
        return app
    }

    /// Which layout this simulator's window gets, read from the app itself rather than the
    /// device idiom: one probe launch of the default capture. Open is `layout.studio`, or
    /// (#542) the compact player drawing the unfolded rail (`folded.systemBar`), which is
    /// what a wide-and-tall iPad window gets now. A narrow iPad window or a wide iPhone
    /// window then picks the matching assertions.
    @MainActor
    private static var probedOpenLayout: Bool?

    @MainActor
    private var isOpenLayout: Bool {
        if let probed = Self.probedOpenLayout { return probed }
        let app = startApp()
        let any = app.descendants(matching: .any)
        let either = any.matching(NSPredicate(format: "identifier IN %@", ["layout.studio", "layout.compact"])).firstMatch
        XCTAssertTrue(either.waitForExistence(timeout: 15),
                      "Neither layout.studio nor layout.compact appeared\n\(visibleIdentifiers(app))")
        let open = any["layout.studio"].exists || any["folded.systemBar"].waitForExistence(timeout: 5)
        app.terminate()
        Self.probedOpenLayout = open
        return open
    }

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
        // #537 declutter: the closed player has no NEXT row, no Playing-from row (its Queue and
        // Tune moved into ⋯), and no Mic down chip (the MIC chip shows only while the DJ is live).
        let any = app.descendants(matching: .any)
        XCTAssertFalse(any["folded.outer.upNext"].exists, "#537: no NEXT row when closed")
        XCTAssertFalse(shows(app, "Playing from"), "#537: no Playing-from row when closed")
        XCTAssertFalse(app.buttons["queue.affordance"].exists, "#537: Queue is in ⋯, not on the closed screen")
        XCTAssertFalse(app.buttons["transport.tune"].exists, "#537: Tune is in ⋯, not on the closed screen")
        XCTAssertFalse(any["dj.micDown"].exists, "#537: no Mic down chip")
        XCTAssertTrue(any["station.title"].exists, "the header still names the station")
        save(app, "closed-compact")

        // #537: the removed rows' actions are reachable in ⋯.
        openClosedMore(app)
        XCTAssertTrue(closedMenuItem(app, "queue.affordance", labelPrefix: "Queue").waitForExistence(timeout: 5),
                      "Queue in ⋯\n\(app.debugDescription)")
        XCTAssertTrue(closedMenuItem(app, "transport.tune", labelPrefix: "Tune station").exists,
                      "Tune in ⋯\n\(app.debugDescription)")
        save(app, "closed-more-menu")
        closedMenuItem(app, "queue.affordance", labelPrefix: "Queue").tap()
        XCTAssertTrue(app.segmentedControls["workspace.segment"].waitForExistence(timeout: 5))
        XCTAssertTrue(shows(app, "Slow Burn"), "Up Next shows the fixture queue")
        save(app, "closed-queue-sheet")
    }

    /// #537: ⋯ on the closed reskin. Opens the menu; the caller checks its rows.
    @MainActor
    private func openClosedMore(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let more = app.buttons["folded.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "closed ⋯ missing\n\(app.debugDescription)", file: file, line: line)
        more.tap()
    }

    /// A ⋯ row by its identifier, or by its visible title where the system menu drops the identifier.
    @MainActor
    private func closedMenuItem(_ app: XCUIApplication, _ identifier: String, labelPrefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", identifier, labelPrefix)).firstMatch
    }

    /// Opens the queue from a closed layout: ⋯ → Queue on the reskin (#537). Phone layouts that
    /// still draw the toolbar (landscape centred column) keep their Queue button.
    @MainActor
    private func openClosedQueue(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let direct = app.buttons["queue.affordance"]
        if !(direct.exists && direct.isHittable) {
            openClosedMore(app, file: file, line: line)
        }
        let queue = closedMenuItem(app, "queue.affordance", labelPrefix: "Queue")
        XCTAssertTrue(queue.waitForExistence(timeout: 5), "Queue missing\n\(app.debugDescription)", file: file, line: line)
        queue.tap()
    }

    /// #542 (2.0 design, after build 49): the open window is the rail layout, not the
    /// two-zone Studio. Art and title left of the fold, the content column, then the rail
    /// with play/pause and skip. The queue opens as the workspace sheet.
    @MainActor
    func testOpenDuoIsTheRailLayout() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "queue")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(any["layout.studio"].exists, "the open window is the rail, not the two zones")
        XCTAssertFalse(any["arrangement.split"].exists, "the two-pane arrangement is not routed")
        XCTAssertTrue(any["folded.trackColumn"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(any["folded.contentColumn"].waitForExistence(timeout: 10), app.debugDescription)
        let bar = any["folded.systemBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the custom rail is missing\n\(app.debugDescription)")
        assertOneMatch(any, "folded.trackColumn", "open rail")
        assertOneMatch(any, "folded.contentColumn", "open rail")
        let track = any["folded.trackColumn"], content = any["folded.contentColumn"]
        XCTAssertLessThanOrEqual(track.frame.maxX, content.frame.minX + 1,
                                 "track \(track.frame) overlaps content \(content.frame)")
        XCTAssertLessThanOrEqual(content.frame.maxX, bar.frame.minX + 1,
                                 "content \(content.frame) overlaps the rail \(bar.frame)")
        XCTAssertTrue(shows(app, "Morning Light"), "Now Playing shows the fixture song")
        XCTAssertTrue(app.buttons["transport.playPause"].isHittable, "play/pause is on the rail")
        XCTAssertTrue(app.buttons["transport.skip"].isHittable, "skip is on the rail")
        XCTAssertTrue(app.buttons["folded.collapse"].isHittable)
        save(app, "open-rail")

        app.buttons["queue.affordance"].tap()
        XCTAssertTrue(app.segmentedControls["workspace.segment"].waitForExistence(timeout: 5))
        XCTAssertTrue(shows(app, "Slow Burn"), "Up Next shows the fixture queue")
        save(app, "open-rail-queue-sheet")
    }

    @MainActor
    func testOpenDuoTunerKeepsNowPlaying() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "tune")
        // #542: the rail layout opens Tune as the workspace sheet over the player.
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["tune.form"].waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(app.sliders.count, 2, "Energy and discovery are real sliders")
        XCTAssertTrue(app.buttons["transport.playPause"].exists, "Now Playing persists while tuning")
        save(app, "open-rail-tune")
    }

    @MainActor
    func testOpenDuoConnectionsAreTruthful() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "connections")
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["connections.list"].waitForExistence(timeout: 10))
        XCTAssertTrue(shows(app, "Calendar"))
        // No placeholder "manage" control.
        XCTAssertFalse(shows(app, "Tap to manage"))
        save(app, "open-rail-connections")
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
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["tune.form"].waitForExistence(timeout: 10))
        save(app, "open-rail-tune-dark")
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
            if c.scenario == "error" { assertReadingOrder(app, title: "Slow Burn", status: "DJ voice unavailable") }
            if c.scenario == "playbackFailed" { assertReadingOrder(app, title: "Morning Light", status: "couldn't play") }
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
        openClosedQueue(app)  // #537: Queue is in ⋯ on the closed reskin
        XCTAssertTrue(app.segmentedControls["workspace.segment"].waitForExistence(timeout: 5))
        XCTAssertTrue(shows(app, "Slow Burn"), "Up Next shows the fixture queue")
        save(app, "closed-queue-sheet-dark")
    }

    @MainActor
    func testOpenQueueDark() throws {
        try XCTSkipUnless(isOpenLayout, "Open layout is checked on an iPad-width simulator")
        let app = launch(segment: "queue", dark: true)
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["folded.systemBar"].waitForExistence(timeout: 10))
        app.buttons["queue.affordance"].tap()
        XCTAssertTrue(app.segmentedControls["workspace.segment"].waitForExistence(timeout: 5))
        XCTAssertTrue(shows(app, "Slow Burn"))
        save(app, "open-rail-queue-dark")
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
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollViews["connections.list"].waitForExistence(timeout: 10))
        XCTAssertTrue(shows(app, "Calendar"))
        save(app, "open-rail-connections-dark")
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
            // #542: open and closed are both the compact player now (rail when open).
            let layout = "layout.compact"
            XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15), c.scenario)
            if isOpenLayout { XCTAssertFalse(app.descendants(matching: .any)["layout.studio"].exists, c.scenario) }
            XCTAssertTrue(shows(app, c.expect), "\(c.scenario) shows \(c.expect)")
            XCTAssertEqual(app.buttons["transport.playPause"].exists, c.transport, c.scenario)
            if c.scenario == "denied" { XCTAssertTrue(app.buttons["Open Settings"].exists) }
            save(app, "\(prefix)-\(c.scenario)-dark")
            app.terminate()
        }
    }

    /// Owner, build 44 (#460): the unfolded Duo (640 pt, compact class) is fully horizontal.
    /// Artwork and the title stay left of the fold. The content column holds the horizontal
    /// scrubber, play/pause, skip, the station pill and the DJ chip. The rail holds
    /// collapse, more, queue and the sleep timer. Tune stays in More.
    @MainActor
    func testDuoWideControlsSitInTheRightRail() throws {
        try XCTSkipUnless(isOpenLayout, "The 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoWideReady")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(any["layout.studio"].exists, "the Duo split stays the compact player")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "no window\n\(app.debugDescription)")
        let windowFrame = try XCTUnwrap(settledFrame(of: window, "window"))
        let container = any["capture.duoContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), "Duo container missing\n\(app.debugDescription)")
        let box = try XCTUnwrap(settledFrame(of: container, "Duo container") {
            abs($0.width - 640) <= 1 && abs($0.height - 820) <= 1
        }, "container never settled at 640 × 820 pt: \(container.frame)")
        XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(box),
                      "container \(box) outside window \(windowFrame)")

        let track = any["folded.trackColumn"]
        let content = any["folded.contentColumn"]
        let bar = any["folded.systemBar"]
        let fold = any["folded.fold"]
        XCTAssertTrue(track.waitForExistence(timeout: 10), "track column missing\n\(app.debugDescription)")
        XCTAssertTrue(content.waitForExistence(timeout: 10), "content column missing\n\(app.debugDescription)")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "system bar missing\n\(app.debugDescription)")
        assertOneMatch(any, "folded.trackColumn", "duo wide")
        assertOneMatch(any, "folded.contentColumn", "duo wide")
        let trackFrame = try XCTUnwrap(settledFrame(of: track, "track column"))
        let contentFrame = try XCTUnwrap(settledFrame(of: content, "content column"))
        let barFrame = try XCTUnwrap(settledFrame(of: bar, "system bar") {
            $0.width >= 44 && $0.width <= 80
        }, "system bar never settled: \(bar.frame)")
        let foldFrame = try XCTUnwrap(settledFrame(of: fold, "fold"))

        let spinners = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"),
                                                 object: app.activityIndicators)
        XCTAssertEqual(XCTWaiter().wait(for: [spinners], timeout: 10), .completed,
                       "a spinner is still showing\n\(app.debugDescription)")

        let play = app.buttons["transport.playPause"]
        let skip = app.buttons["transport.skip"]
        let ready = any["dj.ready"]
        let scrubber = any["playback.progress"]
        let chip = any["station.title"]
        let more = any["folded.more"]
        let collapse = app.buttons["folded.collapse"]
        let sleep = app.buttons["folded.sleepTimer"]
        let queue = app.buttons["queue.affordance"]
        let dot = any["folded.liveDot"]
        // The up-next line also labels the current song "Morning Light". The title under test is the one in the track column.
        let title = track.staticTexts["Morning Light"]
        for (name, element) in [("play", play), ("skip", skip), ("ready", ready), ("scrubber", scrubber),
                                ("chip", chip), ("more", more), ("sleep", sleep), ("queue", queue),
                                ("collapse", collapse), ("dot", dot), ("title", title)] {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(name) missing\n\(app.debugDescription)")
        }
        let frames = "track \(trackFrame) content \(contentFrame) bar \(barFrame) fold \(foldFrame) "
            + "title \(title.frame) play \(play.frame) skip \(skip.frame) scrubber \(scrubber.frame) ready \(ready.frame)"
        XCTAssertLessThan(trackFrame.maxX, foldFrame.minX + 2, "artwork stays left of the fold: \(frames)")
        XCTAssertLessThan(title.frame.maxX, contentFrame.minX, "title stays left of the controls: \(frames)")
        XCTAssertGreaterThanOrEqual(contentFrame.minX, foldFrame.maxX - 2, "controls start right of the fold: \(frames)")
        XCTAssertLessThan(contentFrame.maxX, barFrame.minX + 8, "content column is left of the symbol bar: \(frames)")
        for (name, element) in [("scrubber", scrubber), ("chip", chip), ("ready", ready)] {
            XCTAssertGreaterThanOrEqual(element.frame.midX, contentFrame.minX - 4, "\(name) left the content column: \(frames)")
            XCTAssertLessThanOrEqual(element.frame.midX, contentFrame.maxX + 4, "\(name) left the content column: \(frames)")
        }
        for (name, element) in [("collapse", collapse), ("more", more), ("play", play), ("skip", skip),
                                ("queue", queue), ("sleep", sleep), ("dot", dot)] {
            XCTAssertGreaterThanOrEqual(element.frame.midX, barFrame.minX - 4, "\(name) left the symbol bar: \(frames)")
            XCTAssertLessThanOrEqual(element.frame.midX, barFrame.maxX + 4, "\(name) left the symbol bar: \(frames)")
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name) is under 44 pt wide: \(frames)")
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) is under 44 pt tall: \(frames)")
            XCTAssertFalse(contentFrame.insetBy(dx: -1, dy: -1).contains(element.frame),
                           "\(name) is still in the content column: \(frames)")
        }
        XCTAssertGreaterThan(dot.frame.minY, sleep.frame.maxY, "the live dot sits below the rail controls: \(frames)")
        XCTAssertEqual(dot.value as? String, "Off", "ready is not On Air: \(dot.label) \(String(describing: dot.value))")
        XCTAssertFalse(dot.label.localizedCaseInsensitiveContains("on air"), dot.label)
        XCTAssertGreaterThan(scrubber.frame.width, scrubber.frame.height, "the scrubber stays horizontal: \(frames)")
        XCTAssertGreaterThanOrEqual(play.frame.width, 44)
        XCTAssertGreaterThanOrEqual(collapse.frame.height, 44)
        XCTAssertGreaterThanOrEqual(more.frame.minY, barFrame.minY + 40, "chrome starts below the status clearance")
        let dial = any["duo.stationDial"]
        let late = app.buttons["duo.station.late-night"]
        XCTAssertTrue(dial.waitForExistence(timeout: 5), "station dial missing\n\(app.debugDescription)")
        XCTAssertTrue(late.waitForExistence(timeout: 5), "Late Night stop missing")
        XCTAssertGreaterThanOrEqual(dial.frame.midX, contentFrame.minX - 4, "the dial stays in the content column")
        XCTAssertLessThanOrEqual(dial.frame.midX, contentFrame.maxX + 4, "the dial stays in the content column")
        more.tap()
        let tune = app.buttons["transport.tune"]
        XCTAssertTrue(tune.waitForExistence(timeout: 5), "Tune stays in More\n\(app.debugDescription)")
        XCTAssertTrue(tune.isHittable, "Tune in More is not hittable")
        XCTAssertGreaterThanOrEqual(tune.frame.height, 44, "Tune in More is under 44 pt")
        assertMoreMenuInsideWindow(app)
        // A tap on the artwork column closes it without tuning.
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let tuneClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: tune)
        XCTAssertEqual(XCTWaiter().wait(for: [tuneClosed], timeout: 5), .completed, "More did not close")
        let timeline = app.buttons["duo.upNext"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "up-next timeline missing\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(timeline.frame.midX, contentFrame.minX - 4, "timeline stays in the content column")
        XCTAssertLessThanOrEqual(timeline.frame.midX, contentFrame.maxX + 4, "timeline stays in the content column")
        XCTAssertTrue(timeline.label.contains("Morning Light"))
        XCTAssertTrue(timeline.label.contains("DJ break after this song"))
        XCTAssertTrue(timeline.label.contains("Slow Burn"))
        timeline.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "tapping the timeline opens the queue")
        app.buttons["Done"].tap()
        late.tap()
        let opened = any["duo.openedStation"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
        XCTAssertEqual(opened.label, "late-night", "the dial calls the station-open action")
        XCTAssertEqual(container.frame.width, box.width, accuracy: 0.5, "container resized before the screenshot")
        save(app, "duo-wide-ready")
    }

    /// #492 (#465 item 5): opening the phone. The capture starts at the folded phone
    /// container (compact) and unfolds to the 640×820 Duo (regular), which since #542 is the
    /// 2.0 rail layout. Playback, the selected station, the stored scroll anchor and the load
    /// count stay. Row 4 on screen is checked while folded; unfolded, row 4 must exist.
    @MainActor
    func testOpeningThePhoneKeepsPlaybackScrollAndStation() throws {
        try XCTSkipUnless(isOpenLayout, "The unfolded 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoContinuity")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(any["layout.studio"].exists, "the folded phone stays the compact player")
        XCTAssertEqual(readout(app, "continuity.pose"), "folded")
        XCTAssertEqual(readout(app, "continuity.sizeClass"), "compact")
        waitReadout(app, "continuity.station", "morning-calm")
        waitReadout(app, "continuity.playback", "playing|1")
        waitReadout(app, "continuity.loads", "1")
        XCTAssertEqual(callLabel(app), "0/0")
        let title = any["station.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(title.label.contains("Morning Calm"), title.label)
        let play = app.buttons["transport.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let playLabel = play.label
        let unfold = app.buttons["continuity.unfold"]
        let scrollTo = app.buttons["continuity.scrollToRow"]
        XCTAssertTrue(unfold.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(scrollTo.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(unfold.frame.width, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(unfold.frame.height, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(scrollTo.frame.height, 44 - 0.01)

        let container = any["continuity.container"]
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        _ = settledFrame(of: container, "folded container") {
            abs($0.width - 390) <= 1 && abs($0.height - 844) <= 1
        }
        scrollTo.tap()
        let anchor = any["continuity.anchor"]
        // Identifier only: the anchor readout's label is also "continuity.row.4", so the
        // subscript (identifier or label) matched two elements.
        let row = any.matching(NSPredicate(format: "identifier == %@", "continuity.row.4")).element
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "continuity.row.4"),
                                                 object: anchor)
        XCTAssertEqual(XCTWaiter().wait(for: [scrolled], timeout: 5), .completed,
                       "the scroll anchor did not move to row 4: \(anchor.label)\n\(app.debugDescription)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowOnScreen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [rowOnScreen], timeout: 5), .completed,
                       "row 4 is not on screen after scrolling: \(row.frame)")
        save(app, "duo-continuity-folded")

        let loads = readout(app, "continuity.loads")
        let playback = readout(app, "continuity.playback")
        unfold.tap()
        XCTAssertEqual(readout(app, "continuity.pose"), "unfolded")
        XCTAssertEqual(readout(app, "continuity.sizeClass"), "regular",
                       "opening the phone changes the size class")
        _ = settledFrame(of: container, "unfolded container") {
            abs($0.width - 640) <= 1 && abs($0.height - 820) <= 1
        }
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 10),
                      "640 pt stays the compact player at either size class\n\(app.debugDescription)")
        XCTAssertFalse(any["layout.studio"].exists)
        // #542: regular width at 640 × 820 is the 2.0 rail layout at either size class.
        // The two-pane arrangement is no longer routed.
        XCTAssertTrue(any["folded.trackColumn"].waitForExistence(timeout: 10),
                      "the unfolded Duo is the rail layout\n\(app.debugDescription)")
        XCTAssertTrue(any["folded.systemBar"].waitForExistence(timeout: 10),
                      "the unfolded Duo draws the custom rail\n\(app.debugDescription)")
        XCTAssertFalse(any["arrangement.split"].exists, "the two-pane arrangement is not routed")
        let held = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "continuity.row.4"),
                                             object: anchor)
        // The stored anchor survives the switch. The rail's track column is the player
        // scroll and carries the continuity rows, so row 4 exists there too.
        XCTAssertEqual(XCTWaiter().wait(for: [held], timeout: 5), .completed,
                       "the stored scroll anchor was lost: \(anchor.label)")
        XCTAssertTrue(any["continuity.scroller"].waitForExistence(timeout: 5),
                      "the rail layout has no continuity scroller\n\(app.debugDescription)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "row 4 is missing from the rail layout")
        XCTAssertEqual(readout(app, "continuity.station"), "morning-calm")
        XCTAssertTrue(any["station.title"].label.contains("Morning Calm"))
        XCTAssertEqual(readout(app, "continuity.playback"), playback)
        XCTAssertEqual(play.label, playLabel, "playback was restarted")
        XCTAssertEqual(readout(app, "continuity.loads"), loads, "opening the phone reloaded")
        assertCallsStayZero(app, "opening the phone must not search or play")
        save(app, "duo-continuity-unfolded")
    }

    @MainActor
    private func readout(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier) missing\n\(app.debugDescription)")
        return element.label
    }

    /// Scene storage written by the player can land a frame after the chrome exists.
    @MainActor
    private func waitReadout(_ app: XCUIApplication, _ identifier: String, _ expected: String) {
        let element = app.descendants(matching: .any)[identifier]
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [match], timeout: 5), .completed,
                       "\(identifier) was \(element.exists ? element.label : "missing"), expected \(expected)\n\(app.debugDescription)")
    }

    /// The live dot follows the published DJ state on the unfolded rail. Idle and ready stay off.
    /// Speaking lights it, and that frame is the screenshot next to mockup 02.
    @MainActor
    func testDuoRailLiveDotFollowsSpeaking() throws {
        try XCTSkipUnless(isOpenLayout, "The 640 × 820 pt container needs an iPad-size simulator window")
        for scenario in ["duoWideEmpty", "duoWideReady"] {
            let app = launch(scenario: scenario)
            let dot = app.descendants(matching: .any)["folded.liveDot"]
            XCTAssertTrue(dot.waitForExistence(timeout: 15), "\(scenario) live dot missing\n\(app.debugDescription)")
            XCTAssertEqual(dot.value as? String, "Off", "\(scenario) lit the dot: \(dot.label)")
            XCTAssertFalse(dot.label.localizedCaseInsensitiveContains("on air"), "\(scenario) \(dot.label)")
            app.terminate()
        }
        let app = launch(scenario: "duoWideSpeaking")
        let any = app.descendants(matching: .any)
        let dot = any["folded.liveDot"]
        let bar = any["folded.systemBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(dot.waitForExistence(timeout: 5), "speaking live dot missing\n\(app.debugDescription)")
        XCTAssertEqual(dot.value as? String, "On Air", "speaking did not light the dot: \(dot.label) \(String(describing: dot.value))")
        guard let barFrame = settledFrame(of: bar, "system bar"), let dotFrame = settledFrame(of: dot, "live dot") else { return }
        XCTAssertGreaterThanOrEqual(dotFrame.midX, barFrame.minX - 4, "lit dot left the rail")
        XCTAssertTrue(app.buttons["folded.collapse"].isHittable)
        XCTAssertTrue(app.buttons["folded.sleepTimer"].isHittable)
        XCTAssertTrue(app.buttons["queue.affordance"].isHittable)
        let play = app.buttons["transport.playPause"]
        let skip = app.buttons["transport.skip"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "play missing from the speaking rail")
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "skip missing from the speaking rail")
        XCTAssertGreaterThanOrEqual(play.frame.midX, barFrame.minX - 4, "play left the rail")
        XCTAssertGreaterThanOrEqual(skip.frame.midX, barFrame.minX - 4, "skip left the rail")
        XCTAssertGreaterThanOrEqual(play.frame.width, 44)
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        XCTAssertGreaterThanOrEqual(skip.frame.width, 44)
        XCTAssertGreaterThanOrEqual(skip.frame.height, 44)
        if let content = settledFrame(of: any["folded.contentColumn"], "content column") {
            XCTAssertFalse(content.insetBy(dx: -1, dy: -1).contains(play.frame),
                           "play is still in the content column")
            XCTAssertFalse(content.insetBy(dx: -1, dy: -1).contains(skip.frame),
                           "skip is still in the content column")
        }
        save(app, "duo-wide-speaking")
        let more = app.buttons["folded.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More missing\n\(app.debugDescription)")
        more.tap()
        assertMoreMenuInsideWindow(app)
        save(app, "duo-wide-more-popover")
    }

    /// Accessibility text makes each row taller. The menu still stays inside the window.
    @MainActor
    func testDuoMoreMenuStaysInsideTheWindowAtLargeText() throws {
        try XCTSkipUnless(isOpenLayout, "The 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoWideSpeaking", largeText: true)
        let more = app.buttons["folded.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 15), "More missing at large text\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        more.tap()
        assertMoreMenuInsideWindow(app)
    }

    /// Collapse leaves the unfolded rail and shows the centred column. Playback stays up.
    @MainActor
    func testCollapseUnfoldedRailShowsTheFoldedColumn() throws {
        try XCTSkipUnless(isOpenLayout, "The 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoWideReady")
        let bar = app.descendants(matching: .any)["folded.systemBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), app.debugDescription)
        let collapse = app.buttons["folded.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(collapse.isHittable)
        XCTAssertGreaterThanOrEqual(collapse.frame.width, 44)
        XCTAssertGreaterThanOrEqual(collapse.frame.height, 44)
        collapse.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: bar)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed,
                       "collapse left the unfolded rail up\n\(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["folded.wideColumn"].waitForExistence(timeout: 5),
                      "folded column missing\n\(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["folded.systemBar"].exists)
        XCTAssertTrue(app.buttons["transport.playPause"].exists, "playback stays on screen")
    }

    /// #502: the unfolded Duo (640 × 820 pt) with the DJ on air, so the owner can see that
    /// layout first. Same container and fixtures as `duoWideReady`; the DJ is `.speaking`
    /// with the timer frozen at 0:12. The track column keeps the art (`keepArtVisible`);
    /// the orb is the content-column visualizer, not an orb-only art card.
    @MainActor
    func testDuoWideOnAirKeepsArtAndShowsTheContentColumnOrb() throws {
        try XCTSkipUnless(isOpenLayout, "The 640 × 820 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoWideOnAir")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(any["layout.studio"].exists, "the Duo split stays the compact player")

        let container = any["capture.duoContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), "Duo container missing\n\(app.debugDescription)")
        XCTAssertNotNil(settledFrame(of: container, "Duo container") {
            abs($0.width - 640) <= 1 && abs($0.height - 820) <= 1
        }, "container never settled at 640 × 820 pt: \(container.frame)")

        XCTAssertTrue(any["folded.trackColumn"].waitForExistence(timeout: 10),
                      "track column missing\n\(app.debugDescription)")
        XCTAssertTrue(any["folded.contentColumn"].waitForExistence(timeout: 10),
                      "content column missing\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Morning Light"), "The song stays on screen")
        let bar = any["folded.systemBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "system bar missing\n\(app.debugDescription)")
        let play = app.buttons["transport.playPause"]
        let skip = app.buttons["transport.skip"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "play missing from the on-air rail")
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "skip missing from the on-air rail")
        if let barFrame = settledFrame(of: bar, "system bar"),
           let contentFrame = settledFrame(of: any["folded.contentColumn"], "content column") {
            XCTAssertGreaterThanOrEqual(play.frame.midX, barFrame.minX - 4, "play left the rail")
            XCTAssertGreaterThanOrEqual(skip.frame.midX, barFrame.minX - 4, "skip left the rail")
            XCTAssertFalse(contentFrame.insetBy(dx: -1, dy: -1).contains(play.frame),
                           "play is still in the content column")
            XCTAssertFalse(contentFrame.insetBy(dx: -1, dy: -1).contains(skip.frame),
                           "skip is still in the content column")
        }

        let onAir = any["dj.onAir"]
        XCTAssertTrue(onAir.waitForExistence(timeout: 5), "dj.onAir missing\n\(app.debugDescription)")
        XCTAssertFalse(any["dj.ready"].exists, "On Air replaces the ready line")
        let frozen = any.matching(NSPredicate(format: "label == %@", "On Air, 0:12")).firstMatch
        XCTAssertTrue(frozen.exists, "The capture freezes the ON AIR timer at 0:12: \(onAir.label)")

        XCTAssertTrue(any["folded.artCard.artwork"].waitForExistence(timeout: 5),
                      "the Duo track column keeps the art while on air\n\(app.debugDescription)")
        XCTAssertFalse(any["folded.artCard.orb"].exists,
                       "keepArtVisible leaves the art card as art, not the orb-only card")
        XCTAssertTrue(any["folded.visualizer"].waitForExistence(timeout: 5),
                      "the content-column orb is missing\n\(app.debugDescription)")
        save(app, "duo-wide-onair")
    }

    /// Every visible More row is at least 44 pt and fully inside the window, and each
    /// row's label frame lies inside the panel. The row's own frame can sit inside the
    /// window while the title runs past the panel's trailing edge. The label child exists
    /// because `startApp` launches with `-AeroDJStudioCapture YES`.
    @MainActor
    private func assertMoreMenuInsideWindow(_ app: XCUIApplication, file: StaticString = #filePath,
                                            line: UInt = #line) {
        let menu = app.descendants(matching: .any)["folded.moreMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5),
                      "More menu did not open\n\(app.debugDescription)", file: file, line: line)
        let window = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
        let panel = menu.frame.insetBy(dx: -0.5, dy: -0.5)
        XCTAssertTrue(window.contains(menu.frame),
                      "More menu left the window \(menu.frame) vs \(window)", file: file, line: line)
        // Rows only. Under the capture launch a `.contain` row also exposes its label
        // container as a nested Button carrying the title's `<row>.label` identifier; that
        // is the title checked below, not another row.
        let rows = menu.buttons
            .matching(NSPredicate(format: "NOT (identifier ENDSWITH %@)", ".label"))
            .allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        XCTAssertFalse(rows.isEmpty, "More menu has no visible rows\n\(app.debugDescription)",
                       file: file, line: line)
        for row in rows {
            XCTAssertGreaterThanOrEqual(row.frame.height, 44, "\(row.identifier) is under 44 pt",
                                        file: file, line: line)
            XCTAssertTrue(window.contains(row.frame),
                          "\(row.identifier) left the window \(row.frame) vs \(window)",
                          file: file, line: line)
            let labelID = "\(row.identifier).label"
            let labels = menu.descendants(matching: .staticText)
                .matching(NSPredicate(format: "identifier == %@", labelID))
                .allElementsBoundByIndex
                .filter { $0.exists && !$0.frame.isEmpty }
            XCTAssertFalse(labels.isEmpty,
                           "\(row.identifier) has no label frame\n\(app.debugDescription)",
                           file: file, line: line)
            for label in labels {
                XCTAssertTrue(panel.contains(label.frame),
                              "\(row.identifier) label \(label.label) frame \(label.frame) left the panel \(menu.frame)",
                              file: file, line: line)
            }
        }
    }

    /// The element's frame once it is non-empty, equal (±0.5 pt) on two polls in a row and
    /// accepted by `isFinal`; nil after `timeout`. Polls on the run loop, never a fixed sleep
    /// before a screenshot.
    @MainActor
    private func settledFrame(of element: XCUIElement, _ name: String, timeout: TimeInterval = 10,
                              poll: TimeInterval = 0.25,
                              isFinal: (CGRect) -> Bool = { _ in true }) -> CGRect? {
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5
                && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
        }
        let deadline = Date().addingTimeInterval(timeout)
        var last: CGRect?
        while Date() < deadline {
            let frame = element.exists ? element.frame : .null
            if !frame.isNull, !frame.isEmpty, isFinal(frame), let last, same(last, frame) {
                return frame
            }
            last = (frame.isNull || frame.isEmpty || !isFinal(frame)) ? nil : frame
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
        XCTFail("\(name) frame did not settle within \(timeout) s (last \(element.frame))")
        return nil
    }

    // MARK: Build 51: the open Duo's landscape window and the sidebar-open detail (-Atlas)

    /// Waits for the 820 × 640 pt open-Duo container and returns its settled frame.
    @MainActor
    private func openDuoContainer(_ app: XCUIApplication) -> (window: CGRect, box: CGRect)? {
        let any = app.descendants(matching: .any)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "no window\n\(app.debugDescription)")
        guard let windowFrame = settledFrame(of: window, "window") else { return nil }
        let container = any["capture.duoOpenContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 10), "open Duo container missing\n\(app.debugDescription)")
        guard let box = settledFrame(of: container, "open Duo container", isFinal: {
            abs($0.width - 820) <= 1 && abs($0.height - 640) <= 1
        }) else { return nil }
        XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(box), "container \(box) outside window \(windowFrame)")
        return (windowFrame, box)
    }

    /// Play/Pause, Skip and the scrubber are on screen: hittable, inside the window and inside
    /// the 820 × 640 container. Play and Skip keep their 44 pt targets.
    @MainActor
    private func assertTransportOnScreen(_ app: XCUIApplication, window: CGRect, box: CGRect, _ context: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let any = app.descendants(matching: .any)
        let checks: [(String, XCUIElement)] = [("play", app.buttons["transport.playPause"]),
                                                ("skip", app.buttons["transport.skip"]),
                                                ("scrubber", any["playback.progress"])]
        for (name, element) in checks {
            XCTAssertTrue(element.waitForExistence(timeout: 8), "\(name) missing in \(context)\n\(app.debugDescription)",
                          file: file, line: line)
            guard let frame = settledFrame(of: element, "\(name) in \(context)") else { continue }
            let detail = "\(context) \(name) \(frame) container \(box) window \(window)"
            XCTAssertTrue(element.isHittable, "\(name) is not hittable: \(detail)", file: file, line: line)
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(frame), "\(name) is outside the window: \(detail)",
                          file: file, line: line)
            XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(frame), "\(name) is outside the container: \(detail)",
                          file: file, line: line)
            if name != "scrubber" {
                XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) under 44 pt wide: \(detail)", file: file, line: line)
                XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) under 44 pt tall: \(detail)", file: file, line: line)
            }
        }
    }

    /// Play and Skip sit in the rail, which is the container's trailing column.
    @MainActor
    private func assertTransportInRail(_ app: XCUIApplication, box: CGRect, _ context: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.descendants(matching: .any)["folded.systemBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the rail is missing in \(context)\n\(app.debugDescription)",
                      file: file, line: line)
        guard let barFrame = settledFrame(of: bar, "rail in \(context)") else { return }
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(barFrame), "rail \(barFrame) outside container \(box)",
                      file: file, line: line)
        XCTAssertGreaterThan(barFrame.midX, box.midX, "the rail is not on the trailing side: \(barFrame) in \(box)",
                             file: file, line: line)
        for identifier in ["transport.playPause", "transport.skip", "queue.affordance"] {
            let frame = app.buttons[identifier].frame
            XCTAssertTrue(frame.midX >= barFrame.minX - 4 && frame.midX <= barFrame.maxX + 4,
                          "\(identifier) \(frame) is not in the rail \(barFrame) (\(context))", file: file, line: line)
        }
    }

    /// Build 51 issue 1: the open Duo held sideways (820 × 640 pt with its navigation bar) showed
    /// the centred column with the scrubber cut off and no Play/Skip. Now it is the rail; after
    /// Collapse the transport is pinned on screen, ⋯ and Show rail sit in the top header row,
    /// and Show rail brings the rail back.
    @MainActor
    func testOpenDuoLandscapeKeepsTheTransportOnScreenWithAndWithoutTheRail() throws {
        try XCTSkipUnless(isOpenLayout, "The 820 × 640 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoLandscape")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        guard let found = openDuoContainer(app) else { return }
        let (window, box) = found
        XCTAssertTrue(any["folded.trackColumn"].waitForExistence(timeout: 10),
                      "landscape is not the two-halves rail layout\n\(app.debugDescription)")
        assertTransportInRail(app, box: box, "landscape rail")
        assertTransportOnScreen(app, window: window, box: box, "landscape rail")
        save(app, "open-landscape-rail")

        let collapse = app.buttons["folded.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5) && collapse.isHittable, app.debugDescription)
        collapse.tap()
        let bar = any["folded.systemBar"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: bar)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "collapse left the rail up")
        XCTAssertTrue(any["folded.wideColumn"].waitForExistence(timeout: 5), app.debugDescription)
        assertTransportOnScreen(app, window: window, box: box, "landscape, rail collapsed")
        let expand = app.buttons["folded.expandRail"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "no way back to the rail\n\(app.debugDescription)")
        guard let expandFrame = settledFrame(of: expand, "Show rail") else { return }
        XCTAssertTrue(expand.isHittable)
        XCTAssertLessThan(expandFrame.midY, box.minY + box.height / 3, "Show rail is not in the top header row: \(expandFrame)")
        XCTAssertGreaterThan(expandFrame.midX, box.midX, "Show rail is not on the trailing side: \(expandFrame)")
        save(app, "open-rail-collapsed-landscape")

        expand.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "Show rail did not bring the rail back\n\(app.debugDescription)")
        app.terminate()
    }

    /// Build 51 issue 2: with the Stations sidebar open the player fell back to the old centred
    /// layout (Playing-from bar, Queue and Tune buttons) and lost the rail. The ~500 pt detail now
    /// keeps the rail, with Play, Skip and Queue on it, and the scrubber stays on screen.
    @MainActor
    func testOpenDuoWithTheSidebarOpenKeepsTheRail() throws {
        try XCTSkipUnless(isOpenLayout, "The 820 × 640 pt container needs an iPad-size simulator window")
        let app = launch(scenario: "duoSidebar")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        guard let found = openDuoContainer(app) else { return }
        let (window, box) = found
        let sidebar = any["split.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the Stations sidebar is not open\n\(app.debugDescription)")
        XCTAssertTrue(any["folded.railColumn"].waitForExistence(timeout: 10),
                      "the sidebar-open detail is not the rail column\n\(app.debugDescription)")
        XCTAssertFalse(any["folded.wideColumn"].exists, "the old centred layout is back")
        assertTransportInRail(app, box: box, "sidebar open")
        assertTransportOnScreen(app, window: window, box: box, "sidebar open")
        if let sidebarFrame = settledFrame(of: sidebar, "sidebar"),
           let barFrame = settledFrame(of: any["folded.systemBar"], "rail") {
            XCTAssertGreaterThanOrEqual(barFrame.minX, sidebarFrame.maxX - 1, "the rail overlaps the sidebar")
        }
        save(app, "open-sidebar-rail")
        app.terminate()
    }

    /// 640 × 820, nothing playing and playing. Every control in the content column is
    /// hittable and its frame sits inside the window and inside that column.
    @MainActor
    func testDuoWideColumnControlsStayInsideTheWindow() throws {
        try XCTSkipUnless(isOpenLayout, "The 640 × 820 pt container needs an iPad-size simulator window")
        assertDuoColumnControls(scenario: "duoWideEmpty", names: ["search": "playback.searchAppleMusic",
                                                                   "station": "station.title"])
        assertDuoColumnControls(scenario: "duoWideReady", names: ["station": "station.title",
                                                                  "dj": "dj.ready",
                                                                  "scrubber": "playback.progress"],
                                 transportInRail: true)
    }

    /// `names` maps a short label to an accessibility identifier in the content column.
    /// `transportInRail` is for a playing Duo: play and skip must sit in the rail, not in the column.
    @MainActor
    private func assertDuoColumnControls(scenario: String, names: [String: String],
                                         transportInRail: Bool = false) {
        let app = launch(scenario: scenario)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "no window\n\(app.debugDescription)")
        guard let windowFrame = settledFrame(of: window, "window") else { return }
        let container = any["capture.duoContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 5), "Duo container missing\n\(app.debugDescription)")
        guard let box = settledFrame(of: container, "Duo container", isFinal: {
            abs($0.width - 640) <= 1 && abs($0.height - 820) <= 1
        }) else { return }
        XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(box),
                      "container \(box) outside window \(windowFrame)")
        assertOneMatch(any, "folded.contentColumn", scenario)
        assertOneMatch(any, "folded.trackColumn", scenario)
        let column = any["folded.contentColumn"]
        XCTAssertTrue(column.waitForExistence(timeout: 10), "content column missing\n\(app.debugDescription)")
        guard let columnFrame = settledFrame(of: column, "content column") else { return }
        for (name, identifier) in names {
            let element = any[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 8),
                          "\(name) missing in \(scenario)\n\(app.debugDescription)")
            guard let frame = settledFrame(of: element, name) else { continue }
            let detail = "\(scenario) \(name) \(frame) window \(windowFrame) column \(columnFrame)"
            XCTAssertTrue(element.isHittable, "\(name) is not hittable: \(detail)")
            XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(frame),
                          "\(name) is outside the window: \(detail)")
            XCTAssertTrue(columnFrame.insetBy(dx: -1, dy: -1).contains(frame),
                          "\(name) is outside the content column: \(detail)")
        }
        if transportInRail {
            let bar = any["folded.systemBar"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "system bar missing in \(scenario)")
            guard let barFrame = settledFrame(of: bar, "system bar") else { return }
            for (name, identifier) in [("play", "transport.playPause"), ("skip", "transport.skip")] {
                let element = app.buttons[identifier]
                XCTAssertTrue(element.waitForExistence(timeout: 5),
                              "\(name) missing from the rail in \(scenario)\n\(app.debugDescription)")
                guard let frame = settledFrame(of: element, name) else { continue }
                XCTAssertTrue(element.isHittable, "\(name) is not hittable in the rail: \(scenario) \(frame)")
                XCTAssertGreaterThanOrEqual(frame.midX, barFrame.minX - 4, "\(name) left the rail in \(scenario)")
                XCTAssertLessThanOrEqual(frame.midX, barFrame.maxX + 4, "\(name) left the rail in \(scenario)")
                XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) is under 44 pt wide in \(scenario)")
                XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) is under 44 pt tall in \(scenario)")
                XCTAssertFalse(columnFrame.insetBy(dx: -1, dy: -1).contains(frame),
                               "\(name) is still in the content column in \(scenario)")
            }
        }
        app.terminate()
    }

    /// The column id names one container. More than one match means the id was copied onto its controls.
    @MainActor
    private func assertOneMatch(_ any: XCUIElementQuery, _ identifier: String, _ context: String) {
        let matches = any.matching(NSPredicate(format: "identifier == %@", identifier))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10),
                      "\(identifier) missing in \(context)")
        XCTAssertEqual(matches.count, 1, "\(identifier) matched \(matches.count) elements in \(context)")
    }

    /// Open (since #542 the rail layout) and folded: a quiet, static "DJ break after this
    /// song" line shows (Fry, #161), and nothing says On Air.
    @MainActor
    func testReadyStateShowsNoBreakText() throws {
        let app = launch(scenario: "breakReady")
        let layout = "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15),
                      "ready capture did not show \(layout):\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Morning Light"), "The song stays on screen")
        // `shows` reads XCUIElement.label, which is the visible text and the accessibility label.
        if isOpenLayout {
            // #542: the open window is the rail layout, which shows the same quiet ready line
            // as the folded player in its content column, and never On Air.
            XCTAssertTrue(app.descendants(matching: .any)["folded.contentColumn"].waitForExistence(timeout: 10),
                          "the open window is the rail layout\n\(app.debugDescription)")
            XCTAssertFalse(app.descendants(matching: .any)["layout.studio"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["dj.ready"].exists, "the rail's .ready shows its quiet line")
            XCTAssertFalse(shows(app, "On Air"), ".ready never claims the DJ is speaking")
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["dj.ready"].exists, "folded .ready shows its quiet line")
            XCTAssertFalse(shows(app, "On Air"), ".ready never claims the DJ is speaking")
            XCTAssertFalse(app.descendants(matching: .any)["folded.contentColumn"].exists,
                           "a phone-width layout does not use the Duo content column")
            XCTAssertFalse(app.descendants(matching: .any)["folded.systemBar"].exists,
                           "a phone-width layout does not use the Duo symbol bar")
            XCTAssertFalse(app.descendants(matching: .any)["duo.stationDial"].exists,
                           "a phone-width layout does not show the station dial")
            XCTAssertFalse(app.buttons["duo.upNext"].exists,
                           "a phone-width layout does not show the up-next timeline")
            let play = app.buttons["transport.playPause"]
            let ready = app.descendants(matching: .any)["dj.ready"]
            XCTAssertGreaterThan(play.frame.minY, ready.frame.maxY,
                                 "phone controls stay under the DJ line, not beside it")
        }
        XCTAssertTrue(app.buttons["transport.playPause"].exists)
        save(app, isOpenLayout ? "open-ready-no-break" : "closed-ready-line")
    }

    @MainActor
    func testAX5LightAppearance() throws {
        let app = launch(contentSize: Self.ax5)
        let layout = isOpenLayout ? "layout.studioStacked" : "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15),
                      "\(layout) expected at AX5:\n\(app.debugDescription)")
        if isOpenLayout {
            XCTAssertFalse(app.descendants(matching: .any)["layout.studio"].exists, "no two zones at AX sizes")
        }
        XCTAssertTrue(shows(app, "Morning Light"))
        let play = app.buttons["transport.playPause"]
        XCTAssertTrue(isOpenLayout ? play.exists : play.isHittable, "Play/pause stays reachable at AX5")
        assertReadingOrder(app, title: "Morning Light")
        save(app, isOpenLayout ? "open-ax5" : "closed-ax5")
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
        assertReadingOrder(app, title: "Morning Light")
        save(app, isOpenLayout ? "open-ax5-dark" : "closed-ax5-dark")
    }

    /// #310 / #326: at AX5 on a phone the DJ status moves out of the scrolling upper part and
    /// is pinned above the scrubber. The other AX5 captures have an idle DJ, so this is the one
    /// that draws the ON AIR pill there: on screen without scrolling, above the scrubber and
    /// the transport, read after the title. The capture freezes the pill's timer at "0:12"
    /// (`StudioCaptureOnAir`), so the screenshot is the same every run.
    @MainActor
    func testAX5OnAirPinnedAboveScrubber() throws {
        try XCTSkipIf(isOpenLayout, "The pinned status is the phone-width folded player at AX5")
        let app = launch(scenario: "onAir", contentSize: Self.ax5)
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15),
                      "layout.compact expected at AX5:\n\(app.debugDescription)")
        let any = app.descendants(matching: .any)
        let onAir = any["dj.onAir"]
        let scrubber = any["playback.progress"]
        let play = app.buttons["transport.playPause"]
        for (name, element) in [("onAir", onAir), ("scrubber", scrubber), ("play", play)] {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(name) missing at AX5\n\(app.debugDescription)")
        }
        XCTAssertTrue(shows(app, "Morning Light"))
        XCTAssertFalse(any["dj.ready"].exists, "On Air replaces the ready line")
        guard let pill = settledFrame(of: onAir, "dj.onAir") else { return }
        let window = app.windows.firstMatch.frame
        let frames = "window \(window) onAir \(pill) scrubber \(scrubber.frame) play \(play.frame)"
        XCTAssertGreaterThanOrEqual(pill.minY, window.minY, "ON AIR on screen without scrolling: \(frames)")
        XCTAssertLessThanOrEqual(pill.maxY, window.maxY, "ON AIR on screen without scrolling: \(frames)")
        XCTAssertLessThanOrEqual(pill.maxY, scrubber.frame.minY + 1, "ON AIR pinned above the scrubber: \(frames)")
        XCTAssertLessThan(pill.minY, play.frame.minY, "ON AIR above the transport: \(frames)")
        XCTAssertTrue(play.isHittable, "Play/pause stays reachable at AX5")
        // #345 review: the pinned pill must not cover the TEST STATION tag (capture mode
        // always shows it; a real station has none, so only check it when it exists).
        let tag = any["folded.testStation"]
        if tag.exists {
            let chip = tag.frame
            let both = "\(frames) testStation \(chip)"
            XCTAssertFalse(chip.intersects(pill), "TEST STATION clear of ON AIR: \(both)")
            XCTAssertLessThanOrEqual(chip.maxY, pill.minY, "TEST STATION above ON AIR: \(both)")
            XCTAssertGreaterThanOrEqual(chip.minY, window.minY, "TEST STATION on screen: \(both)")
        }
        assertReadingOrder(app, title: "Morning Light", status: "On Air")
        let frozen = any.matching(NSPredicate(format: "label == %@", "On Air, 0:12")).firstMatch
        XCTAssertTrue(frozen.exists, "The capture freezes the ON AIR timer at 0:12: \(onAir.label)")
        save(app, "closed-ax5-onair")
    }

    /// #435 n1 (#434): default-size on-air stills, so the orb-only art card is visible.
    /// `closed-ax5-onair` often hides the card (`includesArt: false` at AX5). The existing
    /// `onAir` scenario is unchanged (frozen ON AIR timer at 0:12). Closed (phone) is the
    /// folded player, where `FoldedArtCard` swaps art for the orb. Open (iPad) is the rail
    /// layout since #542, which keeps the art (`keepArtVisible`) and shows On Air.
    @MainActor
    func testDefaultOnAirShowsOrbOnlyArtCard() throws {
        let app = launch(scenario: "onAir")
        let layout = "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15),
                      "\(layout) expected at default size:\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Morning Light"), "The song stays on screen")
        XCTAssertTrue(app.buttons["transport.playPause"].exists)
        let any = app.descendants(matching: .any)
        if isOpenLayout {
            // #542: the rail layout keeps the art in the track column and shows On Air,
            // the same as the 640 × 820 Duo on air (testDuoWideOnAir…).
            XCTAssertFalse(any["layout.studio"].exists)
            XCTAssertTrue(any["folded.trackColumn"].waitForExistence(timeout: 10), app.debugDescription)
            let onAir = any["dj.onAir"]
            XCTAssertTrue(onAir.waitForExistence(timeout: 5), "dj.onAir missing\n\(app.debugDescription)")
            XCTAssertFalse(any["dj.ready"].exists, "On Air replaces the ready line")
            XCTAssertTrue(any["folded.artCard.artwork"].waitForExistence(timeout: 5),
                          "the rail's track column keeps the art while on air\n\(app.debugDescription)")
        } else {
            let onAir = any["dj.onAir"]
            XCTAssertTrue(onAir.waitForExistence(timeout: 5), "dj.onAir missing\n\(app.debugDescription)")
            XCTAssertFalse(any["dj.ready"].exists, "On Air replaces the ready line")
            let frozen = any.matching(NSPredicate(format: "label == %@", "On Air, 0:12")).firstMatch
            XCTAssertTrue(frozen.exists, "The capture freezes the ON AIR timer at 0:12: \(onAir.label)")
            XCTAssertTrue(any["folded.artCard.orb"].waitForExistence(timeout: 5),
                          "the art card shows the orb while on air\n\(app.debugDescription)")
            XCTAssertFalse(any["folded.artCard.artwork"].exists,
                           "the art is hidden while on air")
        }
        save(app, isOpenLayout ? "open-onair" : "closed-onair")
    }

    // MARK: Duo shell, fold, and rotation

    /// Tapping a station selects it and shows one studio model. It does not search or play.
    @MainActor
    func testSelectingAStationNeverStartsPlayback() {
        let app = launch(scenario: "shell")
        XCTAssertEqual(callLabel(app), "0/0", app.debugDescription)
        let sidebar = app.descendants(matching: .any)["split.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(contains(sidebar, "Morning Light"), "The sidebar keeps no now-playing copy\n\(app.debugDescription)")
        XCTAssertFalse(contains(sidebar, "On Air"), "The sidebar keeps no DJ state\n\(app.debugDescription)")
        let calm = stationRow(sidebar, named: "Morning Calm")
        XCTAssertTrue(calm.waitForExistence(timeout: 5), app.debugDescription)
        calm.tap()
        XCTAssertEqual(callLabel(app), "0/0", "Selecting a station must not search or play\n\(app.debugDescription)")
        let appeared = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.model.")).firstMatch
        XCTAssertTrue(appeared.waitForExistence(timeout: 5), "The detail holds the one shared studio model\n\(app.debugDescription)")
        XCTAssertEqual(modelIdentifiers(app).count, 1, "The detail holds the one shared studio model\n\(app.debugDescription)")
        if sidebar.exists {
            XCTAssertFalse(contains(sidebar, "Morning Light"), app.debugDescription)
        }
        XCTAssertEqual(callLabel(app), "0/0", app.debugDescription)
    }

    /// Launch (and restore) must not request Apple Music. The binder refreshes
    /// `currentStatus` only; `.notDetermined` shows Allow (never bare Connecting).
    @MainActor
    func testLaunchAndRestoreNeverRequestAppleMusicAuthorization() {
        let morningCalm = "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D"
        let cold = launch(scenario: "shell")
        XCTAssertTrue(cold.descendants(matching: .any)["split.sidebar"].waitForExistence(timeout: 15),
                      cold.debugDescription)
        XCTAssertEqual(authorizeCount(cold), "0",
                       "Cold launch must not request Apple Music\n\(cold.debugDescription)")
        XCTAssertEqual(callLabel(cold), "0/0", cold.debugDescription)

        let app = launch(scenario: "shell", restoreStationID: morningCalm)
        let appeared = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.model.")).firstMatch
        XCTAssertTrue(appeared.waitForExistence(timeout: 5),
                      "Restored detail appears without authorizing\n\(app.debugDescription)")
        let allow = app.descendants(matching: .any)["playback.allowMusic"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5),
                      "Restored notDetermined shows Allow Apple Music, not Connecting\n\(app.debugDescription)")
        XCTAssertFalse(shows(app, "Connecting to Apple Music"),
                       "Restore must not show the bare Connecting spinner\n\(app.debugDescription)")
        XCTAssertEqual(authorizeCount(app), "0",
                       "Restoring a stored station must not request Apple Music\n\(app.debugDescription)")
        XCTAssertEqual(callLabel(app), "0/0", app.debugDescription)

        // Already-granted restore: ready (track) state, still zero requests.
        let granted = launch(scenario: "shell", restoreStationID: morningCalm,
                             musicAuthStatus: "authorized")
        let grantedModel = granted.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.model.")).firstMatch
        XCTAssertTrue(grantedModel.waitForExistence(timeout: 5),
                      "Authorized restore reaches the ready detail\n\(granted.debugDescription)")
        XCTAssertFalse(granted.descendants(matching: .any)["playback.allowMusic"].exists,
                       "Authorized restore does not show Allow\n\(granted.debugDescription)")
        XCTAssertFalse(shows(granted, "Connecting to Apple Music"),
                       "Authorized restore is not Connecting\n\(granted.debugDescription)")
        XCTAssertTrue(shows(granted, "Morning Light") || granted.buttons["transport.playPause"].exists,
                      "Authorized restore reaches a ready playing state\n\(granted.debugDescription)")
        XCTAssertEqual(authorizeCount(granted), "0",
                       "Authorized restore must not call request()\n\(granted.debugDescription)")
        XCTAssertEqual(callLabel(granted), "0/0", granted.debugDescription)
    }

    /// A stored station id selects Morning Calm and shows its detail. It does not search or play.
    /// The id arrives as `-AeroDJRestoreStationID`, the same value `@SceneStorage` would hold.
    @MainActor
    func testSelectionRestoreNeverStartsPlayback() {
        let morningCalm = "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D"
        let app = launch(scenario: "shell", restoreStationID: morningCalm)
        XCTAssertEqual(callLabel(app), "0/0", "Restoring a selection must not search or play\n\(app.debugDescription)")
        let appeared = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.model.")).firstMatch
        XCTAssertTrue(appeared.waitForExistence(timeout: 5), "The restored detail holds the one shared studio model\n\(app.debugDescription)")
        XCTAssertEqual(modelIdentifiers(app).count, 1, "The restored detail holds the one shared studio model\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["split.placeholder"].exists,
                       "A restored station replaces the placeholder\n\(app.debugDescription)")
        let title = app.descendants(matching: .any)["station.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The restored detail names its station\n\(app.debugDescription)")
        XCTAssertTrue(title.label.contains("Morning Calm"), "Morning Calm is the restored station\n\(app.debugDescription)")
        if isOpenLayout {
            let sidebar = app.descendants(matching: .any)["split.sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5), app.debugDescription)
            let row = stationRow(sidebar, named: "Morning Calm")
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(row.isSelected, "Morning Calm is selected\n\(app.debugDescription)")
            XCTAssertFalse(contains(sidebar, "Morning Light"), "The sidebar keeps no now-playing copy\n\(app.debugDescription)")
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 5),
                          "Compact shows the restored detail\n\(app.debugDescription)")
        }
        XCTAssertEqual(callLabel(app), "0/0", app.debugDescription)
    }

    // MARK: Width-class change keeps the restored station (Fry, #280 review)

    /// Whether the station split in `app` is in regular width: the sidebar is the station list.
    /// Compact width draws the carousel instead (`StationSplitRoot.stationPicker`).
    @MainActor
    private func splitIsRegular(_ app: XCUIApplication) -> Bool {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "stations.row.")).firstMatch
        return row.waitForExistence(timeout: 5) && !app.descendants(matching: .any)["stations.carousel"].exists
    }

    @MainActor
    private func assertRestoredStationVisible(_ app: XCUIApplication, _ name: String, _ message: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let title = app.descendants(matching: .any)["station.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "\(message): station detail missing\n\(visibleIdentifiers(app))",
                      file: file, line: line)
        XCTAssertTrue(title.label.contains(name), "\(message): wrong station \(title.label)", file: file, line: line)
        XCTAssertTrue(title.isHittable, "\(message): station detail is not on screen\n\(visibleIdentifiers(app))",
                      file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any)["split.placeholder"].exists, message, file: file, line: line)
        XCTAssertEqual(callLabel(app), "0/0", "\(message): a width change must not search or play", file: file, line: line)
    }

    /// (b) A Max-class phone in landscape is regular width. Restore there, rotate to portrait
    /// (compact): the station stays open instead of the carousel. Skips where landscape is
    /// still compact (smaller phones) and on iPad, where rotation keeps the width class.
    @MainActor
    func testRestoreInRegularLandscapeThenPortraitKeepsStation() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad rotation does not change the width class")
        defer { XCUIDevice.shared.orientation = .portrait }
        let morningCalm = "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D"
        let app = startApp(scenario: "shell", restoreStationID: morningCalm, orientation: .landscapeLeft)
        try XCTSkipUnless(splitIsRegular(app), "Landscape is compact on this phone; needs a Plus/Max-class simulator")
        assertRestoredStationVisible(app, "Morning Calm", "regular landscape restore")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 10),
                      "Portrait is the compact player\n\(visibleIdentifiers(app))")
        assertRestoredStationVisible(app, "Morning Calm", "rotating to portrait")
    }

    /// (c) The reverse: restore in portrait (compact), rotate to regular landscape, and back.
    @MainActor
    func testRestoreInPortraitThenRegularLandscapeKeepsStation() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad rotation does not change the width class")
        defer { XCUIDevice.shared.orientation = .portrait }
        let morningCalm = "7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D"
        let app = startApp(scenario: "shell", restoreStationID: morningCalm)
        assertRestoredStationVisible(app, "Morning Calm", "compact portrait restore")
        XCUIDevice.shared.orientation = .landscapeLeft
        try XCTSkipUnless(splitIsRegular(app), "Landscape is compact on this phone; needs a Plus/Max-class simulator")
        assertRestoredStationVisible(app, "Morning Calm", "rotating to regular landscape")
        XCUIDevice.shared.orientation = .portrait
        assertRestoredStationVisible(app, "Morning Calm", "rotating back to portrait")
    }

    /// Widening from compact to regular keeps the search text and the studio identity, and counts no calls.
    @MainActor
    func testCompactToRegularDoesNotSearchOrPlay() {
        let app = launch(scenario: "resize")
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15))
        XCTAssertEqual(callLabel(app), "0/0")
        let before = modelIdentifiers(app)
        XCTAssertEqual(before.count, 1)
        // #454: search is no longer the compact empty state; it sits behind Search Apple Music,
        // which opens the Queue workspace sheet.
        let searchButton = app.buttons["playback.searchAppleMusic"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10), app.debugDescription)
        searchButton.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replaceText(field, with: "violet")
        // iPad reports "Hide keyboard" below the screen. tap() scrolls that key into
        // view and fails with kAXErrorCannotComplete (Xcode 26.6, self-hosted mini).
        // The sheet toolbar's Done removes the focused field, so the keyboard leaves
        // with it. Done only sets showWorkspace = false. Return would submit: the
        // field's onSubmit runs the search, and the counting fixture records a call.
        // iPhone still uses the on-screen Hide key when that key exists.
        if UIDevice.current.userInterfaceIdiom != .pad {
            dismissKeyboard(app)
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        } else {
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
        }
        app.buttons["probe.widen"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["layout.studio"].waitForExistence(timeout: 10),
                      "Regular width above the studio minimum opens the two panes")
        let again = app.textFields["search.field"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.value as? String, "violet", "Search text survives the fold")
        XCTAssertTrue(app.segmentedControls["workspace.segment"].buttons["Queue"].isSelected)
        XCTAssertEqual(modelIdentifiers(app), before, "Folding reuses the same studio model")
        assertCallsStayZero(app, "A compact-to-regular change must not search or play")
        save(app, isOpenLayout ? "ipad-resize-regular" : "iphone-resize-regular")
    }

    /// A pending tune change is still pending after the same compact-to-regular change.
    @MainActor
    func testPendingTuneSurvivesFold() {
        let app = launch(scenario: "resizeTune")
        XCTAssertTrue(app.scrollViews["tune.form"].waitForExistence(timeout: 15))
        let before = indicatorLabels(app)
        XCTAssertTrue(before.contains { $0.localizedCaseInsensitiveContains("pending") || $0.localizedCaseInsensitiveContains("next") },
                      "The change starts pending: \(before)")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.buttons["probe.widen"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["layout.studio"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["tune.form"].waitForExistence(timeout: 10))
        XCTAssertEqual(indicatorLabels(app), before, "Folding must not re-apply or drop the pending change")
        XCTAssertEqual(callLabel(app), "0/0")
    }

    @MainActor
    func testRotationKeepsSegmentSearchAndPlayback() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        // #542: open is the rail layout, so the queue (and search) is the sheet there too.
        let layout = "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15))
        openClosedQueue(app)  // #537/#542: ⋯ → Queue on the closed reskin; the rail's Queue when open
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        replaceText(field, with: "violet")
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "violet"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [landed], timeout: 5), .completed,
                       "Search text must land in the field before rotation")
        XCUIDevice.shared.orientation = .landscapeLeft
        // A compact sheet can close when the window rotates. The text lives above that sheet.
        if !app.textFields["search.field"].waitForExistence(timeout: 3) {
            openClosedQueue(app)
        }
        let rotated = app.textFields["search.field"]
        XCTAssertTrue(rotated.waitForExistence(timeout: 10))
        XCTAssertEqual(rotated.value as? String, "violet")
        XCTAssertTrue(app.buttons["transport.playPause"].exists, "Playback stays up across rotation")
        XCTAssertTrue(shows(app, "Morning Light"))
        let segments = app.segmentedControls["workspace.segment"]
        if segments.exists {
            XCTAssertTrue(segments.buttons["Queue"].isSelected)
        }
        save(app, isOpenLayout ? "ipad-landscape" : "iphone-landscape")
    }

    @MainActor
    func testLandscapeDark() {
        let app = launch(dark: true)
        defer { XCUIDevice.shared.orientation = .portrait }
        let layout = "layout.compact"
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(shows(app, "Morning Light"))
        XCTAssertTrue(app.buttons["transport.playPause"].waitForExistence(timeout: 10))
        save(app, isOpenLayout ? "ipad-landscape-dark" : "iphone-landscape-dark")
    }

    @MainActor
    func testReduceMotionIsRespected() {
        let app = launch(reduceMotion: true)
        let layout = "layout.compact"  // #542: open is the rail layout (compact player) too
        XCTAssertTrue(app.descendants(matching: .any)[layout].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["motion.reduced"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transport.playPause"].exists)
        assertReadingOrder(app, title: "Morning Light")
    }

    /// Station ratings (-Nova, PR B): the button sits on the now-playing block only in the rating
    /// scenarios; `playing` (and every other scenario) has none, so those screenshots are unchanged.
    @MainActor
    func testRatingButtonOnNowPlaying() throws {
        let plain = launch(scenario: "playing")
        XCTAssertTrue(shows(plain, "Morning Light"))
        XCTAssertFalse(plain.buttons["nowPlaying.rating"].exists, "no rating controller, no button")
        if !isOpenLayout {
            // #537: the closed star lives in ⋯; with no controller ⋯ has no rating row either.
            openClosedMore(plain)
            XCTAssertTrue(closedMenuItem(plain, "queue.affordance", labelPrefix: "Queue").waitForExistence(timeout: 5))
            XCTAssertFalse(closedMenuItem(plain, "nowPlaying.rating", labelPrefix: "Rate song").exists,
                           "no rating controller, no ⋯ rating row")
        }
        plain.terminate()

        let app = launch(scenario: "ratingFirstTime")
        if !isOpenLayout {
            // #537: the star is not in the closed title row; it is reachable in ⋯.
            XCTAssertTrue(shows(app, "Morning Light"))
            XCTAssertFalse(app.buttons["nowPlaying.rating"].exists, "#537: no star in the closed title row")
            openClosedMore(app)
        }
        let button = isOpenLayout ? app.buttons["nowPlaying.rating"]
                                  : closedMenuItem(app, "nowPlaying.rating", labelPrefix: "Rate song")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "rating button:\n\(app.debugDescription)")
        XCTAssertTrue(button.label.contains("not rated"), button.label)
        XCTAssertTrue(button.isHittable)
        // Simulators report sub-point float noise (43.99999999999994 on iPhone Air), so allow 0.01 pt.
        XCTAssertGreaterThanOrEqual(button.frame.width, 44 - 0.01, "44 pt tap target")
        XCTAssertGreaterThanOrEqual(button.frame.height, 44 - 0.01, "44 pt tap target")
        XCTAssertTrue(shows(app, "Rate"), "first-time label")
        XCTAssertTrue(shows(app, "Morning Light, The Calm Collective"), "the labels stay one element")
        save(app, "rating-first-time")
        button.tap()
        for item in ["More like this", "Like it", "Tired of it", "Never play on this station"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 5), "\(item) in the menu")
        }
        save(app, "rating-menu")
    }

    @MainActor
    func testRatedSongAndNeverToast() throws {
        let liked = launch(scenario: "ratingLiked")
        if !isOpenLayout {
            XCTAssertTrue(shows(liked, "Morning Light"))
            XCTAssertFalse(liked.buttons["nowPlaying.rating"].exists, "#537: no star in the closed title row")
            openClosedMore(liked)  // #537: the star is in ⋯
        }
        let button = isOpenLayout ? liked.buttons["nowPlaying.rating"]
                                  : closedMenuItem(liked, "nowPlaying.rating", labelPrefix: "Rate song")
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.label.contains("Like it"), button.label)
        save(liked, "rating-liked")
        liked.terminate()

        let app = launch(scenario: "ratingNever")
        let toast = app.descendants(matching: .any)["nowPlaying.ratingToast"]
        let undo = app.buttons["nowPlaying.rating.undo"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "never toast:\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Won't play on this station again."))
        XCTAssertTrue(undo.isHittable, "Undo is on screen and hittable")
        XCTAssertEqual(undo.label, "Undo")
        XCTAssertEqual(undo.identifier, "nowPlaying.rating.undo")
        XCTAssertGreaterThan(undo.frame.width, 1, "Undo has a real hit target")
        XCTAssertGreaterThan(undo.frame.height, 1, "Undo has a real hit target")
        XCTAssertTrue(undo.frame.origin.x.isFinite && undo.frame.origin.y.isFinite, "Undo has a finite activation point")
        let station = app.descendants(matching: .any)["station.title"]
        XCTAssertTrue(station.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(station.label.contains("Morning Calm"), station.label)
        let stationBefore = station.label
        let state = app.descendants(matching: .any)["capture.ratingState"]
        XCTAssertTrue(state.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(state.label.contains("Never play on this station"), state.label)
        let scopeBefore = ratingScope(state.label)
        XCTAssertFalse(scopeBefore.isEmpty, state.label)
        let rated = ratingControl(app)
        XCTAssertTrue(rated.waitForExistence(timeout: 5), "rating before Undo:\n\(app.debugDescription)")
        XCTAssertTrue(rated.label.contains("Never play on this station"), rated.label)
        closeRatingMenu(app)
        XCTAssertTrue(undo.isHittable, "Undo is tappable after the rating check")
        // ratingNever holds the toast. The tap is the next thing after this wait. #489
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3), "undo hides the toast")
        XCTAssertEqual(app.descendants(matching: .any)["station.title"].label, stationBefore,
                       "the station on screen is unchanged")
        let likeIt = NSPredicate(format: "label CONTAINS %@", "Like it")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: likeIt, object: state)], timeout: 5),
                       .completed, "undo restores the prior rating: \(state.label)")
        XCTAssertEqual(ratingScope(state.label), scopeBefore, "undo stays on the same station scope")
        XCTAssertFalse(state.label.contains("Never"), state.label)
        let restored = ratingControl(app)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: likeIt, object: restored)], timeout: 5),
                       .completed, "rating button shows the prior rating: \(restored.label)")
        XCTAssertFalse(restored.label.contains("Never"), restored.label)
        closeRatingMenu(app)
        save(app, "rating-never-undone")
    }

    /// `capture.ratingState` is "Rate song, current: …|<scope key>".
    private func ratingScope(_ label: String) -> String {
        label.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
    }

    /// The now-playing rating control. The closed reskin keeps it in ⋯ (#537).
    @MainActor
    private func ratingControl(_ app: XCUIApplication) -> XCUIElement {
        if !isOpenLayout {
            let item = closedMenuItem(app, "nowPlaying.rating", labelPrefix: "Rate song")
            if !item.exists { openClosedMore(app) }
        }
        return isOpenLayout ? app.buttons["nowPlaying.rating"]
                            : closedMenuItem(app, "nowPlaying.rating", labelPrefix: "Rate song")
    }

    /// Closes ⋯ after a rating-label check so the next tap can hit Undo, and so the
    /// undone screenshot is the player rather than the open menu.
    @MainActor
    private func closeRatingMenu(_ app: XCUIApplication) {
        guard !isOpenLayout else { return }
        let more = app.buttons["folded.more"]
        if more.exists && more.isHittable {
            more.tap()
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.55)).tap()
    }

    /// The never toast while it is still on screen. The ratingNever fixture holds it, so this shot is not racing the 6s dismissal. No Undo tap.
    @MainActor
    func testRatingNeverToastScreenshot() throws {
        let app = launch(scenario: "ratingNever")
        let toast = app.descendants(matching: .any)["nowPlaying.ratingToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "never toast:\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Won't play on this station again."))
        save(app, "rating-never-toast")
    }

    /// Compact empty state: submit search shows fixture results and does not play.
    @MainActor
    func testCompactSearchShowsFixtureResults() throws {
        try XCTSkipIf(isOpenLayout, "Compact search is checked on an iPhone-width simulator")
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.descendants(matching: .any)["layout.compact"].waitForExistence(timeout: 15))
        // #454: the empty state offers search behind an explicit button, not as the screen itself.
        XCTAssertFalse(app.textFields["search.field"].exists, "Search is not the empty state\n\(app.debugDescription)")
        let searchButton = app.buttons["playback.searchAppleMusic"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10), app.debugDescription)
        searchButton.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        replaceText(field, with: "jazz")
        let submit = app.buttons["search.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), app.debugDescription)
        submit.tap()
        let result = app.descendants(matching: .any)["search.result.1"]
        XCTAssertTrue(result.waitForExistence(timeout: 10),
                      "Fixture search results appear after submit\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Morning Light"), app.debugDescription)
        let calls = callLabel(app)
        XCTAssertTrue(calls.hasPrefix("0/"), "Search must not play: \(calls)\n\(app.debugDescription)")
        XCTAssertNotEqual(calls, "0/0", "Submit records a search: \(calls)")
    }

    // MARK: Station start (#454)

    /// #454: a station tap lands on Now Playing for that station ("Starting <name>…"), never on the
    /// Apple Music search field. iOS CI only: the capture drives the real `PlayingScreen` with the
    /// start state a tap sets; it does not prove Apple Music playback.
    @MainActor
    func testStationTapShowsStartingNowPlayingNotSearch() {
        let app = launch(scenario: "stationStarting")
        let start = app.descendants(matching: .any)["nowPlaying.stationStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Starting state on Now Playing\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Starting Morning Calm…"), app.debugDescription)
        XCTAssertFalse(app.textFields["search.field"].exists, "A station tap never shows search\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["playback.searchAppleMusic"].exists, "No search button while starting\n\(app.debugDescription)")
        save(app, isOpenLayout ? "ipad-station-starting" : "iphone-station-starting")
    }

    /// #454: a start that fails stays on that station's screen with Try again, never search.
    @MainActor
    func testFailedStationStartOffersRetryInPlace() {
        let app = launch(scenario: "stationStartFailed")
        let retry = app.buttons["playback.retryStationStart"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Try again on the same screen\n\(app.debugDescription)")
        XCTAssertTrue(shows(app, "Couldn't start Morning Calm"), app.debugDescription)
        XCTAssertFalse(app.textFields["search.field"].exists, "A failed start never shows search\n\(app.debugDescription)")
        XCTAssertTrue(retry.isHittable)
        save(app, isOpenLayout ? "ipad-station-start-failed" : "iphone-station-start-failed")
        retry.tap()
        XCTAssertFalse(app.textFields["search.field"].exists, "Retry stays off search\n\(app.debugDescription)")
    }

    /// #454: tapping a station row in the real split shows that station's Now Playing, not search.
    @MainActor
    func testStationRowTapShowsNowPlayingNotSearch() {
        let app = launch(scenario: "shell", musicAuthStatus: "authorized")
        let sidebar = app.descendants(matching: .any)["split.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15), app.debugDescription)
        let calm = stationRow(sidebar, named: "Morning Calm")
        XCTAssertTrue(calm.waitForExistence(timeout: 5), app.debugDescription)
        calm.tap()
        let title = app.descendants(matching: .any)["station.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(title.label.contains("Morning Calm"), app.debugDescription)
        XCTAssertTrue(app.buttons["transport.playPause"].waitForExistence(timeout: 10)
                      || app.descendants(matching: .any)["nowPlaying.stationStart"].exists,
                      "Now Playing for the tapped station\n\(app.debugDescription)")
        // The open Studio keeps search in its Queue tab beside a playing song (allowed by #454);
        // the closed player must not show it at all.
        if !isOpenLayout {
            XCTAssertFalse(app.textFields["search.field"].exists, "A station tap never shows search\n\(app.debugDescription)")
        }
    }

    /// Shared Items sheet always has Done and dismisses without force-quit.
    @MainActor
    func testShareSheetDismissesViaDone() throws {
        let app = launch(scenario: "shell")
        let shared = app.buttons["Shared Items"]
        XCTAssertTrue(shared.waitForExistence(timeout: 15), app.debugDescription)
        shared.tap()
        let done = app.buttons["share.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10),
                      "Share sheet exposes Done\n\(app.debugDescription)")
        done.tap()
        XCTAssertFalse(done.waitForExistence(timeout: 3),
                       "Done dismisses the share sheet\n\(app.debugDescription)")
    }

    // MARK: Recorded walkthrough (CI records the simulator screen while this runs)

    @MainActor
    func testRecordedWalkthrough() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STUDIO_WALKTHROUGH"] == "1",
                          "Runs only in the CI recording step")
        let app = launch()
        let pause = { Thread.sleep(forTimeInterval: 1.2) }
        // #542: open is the rail layout, so both layouts open the workspace as the sheet.
        XCTAssertTrue(app.otherElements["layout.compact"].waitForExistence(timeout: 15))
        pause()
        app.buttons["transport.playPause"].tap(); pause()
        app.buttons["transport.playPause"].tap(); pause()
        openClosedQueue(app)  // #537/#542: ⋯ → Queue on the closed reskin; the rail's Queue when open
        XCTAssertTrue(app.segmentedControls["workspace.segment"].waitForExistence(timeout: 5))
        pause()
        let segments = app.segmentedControls["workspace.segment"]
        for name in ["Tune", "Connections", "Queue"] where segments.buttons[name].exists {
            segments.buttons[name].tap(); pause()
            if name == "Tune" { app.scrollViews["tune.form"].swipeUp(); pause(); app.scrollViews["tune.form"].swipeDown(); pause() }
        }
        if app.buttons["Done"].exists { app.buttons["Done"].tap(); pause() }
    }

    /// Title, then status, then transport. The smallest matching element is the spoken node,
    /// not a container that happens to include the same words.
    @MainActor
    private func assertReadingOrder(_ app: XCUIApplication, title: String, status: String? = nil) {
        let titleEl = tightest(app, title)
        let play = app.buttons["transport.playPause"]
        XCTAssertTrue(titleEl.exists, title)
        XCTAssertTrue(play.exists)
        // #542: on the unfolded rail the transport sits in the trailing `folded.systemBar`
        // column (accessibilitySortPriority 0, after the track and content columns at 2 and 1),
        // level with the title, so top-to-bottom order does not apply. There the check is that
        // Play/Pause is inside the rail and the text is in a column leading of it.
        let rail = app.descendants(matching: .any)["folded.systemBar"]
        let onRail = rail.exists && rail.frame.contains(CGPoint(x: play.frame.midX, y: play.frame.midY))
        if onRail {
            XCTAssertLessThanOrEqual(titleEl.frame.maxX, rail.frame.minX + 1, "\(title) is in a column read before the rail transport")
        } else {
            XCTAssertLessThan(titleEl.frame.minY, play.frame.minY, "\(title) is read before the transport")
        }
        if let status {
            let statusEl = tightest(app, status)
            XCTAssertTrue(statusEl.exists, status)
            XCTAssertLessThanOrEqual(titleEl.frame.minY, statusEl.frame.minY, "\(title) is read before \(status)")
            if onRail {
                XCTAssertLessThanOrEqual(statusEl.frame.maxX, rail.frame.minX + 1, "\(status) is in a column read before the rail transport")
            } else {
                XCTAssertLessThanOrEqual(statusEl.frame.minY, play.frame.minY, "\(status) is read before the transport")
            }
        }
    }

    @MainActor
    private func tightest(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .allElementsBoundByIndex
        return matches.min(by: { $0.frame.height < $1.frame.height }) ?? app.descendants(matching: .any).firstMatch
    }

    /// Compact dump of on-screen accessibility identifiers for launch timeouts.
    @MainActor
    private func visibleIdentifiers(_ app: XCUIApplication) -> String {
        let nodes = app.descendants(matching: .any).allElementsBoundByIndex
        let ids = nodes.compactMap { el -> String? in
            let id = el.identifier
            return id.isEmpty ? nil : id
        }
        let unique = Array(Set(ids)).sorted()
        return "visible identifiers (\(unique.count)): \(unique.joined(separator: ", "))"
    }

    @MainActor
    private func authorizeCount(_ app: XCUIApplication) -> String {
        let badge = app.descendants(matching: .any)["playback.authorize"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), app.debugDescription)
        return badge.label
    }

    private func callLabel(_ app: XCUIApplication) -> String {
        let badge = app.descendants(matching: .any)["playback.calls"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "playback call counter")
        return badge.label
    }

    /// A layout change can schedule search or play after the next frame. Wait long enough
    /// for that call to show up, and fail if the counter moves off `0/0`.
    @MainActor
    private func assertCallsStayZero(_ app: XCUIApplication, _ message: String) {
        let badge = app.descendants(matching: .any)["playback.calls"]
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "0/0"), object: badge)
        let result = XCTWaiter().wait(for: [changed], timeout: 1)
        XCTAssertEqual(result, .timedOut, "\(message): \(badge.label)")
    }

    /// The selectable list row, not the title text inside it.
    @MainActor
    private func stationRow(_ sidebar: XCUIElement, named name: String) -> XCUIElement {
        let label = NSPredicate(format: "label CONTAINS %@", name)
        let button = sidebar.buttons.matching(label).firstMatch
        if button.exists { return button }
        let cell = sidebar.cells.matching(label).firstMatch
        if cell.exists { return cell }
        return sidebar.descendants(matching: .any).matching(label).firstMatch
    }

    @MainActor
    private func modelIdentifiers(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "studio.model."))
            .allElementsBoundByIndex
            .map(\.identifier)
            .sorted()
    }

    @MainActor
    private func indicatorLabels(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any)
            .matching(identifier: "tune.indicator")
            .allElementsBoundByIndex
            .map(\.label)
            .sorted()
    }

    @MainActor
    private func replaceText(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = typedText(field)
        if !current.isEmpty, current != text {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        if typedText(field) != text {
            field.typeText(text)
        }
    }

    /// The empty field reports its placeholder. That string is not stored text.
    private func typedText(_ field: XCUIElement) -> String {
        guard let value = field.value as? String, value != "Search Apple Music" else { return "" }
        return value
    }

    /// Hides the keyboard without pressing Return, which would submit a search.
    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.waitForExistence(timeout: 2) {
            hide.tap()
        }
    }

    @MainActor
    private func contains(_ root: XCUIElement, _ text: String) -> Bool {
        root.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch.exists
    }

    /// Any element whose label contains `text` (SwiftUI combines some texts into one element).
    @MainActor
    private func shows(_ app: XCUIApplication, _ text: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch.exists
    }

    /// Compact narrow, half and two-thirds. Full is covered by `SplitViewLayoutTests`.
    /// Widths match `SplitViewLayout.narrow`, `.half` and `.wide`.
    @MainActor
    func testSplitViewKeepsEveryScreenInsideTheWindow() throws {
        try XCTSkipUnless(isOpenLayout, "Split widths need an iPad-size simulator window")
        let widths: [(name: String, width: CGFloat, height: CGFloat, leading: CGFloat, trailing: CGFloat,
                      span: String, shot: String)] = [
            ("narrow", 340, 760, 28, 0, "compactNarrow", "split-narrow"),
            ("half", 540, 760, 28, 0, "half", "split-half"),
            ("wide", 680, 760, 0, 28, "twoThirds", "split-wide"),
        ]
        for width in widths {
            try assertSplit(width)
        }
    }

    @MainActor
    private func assertSplit(_ sample: (name: String, width: CGFloat, height: CGFloat, leading: CGFloat,
                                       trailing: CGFloat, span: String, shot: String)) throws {
        let app = launch(scenario: "splitView", splitExample: sample.name)
        let any = app.descendants(matching: .any)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "no window")
        guard let windowFrame = settledFrame(of: window, "window") else { return }
        if windowFrame.width + 8 < sample.width || windowFrame.height + 8 < sample.height {
            throw XCTSkip("window \(windowFrame) cannot hold \(sample.width) × \(sample.height)")
        }
        let container = any["split.container"]
        XCTAssertTrue(container.waitForExistence(timeout: 15), app.debugDescription)
        guard let box = settledFrame(of: container, sample.name, isFinal: {
            abs($0.width - sample.width) <= 1 && abs($0.height - sample.height) <= 1
        }) else { return }
        XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(box),
                      "container \(box) outside window \(windowFrame)")
        let edge = sample.leading > sample.trailing ? "leading" : "trailing"
        let screens = ["library", "stations", "settings", "nowPlaying"]
        for screen in screens {
            let show = app.buttons["split.show.\(screen)"]
            XCTAssertTrue(show.waitForExistence(timeout: 5), screen)
            XCTAssertGreaterThanOrEqual(show.frame.width, 44, screen)
            XCTAssertGreaterThanOrEqual(show.frame.height, 44, screen)
            show.tap()
            let decision = any["split.decision"]
            XCTAssertTrue(decision.waitForExistence(timeout: 8), "\(screen) never resolved\n\(app.debugDescription)")
            let expected = "\(sample.span) \(edge)"
            let matched = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", expected), object: decision)
            XCTAssertEqual(XCTWaiter().wait(for: [matched], timeout: 8), .completed,
                           "\(screen) decision \(decision.label), expected \(expected)")
            if sample.name == "half", screen == "stations" {
                save(app, "split-half-stations")
            }
            try assertSplitScreen(screen, app: app, box: box, leading: sample.leading,
                                  trailing: sample.trailing, edge: edge,
                                  sideBar: sample.name != "narrow")
        }
        save(app, sample.shot)
        app.terminate()
    }

    @MainActor
    private func assertSplitScreen(_ screen: String, app: XCUIApplication, box: CGRect,
                                   leading: CGFloat, trailing: CGFloat, edge: String,
                                   sideBar: Bool) throws {
        let any = app.descendants(matching: .any)
        switch screen {
        case "nowPlaying":
            XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertFalse(any["layout.studio"].exists)
            let play = app.buttons["transport.playPause"]
            let skip = app.buttons["transport.skip"]
            XCTAssertTrue(play.waitForExistence(timeout: 8))
            XCTAssertTrue(skip.waitForExistence(timeout: 8))
            try assertInside(play, box: box, leading: leading, trailing: trailing, name: "play")
            try assertInside(skip, box: box, leading: leading, trailing: trailing, name: "skip")
            XCTAssertTrue(play.isHittable, "play is not hittable")
            if sideBar {
                let bar = any["folded.systemBar"]
                XCTAssertTrue(bar.waitForExistence(timeout: 5), "the symbol bar is the outer edge")
                try assertInside(bar, box: box, leading: leading, trailing: trailing, name: "bar")
                try assertOuterEdge(bar, box: box, edge: edge, name: "bar")
                let more = any["folded.more"]
                XCTAssertTrue(more.waitForExistence(timeout: 5), "More stays on the bar")
                try assertInside(more, box: box, leading: leading, trailing: trailing, name: "more")
            } else {
                XCTAssertFalse(any["folded.systemBar"].exists, "a narrow split keeps the phone column")
                // More is a Menu inside the navigation bar. Same label-frame check as
                // the other system toolbar buttons. The symbol-bar More stays on assertInside.
                let more = app.buttons["folded.more"]
                XCTAssertTrue(more.waitForExistence(timeout: 5), "narrow split keeps More")
                assertSystemToolbar(more, box: box, name: "more")
                try assertOuterEdge(more, box: box, edge: edge, name: "more")
            }
        case "library":
            let edit = app.buttons["library.edit"]
            let row = any["library.row.0"]
            XCTAssertTrue(edit.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            assertSystemToolbar(edit, box: box, name: "library edit")
            try assertInside(row, box: box, leading: leading, trailing: trailing, name: "library row")
            try assertOuterEdge(edit, box: box, edge: edge, name: "library edit")
        case "stations":
            let gear = app.buttons["stations.settings"]
            XCTAssertTrue(gear.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(any["split.sidebar"].waitForExistence(timeout: 5))
            assertSystemToolbar(gear, box: box, name: "settings gear")
            try assertOuterEdge(gear, box: box, edge: edge, name: "settings gear")
            let identifier = sideBar
                ? "stations.row.7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D"
                : "stations.card.7C2A1B10-4E5F-4A6B-8C9D-0E1F2A3B4C5D"
            let row = any[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "station row \(identifier)")
            try assertInside(row, box: box, leading: leading, trailing: trailing, name: "station row")
        case "settings":
            let done = app.buttons["settings.done"]
            let toggle = app.switches["settings.talkoverToggle"]
            XCTAssertTrue(done.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(toggle.waitForExistence(timeout: 8))
            assertSystemToolbar(done, box: box, name: "done")
            try assertInside(toggle, box: box, leading: leading, trailing: trailing, name: "talk-over")
            try assertOuterEdge(done, box: box, edge: edge, name: "done")
        default:
            XCTFail(screen)
        }
    }

    /// A `Button` inside a `ToolbarItem` (or `EditButton`). XCUITest reports the
    /// label frame (36 pt on iOS 26.5), not the 44 pt hit area of the bar. Same
    /// check as settings.done in #512. Controls the app lays out stay on `assertInside`.
    @MainActor
    private func assertSystemToolbar(_ element: XCUIElement, box: CGRect, name: String) {
        XCTAssertTrue(element.exists)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(element.frame),
                      "\(name) left the container \(element.frame) \(box)")
    }

    @MainActor
    private func assertInside(_ element: XCUIElement, box: CGRect, leading: CGFloat, trailing: CGFloat,
                              name: String) throws {
        guard let frame = settledFrame(of: element, name) else { return }
        let detail = "\(name) \(frame) container \(box) insets \(leading),\(trailing)"
        XCTAssertGreaterThanOrEqual(frame.width, 44, detail)
        XCTAssertGreaterThanOrEqual(frame.height, 44, detail)
        XCTAssertGreaterThanOrEqual(frame.minX, box.minX + leading - 2, detail)
        XCTAssertLessThanOrEqual(frame.maxX, box.maxX - trailing + 2, detail)
        XCTAssertTrue(box.insetBy(dx: -2, dy: -2).contains(frame), "\(name) is clipped: \(detail)")
    }

    @MainActor
    private func assertOuterEdge(_ element: XCUIElement, box: CGRect, edge: String, name: String) throws {
        guard let frame = settledFrame(of: element, name) else { return }
        if edge == "leading" {
            XCTAssertLessThan(frame.midX, box.midX, "\(name) \(frame) is not on the leading outer edge of \(box)")
        } else {
            XCTAssertGreaterThan(frame.midX, box.midX, "\(name) \(frame) is not on the trailing outer edge of \(box)")
        }
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
