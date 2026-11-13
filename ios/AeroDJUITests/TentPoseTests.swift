import XCTest
import UIKit

/// #465 item 3: the tent / tabletop pose. The required CI SDK (iOS 26.5) has no hinge API,
/// so the `duoTent` capture forces a partially open hinge at 100° into the real
/// `DuoPoseDecision`, inside an 820 × 640 pt container (the unfolded Duo, rotated). Needs an
/// iPad-size window; skipped on iPhone. Saves `duo-tent` (required in ios.yml).
final class TentPoseTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The other suites launch in portrait; leave the simulator that way.
    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        try await super.tearDown()
    }

    @MainActor
    private func launchTent(holdControls: Bool = false, reduceMotion: Bool = false) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad,
                          "The 820 × 640 pt tent container needs an iPad-size simulator window")
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", "duoTent"]
        if holdControls { app.launchArguments += ["-AeroDJTentHoldControls", "YES"] }
        if reduceMotion { app.launchArguments += ["-AeroDJReduceMotion", "YES"] }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        let loading = app.descendants(matching: .any)["capture.loading"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed, "capture still loading\n\(app.debugDescription)")
        let failed = app.descendants(matching: .any)["capture.failed"]
        if failed.exists { XCTFail(failed.label) }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        try XCTSkipUnless(window.frame.width >= 820 && window.frame.height >= 640,
                          "window \(window.frame.size) is smaller than the 820 × 640 pt tent container")
        return app
    }

    /// The container's frame once it has its final size, polled, never a fixed sleep.
    @MainActor
    private func settledContainer(_ app: XCUIApplication) throws -> CGRect {
        let container = app.descendants(matching: .any)["capture.tentContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 10), "tent container missing\n\(app.debugDescription)")
        let deadline = Date().addingTimeInterval(10)
        var last = CGRect.null
        while Date() < deadline {
            let frame = container.frame
            if abs(frame.width - 820) <= 1, abs(frame.height - 640) <= 1, frame == last { return frame }
            last = frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("tent container never settled at 820 × 640: \(container.frame)")
        return last
    }

    @MainActor
    func testTentFaceShowsTheRadioReadoutAndNoControls() throws {
        let app = try launchTent()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.tent"].waitForExistence(timeout: 15), "tent pose not drawn\n\(app.debugDescription)")
        XCTAssertFalse(any["layout.compact"].exists, "the tent replaces the folded player")
        XCTAssertFalse(any["layout.studio"].exists, "the tent replaces the Studio")
        let box = try settledContainer(app)
        let faceBottom = box.minY + 306

        // On Air comes from the confirmed speaking state only (`DJStudioState.onAirLabel`).
        let tally = any["tent.onAir"]
        XCTAssertTrue(tally.waitForExistence(timeout: 5), "On Air tally missing\n\(app.debugDescription)")
        XCTAssertEqual(tally.label, "On Air")
        XCTAssertLessThan(tally.frame.maxY, faceBottom, "the tally stays on the face")
        XCTAssertEqual(any["tent.hero"].label, "liveOrb", "speaking draws the live orb")

        let clock = any["tent.clock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        XCTAssertTrue(clock.label.hasPrefix("OnAirly radio face"), clock.label)
        XCTAssertTrue(clock.label.contains("Station Morning Calm"), clock.label)
        XCTAssertTrue(clock.label.contains("Up after the break: Slow Burn by Neon Harbor"), clock.label)
        XCTAssertLessThan(clock.frame.maxY, faceBottom, "the clock stays above the fold")

        // No buttons on the face until it is touched; the lower half takes no touch.
        XCTAssertTrue(app.buttons["tent.showControls"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["tent.showControls"].frame.height, 44)
        XCTAssertFalse(app.buttons["tent.playPause"].exists, "transport hidden until a tap")
        XCTAssertFalse(any["tent.stationDial"].exists, "dial hidden until a tap")
        for button in app.buttons.allElementsBoundByIndex where button.identifier.hasPrefix("tent.") {
            XCTAssertLessThan(button.frame.maxY, faceBottom, "\(button.identifier) sits below the fold")
        }
        save(app, "duo-tent")

        // One tap brings the controls up.
        app.buttons["tent.showControls"].tap()
        XCTAssertTrue(app.buttons["tent.playPause"].waitForExistence(timeout: 3), "a tap shows the transport")
    }

    @MainActor
    func testTentControlsMeetTheTargetSizesAndOpenStations() throws {
        let app = try launchTent(holdControls: true)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.tent"].waitForExistence(timeout: 15), "tent pose not drawn\n\(app.debugDescription)")
        let box = try settledContainer(app)
        let play = app.buttons["tent.playPause"]
        let skip = app.buttons["tent.skip"]
        let late = app.buttons["tent.station.late-night"]
        for (name, element) in [("play", play), ("skip", skip), ("late night", late),
                                ("queue", app.buttons["tent.queue"]), ("tune", app.buttons["tent.tune"]),
                                ("back", app.buttons["tent.back"])] {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(name) missing\n\(app.debugDescription)")
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name) \(element.frame)")
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) \(element.frame)")
            XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(element.frame), "\(name) left the container")
            XCTAssertLessThan(element.frame.maxY, box.minY + 306, "\(name) is on the face, not the back half")
        }
        // Big transport.
        XCTAssertGreaterThanOrEqual(play.frame.width, 60)
        XCTAssertGreaterThanOrEqual(play.frame.height, 60)
        XCTAssertGreaterThanOrEqual(skip.frame.width, 60)
        XCTAssertGreaterThanOrEqual(skip.frame.height, 60)
        XCTAssertEqual(play.label, "Pause", "the fixture is playing")
        // No break is ready while the DJ is speaking, so there is no break chip.
        XCTAssertFalse(any["tent.breakChip"].exists)
        late.tap()
        let opened = any["tent.openedStation"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
        XCTAssertEqual(opened.label, "late-night", "the dial calls the station-open action")
        save(app, "duo-tent-controls")
    }

    @MainActor
    func testTentUnderReduceMotionDrawsAStillOrb() throws {
        let app = try launchTent(reduceMotion: true)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.tent"].waitForExistence(timeout: 15), "tent pose not drawn\n\(app.debugDescription)")
        let hero = any["tent.hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertEqual(hero.label, "stillOrb", "Reduce Motion: no visualizer animation")
        XCTAssertTrue(any["tent.onAir"].exists, "On Air still shows under Reduce Motion")
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
