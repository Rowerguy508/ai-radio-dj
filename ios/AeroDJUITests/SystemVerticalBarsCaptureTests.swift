import XCTest
import UIKit

/// #465 item 1, DEBUG capture only (-Nova): the open Duo with the iOS 27.1 system vertical bar
/// in place of Rail D, for the owner's decision. Launched with `-AeroDJCaptureSystemVerticalBars
/// YES`; the frames are Rail D's (640 x 820 compact, 820 x 640 regular with a flat hinge).
///
/// Skips, never fails, where the shot can't be real:
/// - a window smaller than the frame (the hosted iPhone Duo window, 466 x 678, and every iPhone),
/// - a binary or OS without the vertical bar (`capture.systemVerticalBars` reads `railD`: the
///   Xcode 26.6 / iOS 26.5 SDK lanes compile the toolbar out).
/// Shots (not required in ios.yml): system-vertical-bars-duo-open-portrait,
/// system-vertical-bars-duo-open-portrait-collapsed, system-vertical-bars-duo-open-landscape,
/// system-vertical-bars-duo-open-landscape-collapsed.
///
/// Whether iOS draws the bar vertically is the system's call (`toolbarVerticalBehavior(.automatic)`
/// resolves by device and window), so the axis is recorded in the attachment, not asserted.
final class SystemVerticalBarsCaptureTests: XCTestCase {
    private static let portrait = CGSize(width: 640, height: 820)
    private static let landscape = CGSize(width: 820, height: 640)
    private static let flag = ["-AeroDJCaptureSystemVerticalBars", "YES"]

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        try await super.tearDown()
    }

    @MainActor
    func testOpenPortraitSystemVerticalBars() throws {
        try run("systemVerticalBarsDuoOpenPortrait", size: Self.portrait, orientation: .portrait,
                shot: "system-vertical-bars-duo-open-portrait")
    }

    @MainActor
    func testOpenLandscapeSystemVerticalBars() throws {
        try run("systemVerticalBarsDuoOpenLandscape", size: Self.landscape, orientation: .landscapeLeft,
                shot: "system-vertical-bars-duo-open-landscape")
    }

    // MARK: Flow

    @MainActor
    private func run(_ scenario: String, size: CGSize, orientation: UIDeviceOrientation, shot: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", scenario] + Self.flag
        XCUIDevice.shared.orientation = orientation
        app.launchAfterLeftoverExits()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window\n\(app.debugDescription)")
        try XCTSkipUnless(window.frame.width >= size.width && window.frame.height >= size.height,
                          "window \(window.frame.size) is smaller than the \(size) frame")
        let any = app.descendants(matching: .any)
        let loading = any["capture.loading"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed, "capture still loading\n\(app.debugDescription)")
        let failed = any["capture.failed"]
        if failed.exists { XCTFail(failed.label) }

        let marker = any["capture.systemVerticalBars"]
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "marker missing\n\(app.debugDescription)")
        try XCTSkipUnless(marker.label == "system",
                          "this binary or OS has no iOS 27.1 vertical bar (marker \(marker.label)); Rail D is drawn")

        let container = any["capture.railDContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 10), "container missing\n\(app.debugDescription)")
        let spinners = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.activityIndicators)
        _ = XCTWaiter().wait(for: [spinners], timeout: 10)

        // The system bar replaces the custom rail; it never sits beside it.
        let collapse = app.buttons["folded.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10), "Collapse missing from the system bar\n\(app.debugDescription)")
        XCTAssertFalse(any["folded.systemBar"].exists, "the custom rail is drawn under the system bar")

        // Every bar control the system shows keeps a 44 pt target.
        var frames: [String: CGRect] = [:]
        for id in ["folded.collapse", "folded.more", "transport.playPause", "transport.skip",
                   "queue.affordance", "folded.sleepTimer", "folded.liveDot"] {
            let element = any[id].firstMatch
            guard element.exists, element.isHittable else { continue }
            frames[id] = element.frame
            assertAtLeastPoints(element.frame.width, 44, "\(id) width")
            assertAtLeastPoints(element.frame.height, 44, "\(id) height")
        }
        record(axis(of: frames), name: "\(shot)-axis")
        save(app, shot)

        // The owner's open question: should Collapse keep a rail at all?
        collapse.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: collapse)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed,
                       "Collapse is still in the bar after collapsing\n\(app.debugDescription)")
        let expand = app.buttons["folded.expandRail"]
        if expand.waitForExistence(timeout: 5), expand.isHittable {
            assertAtLeastPoints(expand.frame.width, 44, "folded.expandRail width")
            assertAtLeastPoints(expand.frame.height, 44, "folded.expandRail height")
        }
        save(app, "\(shot)-collapsed")
    }

    /// "vertical" when the bar's controls stack in one column, "horizontal" when they share a row.
    private func axis(of frames: [String: CGRect]) -> String {
        let rects = Array(frames.values)
        guard rects.count >= 2 else { return "unknown (\(rects.count) bar controls hittable)" }
        let xs = rects.map(\.midX), ys = rects.map(\.midY)
        let xSpread = (xs.max() ?? 0) - (xs.min() ?? 0)
        let ySpread = (ys.max() ?? 0) - (ys.min() ?? 0)
        let summary = frames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return (ySpread > xSpread ? "vertical" : "horizontal") + "\n" + summary
    }

    private func record(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The app screenshot (status bar and all, so the owner sees where the system put the bar),
    /// saved like the Rail D shots: `<name>_<device>.png` in `STUDIO_SCREENSHOT_DIR`.
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
