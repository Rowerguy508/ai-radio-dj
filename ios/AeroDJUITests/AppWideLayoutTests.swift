import XCTest
import UIKit

/// #465 item 10 (-Nova): Library, Stations and Settings at the unfolded Duo's inner display
/// (640 × 820 pt, compact class) and at narrow Split View (340 × 760 pt, compact class). The
/// captures (`AppWideCaptureScenario`) draw the real screens in a fixed container, so these run
/// on any simulator whose window is big enough. Saves `duo-wide-library`, `duo-wide-stations`
/// and `duo-wide-settings` (required in ios.yml, like `duo-wide-ready`) plus the narrow shots.
final class AppWideLayoutTests: XCTestCase {
    private static let duo = CGSize(width: 640, height: 820)
    private static let narrow = CGSize(width: 340, height: 760)

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ scenario: String, size: CGSize) throws -> (XCUIApplication, CGRect) {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", scenario]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window\n\(app.debugDescription)")
        try XCTSkipUnless(window.frame.width >= size.width && window.frame.height >= size.height,
                          "window \(window.frame.size) is smaller than the \(size) container")
        let loading = app.descendants(matching: .any)["capture.loading"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed, "capture still loading\n\(app.debugDescription)")
        let failed = app.descendants(matching: .any)["capture.failed"]
        if failed.exists { XCTFail(failed.label) }
        return (app, try settledContainer(app, size: size))
    }

    /// The container's frame once it has its final size, polled, never a fixed sleep.
    @MainActor
    private func settledContainer(_ app: XCUIApplication, size: CGSize) throws -> CGRect {
        let container = app.descendants(matching: .any)["capture.appWideContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 10), "container missing\n\(app.debugDescription)")
        let deadline = Date().addingTimeInterval(10)
        var last = CGRect.null
        while Date() < deadline {
            let frame = container.frame
            if abs(frame.width - size.width) <= 1, abs(frame.height - size.height) <= 1, frame == last { return frame }
            last = frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("container never settled at \(size): \(container.frame)")
        return last
    }

    @MainActor
    private func assertTarget(_ element: XCUIElement, in box: CGRect, _ name: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) \(element.frame)", file: file, line: line)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(element.frame), "\(name) left the container", file: file, line: line)
    }

    @MainActor
    private func decision(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["appWide.decision"].label
    }

    @MainActor
    private func openLibraryTab(_ app: XCUIApplication) {
        let source = app.segmentedControls["addStation.playlistSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), "playlist source missing\n\(app.debugDescription)")
        source.buttons["Your library"].tap()
    }

    private func libraryRow(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        let names = ["Road Trip", "Sunday Slow", "Focus Flow", "Late Night Drive"]
        return app.buttons["[TEST] \(names[index]), \(12 + index * 7) songs"]
    }

    // MARK: Duo inner display

    @MainActor
    func testDuoWideLibraryIsTwoReadableColumns() throws {
        let (app, box) = try launch("duoWideLibrary", size: Self.duo)
        XCTAssertEqual(decision(app), "wide 2 40")
        openLibraryTab(app)
        XCTAssertTrue(app.descendants(matching: .any)["addStation.results.grid"].waitForExistence(timeout: 10),
                      "library grid missing\n\(app.debugDescription)")
        let first = libraryRow(app, 0)
        let second = libraryRow(app, 1)
        let third = libraryRow(app, 2)
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(second.exists && third.exists, app.debugDescription)
        // Across, then down: VoiceOver reads the same order as the phone list.
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 1, "rows 1 and 2 share a line")
        XCTAssertLessThan(first.frame.maxX, second.frame.minX, "row 2 is the second column")
        XCTAssertGreaterThan(third.frame.minY, first.frame.maxY, "row 3 starts the next line")
        for (name, row) in [("row 1", first), ("row 2", second), ("row 3", third)] {
            assertTarget(row, in: box, name)
        }
        // Readable width: 40 pt inset plus the 20 pt gutter on each side.
        XCTAssertGreaterThanOrEqual(first.frame.minX, box.minX + 59, "left edge \(first.frame)")
        XCTAssertLessThanOrEqual(second.frame.maxX, box.maxX - 59, "right edge \(second.frame)")
        let next = app.buttons["addStation.next"]
        XCTAssertTrue(next.exists)
        XCTAssertGreaterThanOrEqual(next.frame.minX, box.minX + 59, "the footer holds the same width")
        XCTAssertTrue(app.buttons["addStation.cancel"].exists, "Cancel stays in the bar")
        save(app, "duo-wide-library")
    }

    @MainActor
    func testDuoWideStationsIsAGridOfTheCarouselCards() throws {
        let (app, box) = try launch("duoWideStations", size: Self.duo)
        XCTAssertEqual(decision(app), "wide 3 0")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["stations.grid"].waitForExistence(timeout: 10), "grid missing\n\(app.debugDescription)")
        XCTAssertFalse(any["stations.carousel"].exists, "the grid replaces the carousel at Duo width")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stations.card.'"))
        XCTAssertGreaterThanOrEqual(cards.count, 2, app.debugDescription)
        let first = cards.element(boundBy: 0)
        let second = cards.element(boundBy: 1)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1, "two stations on one row")
        XCTAssertLessThan(first.frame.maxX, second.frame.minX)
        assertTarget(first, in: box, "card 1")
        assertTarget(second, in: box, "card 2")
        XCTAssertGreaterThanOrEqual(first.frame.width, 160, "a card keeps room for its name")
        // Same VoiceOver text as the carousel card: name, then the vibe line, and a hint.
        XCTAssertFalse(first.label.isEmpty)
        save(app, "duo-wide-stations")
        first.tap()
        XCTAssertTrue(first.isSelected, "a tap uses the split's selection path")
    }

    @MainActor
    func testDuoWideSettingsIsOneReadableColumnWithDoneInTheBar() throws {
        let (app, box) = try launch("duoWideSettings", size: Self.duo)
        XCTAssertEqual(decision(app), "wide 1 40")
        let toggle = app.switches["settings.talkoverToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "talk-over row missing\n\(app.debugDescription)")
        let cell = app.cells.containing(.switch, identifier: "settings.talkoverToggle").firstMatch
        let row = cell.exists ? cell.frame : toggle.frame
        XCTAssertGreaterThanOrEqual(row.minX, box.minX + 55, "the row is inset to the readable width: \(row)")
        XCTAssertLessThanOrEqual(row.maxX, box.maxX - 55, "the row is inset to the readable width: \(row)")
        let done = app.buttons["settings.done"]
        XCTAssertTrue(done.exists)
        assertTarget(done, in: box, "Done")
        XCTAssertGreaterThan(done.frame.midX, box.midX, "Done stays on the bar's trailing side")
        save(app, "duo-wide-settings")
    }

    // MARK: Narrow Split View: the phone path, unchanged

    @MainActor
    func testNarrowSplitLibraryKeepsThePhoneList() throws {
        let (app, box) = try launch("splitNarrowLibrary", size: Self.narrow)
        XCTAssertEqual(decision(app), "phone 1 0")
        openLibraryTab(app)
        let first = libraryRow(app, 0)
        let second = libraryRow(app, 1)
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["addStation.results.grid"].exists, "no grid on the phone path")
        XCTAssertGreaterThan(second.frame.minY, first.frame.maxY - 1, "one column")
        XCTAssertEqual(first.frame.minX, box.minX + 20, accuracy: 1, "the phone's 20 pt gutter")
        assertTarget(first, in: box, "row 1")
        save(app, "split-narrow-library")
    }

    @MainActor
    func testNarrowSplitStationsKeepsTheCarousel() throws {
        let (app, _) = try launch("splitNarrowStations", size: Self.narrow)
        XCTAssertEqual(decision(app), "phone 1 0")
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["stations.carousel"].waitForExistence(timeout: 10), "carousel missing\n\(app.debugDescription)")
        XCTAssertFalse(any["stations.grid"].exists, "no grid on the phone path")
        save(app, "split-narrow-stations")
    }

    @MainActor
    func testNarrowSplitSettingsKeepsTheSystemInset() throws {
        let (app, box) = try launch("splitNarrowSettings", size: Self.narrow)
        XCTAssertEqual(decision(app), "phone 1 0")
        let toggle = app.switches["settings.talkoverToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(toggle.frame.minX, box.minX + 40, "no extra inset on the phone path")
        assertTarget(app.buttons["settings.done"], in: box, "Done")
        save(app, "split-narrow-settings")
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
