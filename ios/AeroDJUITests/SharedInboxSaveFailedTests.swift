import XCTest
import UIKit

/// #426 (-Sentinel): the "Shared with" review when the review store can't verify its backup
/// exclusion. Turning on "Include in my briefing" shows the fail-closed alert and leaves the
/// toggle off. Deleting goes ahead and says the choices were reset (Echo's blocker on #591).
/// Saves `shared-inbox-save-failed` and `shared-inbox-delete-reset` (not required in ios.yml).
final class SharedInboxSaveFailedTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testIncludeShowsTheFailClosedAlertAndStaysOff() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", "sharedInboxSaveFailed"]
        XCUIDevice.shared.orientation = .portrait
        app.launchAfterLeftoverExits()
        let toggle = app.switches["Include in my briefing"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "0")
        // Tap the switch itself, at its trailing edge, not the label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let alert = app.alerts["Something went wrong"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(alert.staticTexts["Couldn't save that change privately, so nothing changed. Please try again."].exists,
                      alert.debugDescription)
        save(app, "shared-inbox-save-failed")
        alert.buttons["OK"].tap()
        XCTAssertEqual(app.switches["Include in my briefing"].value as? String, "0", "not applied")
    }

    @MainActor
    func testDeleteGoesAheadAndSaysTheChoicesWereReset() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", "sharedInboxSaveFailed"]
        XCUIDevice.shared.orientation = .portrait
        app.launchAfterLeftoverExits()
        let note = app.staticTexts["Lunch moved to noon on Friday."]
        XCTAssertTrue(note.waitForExistence(timeout: 30), app.debugDescription)
        note.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), app.debugDescription)
        delete.tap()
        let alert = app.alerts["Something went wrong"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(alert.staticTexts["Done, but your choices couldn't be saved privately, so every item is set back to not included. Include the ones you want again."].exists,
                      alert.debugDescription)
        save(app, "shared-inbox-delete-reset")
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.staticTexts["Lunch moved to noon on Friday."].waitForExistence(timeout: 3), "the delete went ahead")
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
