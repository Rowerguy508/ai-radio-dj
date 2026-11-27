import XCTest
import UIKit

/// #198 MOCK, owner review only (-Nova): the listener-controls mock (`ListenerControlsMockScenario`,
/// Mockups/ListenerControlsMock.swift) drawn in the test station and saved as Studio shots. Not
/// required in ios.yml; the shots land in the studio-screenshots artifact with the rest. Nothing
/// here touches the real Tune, settings or playback. Shots (each `<name>_<device>.png`):
/// mock-198-iphone, mock-198-iphone-dark, mock-198-iphone-large-text, mock-198-iphone-sources,
/// mock-198-duo-open-portrait, mock-198-duo-open-portrait-dark, mock-198-duo-open-landscape,
/// mock-198-ipad, mock-198-ipad-dark. A Duo frame bigger than the window is skipped, as in
/// `AppWideLayoutTests`; the iPhone shots run on the iPhone, the iPad shots on the iPad.
final class ListenerControlsMockTests: XCTestCase {
    private static let duoPortrait = CGSize(width: 640, height: 820)
    private static let duoLandscape = CGSize(width: 820, height: 640)

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: iPhone (compact)

    @MainActor
    func testPhoneListenerControls() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone window shot")
        let (app, box) = try launch("listenerMockPhone")
        assertControlsTargets(app, in: box)
        assertOneColumn(app)
        // Choosing a personality only changes the mock's own state.
        let upbeat = app.buttons["mock198.personality.upbeat"]
        upbeat.tap()
        XCTAssertTrue(upbeat.isSelected, "the tapped personality is selected")
        app.buttons["mock198.personality.warm"].tap()
        save(app, "mock-198-iphone")
    }

    @MainActor
    func testPhoneListenerControlsDark() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone window shot")
        let (app, box) = try launch("listenerMockPhone", dark: true)
        assertControlsTargets(app, in: box)
        save(app, "mock-198-iphone-dark")
    }

    @MainActor
    func testPhoneListenerControlsLargeText() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone window shot")
        let (app, box) = try launch("listenerMockPhone", contentSize: "UICTContentSizeCategoryAccessibilityL")
        // At accessibility sizes the segmented choices stack instead of clipping.
        for id in ["mock198.language.english", "mock198.language.spanish",
                   "mock198.spanglish.off", "mock198.spanglish.light", "mock198.spanglish.conversational"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(id) missing\n\(app.debugDescription)")
            assertAtLeastPoints(button.frame.height, 44, "\(id) \(button.frame)")
            XCTAssertGreaterThanOrEqual(button.frame.minX, box.minX - 1, "\(id) left the window")
            XCTAssertLessThanOrEqual(button.frame.maxX, box.maxX + 1, "\(id) left the window")
        }
        save(app, "mock-198-iphone-large-text")
    }

    @MainActor
    func testPhoneSources() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone window shot")
        let (app, box) = try launch("listenerMockPhoneSources")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["mock198.sources"].waitForExistence(timeout: 10), "Sources screen\n\(app.debugDescription)")
        for id in ["fact", "weather", "news", "personal"] {
            XCTAssertTrue(any["mock198.source.\(id)"].exists, "source row \(id)\n\(app.debugDescription)")
        }
        let link = app.buttons["mock198.source.weather.link"]
        if link.exists { assertTarget(link, in: box, "weather legal link") }
        save(app, "mock-198-iphone-sources")
    }

    // MARK: Open Duo (fixed containers)

    @MainActor
    func testDuoOpenPortrait() throws {
        let (app, box) = try launch("listenerMockDuoPortrait", container: Self.duoPortrait)
        assertControlsTargets(app, in: box)
        assertOneColumn(app)
        save(app, "mock-198-duo-open-portrait", container: container(app))
    }

    @MainActor
    func testDuoOpenPortraitDark() throws {
        let (app, box) = try launch("listenerMockDuoPortrait", container: Self.duoPortrait, dark: true)
        assertControlsTargets(app, in: box)
        save(app, "mock-198-duo-open-portrait-dark", container: container(app))
    }

    @MainActor
    func testDuoOpenLandscape() throws {
        let (app, box) = try launch("listenerMockDuoLandscape", container: Self.duoLandscape)
        assertTwoColumns(app, in: box)
        save(app, "mock-198-duo-open-landscape", container: container(app))
    }

    // MARK: iPad (regular window)

    @MainActor
    func testPadListenerControls() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad window shot")
        let (app, box) = try launch("listenerMockPad")
        assertTwoColumns(app, in: box)
        save(app, "mock-198-ipad")
    }

    @MainActor
    func testPadListenerControlsDark() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad window shot")
        let (app, box) = try launch("listenerMockPad", dark: true)
        assertTwoColumns(app, in: box)
        save(app, "mock-198-ipad-dark")
    }

    // MARK: Helpers

    /// Launches the capture; returns the app and the frame the mock is drawn in (the container
    /// for the Duo frames, else the window).
    @MainActor
    private func launch(_ scenario: String, container size: CGSize? = nil, dark: Bool = false,
                        contentSize: String? = nil) throws -> (XCUIApplication, CGRect) {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", scenario]
        if dark { app.launchArguments += ["-AeroDJStudioCaptureDark", "YES"] }
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        XCUIDevice.shared.orientation = .portrait
        app.launchAfterLeftoverExits()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window\n\(app.debugDescription)")
        if let size {
            try XCTSkipUnless(window.frame.width >= size.width && window.frame.height >= size.height,
                              "window \(window.frame.size) is smaller than the \(size) container")
        }
        let root = container(app)
        XCTAssertTrue(root.waitForExistence(timeout: 15), "mock missing\n\(app.debugDescription)")
        guard let size else { return (app, window.frame) }
        return (app, try settled(root, size: size))
    }

    @MainActor
    private func container(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["capture.listenerMockContainer"]
    }

    /// The container's frame once it has its final size, polled, never a fixed sleep.
    @MainActor
    private func settled(_ element: XCUIElement, size: CGSize) throws -> CGRect {
        let deadline = Date().addingTimeInterval(10)
        var last = CGRect.null
        while Date() < deadline {
            let frame = element.frame
            if abs(frame.width - size.width) <= 1, abs(frame.height - size.height) <= 1, frame == last { return frame }
            last = frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("container never settled at \(size): \(element.frame)")
        return last
    }

    /// Every control above the fold is at least 44 pt tall and inside the frame.
    @MainActor
    private func assertControlsTargets(_ app: XCUIApplication, in box: CGRect) {
        for p in ["warm", "upbeat", "laidBack", "minimal"] {
            let row = app.buttons["mock198.personality.\(p)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "personality \(p)\n\(app.debugDescription)")
            assertTarget(row, in: box, "personality \(p)")
        }
        for id in ["mock198.language.english", "mock198.language.spanish",
                   "mock198.spanglish.off", "mock198.spanglish.light", "mock198.spanglish.conversational"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.exists, "\(id) missing\n\(app.debugDescription)")
            if box.contains(button.frame) { assertTarget(button, in: box, id) }
        }
        let web = app.switches["mock198.topic.web"]
        if web.exists {
            XCTAssertFalse(web.isEnabled, "web lookups are not built: shown off and disabled")
        }
    }

    /// Compact: the language card sits under the personality card, same leading edge.
    @MainActor
    private func assertOneColumn(_ app: XCUIApplication) {
        let warm = app.buttons["mock198.personality.warm"].frame
        let english = app.buttons["mock198.language.english"].frame
        XCTAssertGreaterThan(english.minY, warm.maxY, "language is below personality")
        XCTAssertEqual(app.buttons["mock198.allSources"].exists, true, "compact pushes All sources")
    }

    /// Regular: topics and Sources are the second column, right of personality, with a side inset.
    @MainActor
    private func assertTwoColumns(_ app: XCUIApplication, in box: CGRect) {
        let warm = app.buttons["mock198.personality.warm"]
        let facts = app.switches["mock198.topic.songFacts"]
        XCTAssertTrue(warm.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(facts.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThan(facts.frame.minX, warm.frame.maxX, "topics are the second column")
        XCTAssertGreaterThanOrEqual(warm.frame.minX, box.minX + 28, "side inset \(warm.frame) in \(box)")
        XCTAssertFalse(app.buttons["mock198.allSources"].exists, "regular shows every source inline")
        assertTarget(warm, in: box, "personality warm")
        assertTarget(facts, in: box, "song facts switch")
    }

    @MainActor
    private func assertTarget(_ element: XCUIElement, in box: CGRect, _ name: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        assertAtLeastPoints(element.frame.height, 44, "\(name) \(element.frame)", file: file, line: line)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(element.frame), "\(name) left the frame \(element.frame)",
                      file: file, line: line)
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String, container: XCUIElement? = nil) {
        let shot = container.map { $0.screenshot() } ?? app.screenshot()
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
