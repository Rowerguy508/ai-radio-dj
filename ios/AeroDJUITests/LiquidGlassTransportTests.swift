import XCTest
import UIKit

/// #465 item 9: the Liquid Glass transport under Reduce Transparency, Increase Contrast and
/// Reduce Motion, in the Debug test station's capture mode. The settings are forced with the
/// Debug-only `AeroGlassDebug` / `StudioCapture` launch keys, because the simulator's own
/// accessibility switches cannot be set before launch. The glass decision itself is unit tested
/// for every combination in AeroDJCore (`GlassTreatmentTests`); this checks that each mode
/// renders, keeps Tune, Play/Pause and Skip hittable, and saves a screenshot for review
/// (`glass-<mode>_<device>.png` in `$STUDIO_SCREENSHOT_DIR`).
final class LiquidGlassTransportTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private enum Mode: String {
        case standard
        case reduceTransparency = "reduce-transparency"
        case increaseContrast = "increase-contrast"
        case reduceMotion = "reduce-motion"
        case all

        var launchArguments: [String] {
            switch self {
            case .standard: []
            case .reduceTransparency: ["-AeroDJReduceTransparency", "YES"]
            case .increaseContrast: ["-AeroDJIncreaseContrast", "YES"]
            case .reduceMotion: ["-AeroDJReduceMotion", "YES"]
            case .all: Mode.reduceTransparency.launchArguments + Mode.increaseContrast.launchArguments
                + Mode.reduceMotion.launchArguments
            }
        }
    }

    @MainActor
    func testStandardGlassTransport() { check(.standard) }

    @MainActor
    func testReduceTransparencyTransport() { check(.reduceTransparency) }

    @MainActor
    func testIncreaseContrastTransport() { check(.increaseContrast) }

    @MainActor
    func testReduceMotionTransport() { check(.reduceMotion) }

    @MainActor
    func testAllAccessibilitySettingsTransport() { check(.all) }

    @MainActor
    private func check(_ mode: Mode) {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES"] + mode.launchArguments
        app.launch()
        defer { app.terminate() }

        let loading = app.descendants(matching: .any)["capture.loading"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed,
                       "Studio capture still loading after 20 s (\(mode.rawValue))")
        let failed = app.descendants(matching: .any)["capture.failed"]
        if failed.exists { XCTFail(failed.label) }

        let play = app.buttons["transport.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Play/Pause missing (\(mode.rawValue))")
        XCTAssertTrue(play.isHittable, "Play/Pause not hittable (\(mode.rawValue))")
        XCTAssertTrue(app.buttons["transport.skip"].isHittable, "Skip not hittable (\(mode.rawValue))")
        let tune = app.buttons["transport.tune"]
        if tune.exists {
            XCTAssertTrue(tune.isHittable, "Tune not hittable (\(mode.rawValue))")
        }
        // The glass circles must not grow the 52 pt / 68 pt targets.
        XCTAssertEqual(play.frame.width, 68, accuracy: 1, "Play/Pause size (\(mode.rawValue))")
        XCTAssertEqual(app.buttons["transport.skip"].frame.width, 52, accuracy: 1, "Skip size (\(mode.rawValue))")
        save(app, "glass-\(mode.rawValue)")
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
