import XCTest
import UIKit

/// Open-Duo Stations (owner, 2026-11-17): the three designs on the open Duo in the book pose
/// (820 × 640, fold band 396…424) and upright (640 × 820), Rail D (the player's full open-Duo
/// rail with the now-playing thumbnail in Collapse's place), and
/// Settings > Stations layout on the iPhone and the Duo (`StationsLayoutCaptureScenario`).
/// The Duo-sized frames need an iPad window: on an iPad they fail, never skip, if the window is
/// too small, and ios.yml requires every shot. Main-actor work runs inside
/// `MainActor.assumeIsolated` (no class-level @MainActor). -Nova
final class StationsLayoutTests: XCTestCase {
    private static let book = CGSize(width: 820, height: 640)
    private static let portrait = CGSize(width: 640, height: 820)
    private static let phone = CGSize(width: 390, height: 844)
    /// `RailDCaptureContainer.foldBand`, in container points.
    private static let foldMinX: CGFloat = 396
    private static let foldMaxX: CGFloat = 424

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: A tile grid

    func testLayoutABookPose() throws {
        try MainActor.assumeIsolated {
            let (app, _) = try checkStations("stationsLayoutABook", style: "tiles", size: Self.book,
                                             rowPrefix: "stations.tile.", rows: 8,
                                             shot: "stations-layout-a-duo-open-book")
            // A tile starts that station through the split's selection: the player opens.
            let late = stationButton(app, prefix: "stations.tile.", named: "Late Night")
            XCTAssertTrue(late.isHittable, "Late Night tile")
            late.tap()
            assertPlayerOpened(app, station: "Late Night")
        }
    }

    /// ⋯ on the Stations rail: Rail D's own panel, inward of the rail, on the trailing page and
    /// off the fold. Tune opens the playing station's player on its Tune segment.
    func testLayoutABookPoseMoreMenu() throws {
        try MainActor.assumeIsolated {
            let (app, box) = try launch("stationsLayoutABook", size: Self.book, needsPad: true)
            let any = app.descendants(matching: .any)
            XCTAssertTrue(any["stations.duo.tiles"].waitForExistence(timeout: 10), app.debugDescription)
            let rail = any["stations.rail"]
            app.buttons["folded.more"].tap()
            let menu = any["folded.moreMenu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "⋯ panel missing\n\(app.debugDescription)")
            XCTAssertLessThanOrEqual(menu.frame.maxX, rail.frame.minX, "the panel opens inward of the rail")
            XCTAssertGreaterThanOrEqual(menu.frame.minX, box.minX + Self.foldMaxX, "the panel stays off the fold")
            for id in ["more.connections", "transport.tune"] {
                let row = any[id]
                XCTAssertTrue(row.exists, "\(id) missing\n\(app.debugDescription)")
                XCTAssertGreaterThanOrEqual(row.frame.height, 44, "\(id) \(row.frame)")
            }
            any["transport.tune"].tap()
            assertPlayerOpened(app, station: "Morning Calm")
            XCTAssertTrue(any["capture.stationsLayout.player"].label.hasSuffix(", tune"),
                          "Tune asks the player for its Tune segment: \(any["capture.stationsLayout.player"].label)")
        }
    }

    func testLayoutAPortrait() throws {
        try MainActor.assumeIsolated {
            let (app, _) = try checkStations("stationsLayoutAPortrait", style: "tiles", size: Self.portrait,
                                             rowPrefix: "stations.tile.", rows: 8,
                                             shot: "stations-layout-a-duo-open-portrait")
            // The rail's top slot opens the playing station's player.
            app.buttons["stations.rail.nowPlaying"].tap()
            assertPlayerOpened(app, station: "Morning Calm")
        }
    }

    // MARK: B Daytime / After dark

    func testLayoutBBookPose() throws {
        try MainActor.assumeIsolated {
            let (app, box) = try checkStations("stationsLayoutBBook", style: "editorial", size: Self.book,
                                               rowPrefix: "stations.listRow.", rows: 8,
                                               shot: "stations-layout-b-duo-open-book")
            let any = app.descendants(matching: .any)
            let day = any["stations.section.daytime"]
            let night = any["stations.section.afterDark"]
            XCTAssertTrue(day.exists && night.exists, app.debugDescription)
            // Daytime on the leading page, After dark on the trailing one.
            XCTAssertLessThan(day.frame.maxX, box.minX + Self.foldMinX + 1)
            XCTAssertGreaterThan(night.frame.minX, box.minX + Self.foldMaxX - 1)
        }
    }

    func testLayoutBPortrait() throws {
        try MainActor.assumeIsolated {
            let (app, _) = try checkStations("stationsLayoutBPortrait", style: "editorial", size: Self.portrait,
                                             rowPrefix: "stations.listRow.", rows: 8,
                                             shot: "stations-layout-b-duo-open-portrait")
            let any = app.descendants(matching: .any)
            XCTAssertLessThan(any["stations.section.daytime"].frame.minY, any["stations.section.afterDark"].frame.minY,
                              "Daytime above After dark")
        }
    }

    // MARK: C featured + Switch to

    func testLayoutCBookPose() throws {
        try MainActor.assumeIsolated {
            let (app, box) = try checkStations("stationsLayoutCBook", style: "featured", size: Self.book,
                                               rowPrefix: "stations.switchRow.", rows: 7,
                                               shot: "stations-layout-c-duo-open-book")
            let featured = app.descendants(matching: .any)["stations.featured"]
            XCTAssertTrue(featured.exists, app.debugDescription)
            XCTAssertLessThan(featured.frame.maxX, box.minX + Self.foldMinX + 1, "the card stays on the leading page")
            XCTAssertFalse(stationButton(app, prefix: "stations.switchRow.", named: "Morning Calm").exists,
                           "the playing station is the card, not a row")
            let open = app.buttons["stations.featured.openPlayer"]
            assertTarget(open, in: box, "Open player")
            open.tap()
            assertPlayerOpened(app, station: "Morning Calm")
        }
    }

    func testLayoutCPortrait() throws {
        try MainActor.assumeIsolated {
            let (app, _) = try checkStations("stationsLayoutCPortrait", style: "featured", size: Self.portrait,
                                             rowPrefix: "stations.switchRow.", rows: 7,
                                             shot: "stations-layout-c-duo-open-portrait")
            // Queue on the Stations rail opens the playing station's player on its queue.
            let queue = app.buttons["queue.affordance"]
            XCTAssertEqual(queue.label, "Up next: Salt Lines by Paper Lanterns")
            queue.tap()
            assertPlayerOpened(app, station: "Morning Calm")
            let player = app.descendants(matching: .any)["capture.stationsLayout.player"]
            XCTAssertTrue(player.label.hasSuffix(", queue"), "Queue asks for the queue: \(player.label)")
        }
    }

    // MARK: Settings > Stations layout

    func testSettingsPickerOnIPhone() throws {
        try MainActor.assumeIsolated {
            let (app, box) = try launch("stationsLayoutSettingsPhone", size: Self.phone, needsPad: false)
            let rows = try settingsRows(app, box: box)
            XCTAssertTrue(app.switches["settings.talkoverToggle"].exists, "the existing rows stay")
            save(app, "settings-stations-layout-iphone")
            // A tap picks that design; the default comes back with a tap on A.
            rows[1].tap()
            waitSelected(rows[1])
            XCTAssertFalse(rows[0].isSelected)
            rows[0].tap()
            waitSelected(rows[0])
        }
    }

    func testSettingsPickerOnTheDuo() throws {
        try MainActor.assumeIsolated {
            let (app, box) = try launch("stationsLayoutSettingsDuo", size: Self.portrait, needsPad: true)
            let rows = try settingsRows(app, box: box)
            for row in rows {
                XCTAssertGreaterThanOrEqual(row.frame.minX, box.minX + 59, "inset to the readable width: \(row.frame)")
                XCTAssertLessThanOrEqual(row.frame.maxX, box.maxX - 59, "inset to the readable width: \(row.frame)")
            }
            save(app, "settings-stations-layout-duo")
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ scenario: String, size: CGSize, needsPad: Bool) throws -> (XCUIApplication, CGRect) {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        if needsPad {
            try XCTSkipIf(isPhone, "open-Duo frame (\(size)) runs in the iPad step")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", scenario, "-AeroDJReduceMotion", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window\n\(app.debugDescription)")
        let fits = window.frame.width >= size.width && window.frame.height >= size.height
        if isPhone {
            try XCTSkipUnless(fits, "window \(window.frame.size) is smaller than \(size); the iPad step saves this shot")
        } else {
            XCTAssertTrue(fits, "iPad window \(window.frame.size) cannot hold \(size)")
        }
        let loading = app.descendants(matching: .any)["capture.loading"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 20), .completed, "capture still loading")
        let container = app.descendants(matching: .any)["capture.stationsLayoutContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 10), "container missing\n\(app.debugDescription)")
        let deadline = Date().addingTimeInterval(10)
        var last = CGRect.null
        while Date() < deadline {
            let frame = container.frame
            if abs(frame.width - size.width) <= 1, abs(frame.height - size.height) <= 1, frame == last {
                return (app, frame)
            }
            last = frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("container never settled at \(size): \(container.frame)")
        return (app, last)
    }

    /// Everything every design must do: no carousel, Rail D 56 pt wide and 8 pt from the
    /// trailing edge, the thumbnail on top with its VoiceOver label, every station present, and
    /// every visible control at least 44 pt, left of the rail and clear of the fold.
    @MainActor
    private func checkStations(_ scenario: String, style: String, size: CGSize, rowPrefix: String, rows: Int,
                               shot: String) throws -> (XCUIApplication, CGRect) {
        let (app, box) = try launch(scenario, size: size, needsPad: true)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["stations.duo.\(style)"].waitForExistence(timeout: 10),
                      "design \(style) missing\n\(app.debugDescription)")
        XCTAssertFalse(any["stations.carousel"].exists, "#551's carousel is gone on the open Duo")
        XCTAssertFalse(any["stations.grid"].exists, "the old grid is replaced")

        let rail = any["stations.rail"]
        XCTAssertTrue(rail.exists, "Rail D missing")
        XCTAssertEqual(rail.frame.width, 56, accuracy: 1, "rail \(rail.frame)")
        XCTAssertEqual(rail.frame.maxX, box.maxX - 8, accuracy: 1.5, "8 pt from the trailing edge")

        let thumb = app.buttons["stations.rail.nowPlaying"]
        XCTAssertTrue(thumb.exists, "thumbnail missing")
        XCTAssertEqual(thumb.label, "Open player, now playing Morning Calm")
        XCTAssertGreaterThanOrEqual(thumb.frame.width, 44)
        XCTAssertGreaterThanOrEqual(thumb.frame.height, 44)
        XCTAssertTrue(rail.frame.insetBy(dx: -1, dy: -1).contains(thumb.frame), "thumbnail sits in the rail")
        XCTAssertLessThanOrEqual(thumb.frame.minY, rail.frame.minY + 12, "the thumbnail is the top slot")
        assertFullRail(app, rail: rail, thumb: thumb, box: box, bookPose: size.width > size.height)

        let stationButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", rowPrefix))
        XCTAssertEqual(stationButtons.count, rows, "every station is drawn\n\(app.debugDescription)")
        XCTAssertTrue(stationButton(app, prefix: rowPrefix, named: "Late Night").exists)

        let controls = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'stations.' OR identifier BEGINSWITH 'transport.' OR identifier BEGINSWITH 'folded.' OR identifier BEGINSWITH 'queue.'"))
        for index in 0..<controls.count {
            let control = controls.element(boundBy: index)
            guard control.isHittable else { continue }
            let frame = control.frame
            let name = "\(control.identifier) \(frame)"
            XCTAssertGreaterThanOrEqual(frame.height, 44, name)
            XCTAssertGreaterThanOrEqual(frame.width, 44, name)
            if !rail.frame.insetBy(dx: -1, dy: -1).contains(frame) {
                XCTAssertLessThanOrEqual(frame.maxX, rail.frame.minX, "\(name) runs under the rail")
            }
            if size.width > size.height {
                let foldMin = box.minX + Self.foldMinX
                let foldMax = box.minX + Self.foldMaxX
                XCTAssertFalse(frame.minX < foldMax && frame.maxX > foldMin, "\(name) is on the fold")
            }
        }
        save(app, shot)
        return (app, box)
    }

    /// The rest of Rail D's open-Duo rail under the thumbnail, in the player's order: ⋯,
    /// Play/Pause, Skip, Queue, the sleep timer, the song bar with its times and the live dot.
    /// Every item is at least 44 pt, centred in the 56 pt rail, inside it, and 10 pt from the next;
    /// the rail itself is right of the fold band in the book pose.
    @MainActor
    private func assertFullRail(_ app: XCUIApplication, rail: XCUIElement, thumb: XCUIElement, box: CGRect,
                                bookPose: Bool) {
        let any = app.descendants(matching: .any)
        let items: [(String, XCUIElement)] = [
            ("thumbnail", thumb),
            ("more", any["folded.more"]),
            ("play/pause", any["transport.playPause"]),
            ("skip", any["transport.skip"]),
            ("queue", any["queue.affordance"]),
            ("sleep timer", any["folded.sleepTimer"]),
            ("song bar", any["playback.progress"]),
            ("live dot", any["folded.liveDot"]),
        ]
        var previous: (String, CGRect)?
        for (name, element) in items {
            XCTAssertTrue(element.exists, "\(name) missing from the Stations rail\n\(app.debugDescription)")
            let frame = element.frame
            XCTAssertTrue(rail.frame.insetBy(dx: -1, dy: -1).contains(frame), "\(name) \(frame) is outside the rail \(rail.frame)")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) \(frame)")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) \(frame)")
            XCTAssertEqual(frame.midX, rail.frame.midX, accuracy: 1.5, "\(name) is centred in the rail")
            if let previous {
                XCTAssertGreaterThanOrEqual(frame.minY - previous.1.maxY, 10 - 1, "\(name) sits 10 pt under \(previous.0)")
            }
            previous = (name, frame)
        }
        XCTAssertEqual(any["playback.progress"].value as? String, "1:12 of 3:45", "the song bar and its times")
        XCTAssertGreaterThanOrEqual(any["playback.progress"].frame.height, 44 + 36, "a 44 pt track plus both times")
        XCTAssertEqual(any["folded.liveDot"].label, "DJ live dot")
        XCTAssertFalse(any["folded.collapse"].exists, "the thumbnail replaces Collapse on Stations")
        if bookPose {
            XCTAssertGreaterThan(rail.frame.minX, box.minX + Self.foldMaxX, "the rail is clear of the fold band")
        }
    }

    @MainActor
    private func stationButton(_ app: XCUIApplication, prefix: String, named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", prefix, name)).firstMatch
    }

    @MainActor
    private func assertPlayerOpened(_ app: XCUIApplication, station: String) {
        let player = app.descendants(matching: .any)["capture.stationsLayout.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 8), "the player did not open\n\(app.debugDescription)")
        XCTAssertTrue(player.label.contains(station) || app.staticTexts["Player: \(station)"].exists,
                      "opened \(player.label), expected \(station)")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.buttons["stations.rail.nowPlaying"])
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 8), .completed, "Stations stayed over the player")
    }

    @MainActor
    private func settingsRows(_ app: XCUIApplication, box: CGRect) throws -> [XCUIElement] {
        let rows = ["tiles", "editorial", "featured"].map { app.buttons["settings.stationsLayout.\($0)"] }
        XCTAssertTrue(rows[0].waitForExistence(timeout: 10), "Stations layout rows missing\n\(app.debugDescription)")
        for row in rows {
            XCTAssertTrue(row.exists)
            assertTarget(row, in: box, row.identifier)
        }
        XCTAssertTrue(rows[0].isSelected, "unset is A, the tile grid")
        XCTAssertFalse(rows[1].isSelected)
        XCTAssertFalse(rows[2].isSelected)
        XCTAssertTrue(app.staticTexts["Stations layout"].exists || app.staticTexts["STATIONS LAYOUT"].exists,
                      "section header")
        return rows
    }

    @MainActor
    private func waitSelected(_ element: XCUIElement) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 5), .completed, "\(element.identifier) not selected")
    }

    @MainActor
    private func assertTarget(_ element: XCUIElement, in box: CGRect, _ name: String) {
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) \(element.frame)")
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(element.frame), "\(name) left the container")
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
