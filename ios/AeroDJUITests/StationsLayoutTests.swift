import XCTest
import UIKit

/// Open-Duo Stations (owner, 2026-11-17): the three designs on the open Duo in the book pose
/// (820 × 640, fold band 396…424) and upright (640 × 820), Rail D (the player's full open-Duo
/// rail with the now-playing thumbnail in Collapse's place), and
/// Settings > Stations layout on the iPhone and the Duo (`StationsLayoutCaptureScenario`).
/// The Duo-sized frames need an iPad window: on an iPad they fail, never skip, if the window is
/// too small, and ios.yml requires every shot. Each test and helper is @MainActor, as in
/// RailDLayoutTests and StudioScreenTests (Swift 6). -Nova
final class StationsLayoutTests: XCTestCase {
    private static let book = CGSize(width: 820, height: 640)
    private static let portrait = CGSize(width: 640, height: 820)
    private static let phone = CGSize(width: 390, height: 844)
    /// `RailDCaptureContainer.foldBand`, in container points.
    private static let foldMinX: CGFloat = 396
    private static let foldMaxX: CGFloat = 424
    /// `RailDLayout.railWidth` and `RailDLayout.trailingInset` (spec D: 56 pt glass, 8 pt in),
    /// as in `RailDLayoutTests.railGlassWidth` / `railEdgeInset`.
    private static let railGlassWidth: CGFloat = 56
    private static let railEdgeInset: CGFloat = 8

    /// The open Duo window from the owner's build 54 shots (@3x): 951 × 669 pt.
    private static let device = CGSize(width: 951, height: 669)

    override func setUp() {
        continueAfterFailure = false
    }

    /// The regular-width device frames launch sideways; leave the simulator upright.
    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        try await super.tearDown()
    }

    /// The centred 28 pt fold band for a container (`StationsLayoutCaptureScenario.foldBand`):
    /// 396…424 at 820 pt.
    private static func foldBand(_ size: CGSize) -> (min: CGFloat, max: CGFloat) {
        ((size.width - 28) / 2, (size.width + 28) / 2)
    }

    // MARK: Regular width (build 54: the device reports regular on the open Duo)

    /// The primary build 54 check: the device's 951 × 669 window at the regular width class, no
    /// fold override. Duo Stations (not the system split), Rail D with the 44 pt thumbnail, every
    /// target 44 pt, and a tile pushes the player over the whole window (no sidebar beside it).
    @MainActor
    func testRegularWidthDeviceWindow() throws {
        let (app, box) = try checkStations("stationsLayoutARegularDevice", style: "tiles", size: Self.device,
                                           rowPrefix: "stations.tile.", rows: 8,
                                           shot: "stations-layout-a-duo-open-regular-951x669",
                                           orientation: .landscapeLeft)
        assertNoSystemSplit(app)
        let late = stationButton(app, prefix: "stations.tile.", named: "Late Night")
        XCTAssertTrue(late.isHittable, "Late Night tile")
        late.tap()
        assertPlayerOpened(app, station: "Late Night")
        assertPlayerFillsTheWindow(app, box: box)
        save(app, "stations-layout-a-duo-open-regular-951x669-player",
             container: app.descendants(matching: .any)["capture.stationsLayoutContainer"])
    }

    /// The idiom-or-hinge gate: the same 951 × 669 regular window on an iPad (no phone idiom, no
    /// hinge) keeps today's system split, never the Duo Stations.
    @MainActor
    func testRegularWidthIPadWindowKeepsTheSplit() throws {
        let (app, _) = try launch("stationsLayoutARegularDevice", size: Self.device, needsPad: true,
                                  orientation: .landscapeLeft, phoneIdiom: false)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.staticTexts["Late Night"].waitForExistence(timeout: 10),
                      "the station list\n\(app.debugDescription)")
        XCTAssertFalse(any["stations.duo.tiles"].exists, "an iPad window must not get the Duo Stations")
        XCTAssertFalse(app.buttons["stations.rail.nowPlaying"].exists)
    }

    /// The same window with the hinge and a centred fold forced: nothing on the fold band.
    @MainActor
    func testRegularWidthDeviceWindowFold() throws {
        let (app, _) = try checkStations("stationsLayoutARegularDeviceFold", style: "tiles", size: Self.device,
                                         rowPrefix: "stations.tile.", rows: 8,
                                         shot: "stations-layout-a-duo-open-regular-951x669-fold",
                                         orientation: .landscapeLeft)
        assertNoSystemSplit(app)
    }

    /// The sim bands at regular width: book (820 × 640, fold forced) and upright (640 × 820).
    @MainActor
    func testRegularWidthBookPose() throws {
        let (app, box) = try checkStations("stationsLayoutABookRegular", style: "tiles", size: Self.book,
                                           rowPrefix: "stations.tile.", rows: 8,
                                           shot: "stations-layout-a-duo-open-regular-book",
                                           orientation: .landscapeLeft)
        assertNoSystemSplit(app)
        app.buttons["stations.rail.nowPlaying"].tap()
        assertPlayerOpened(app, station: "Morning Calm")
        assertPlayerFillsTheWindow(app, box: box)
    }

    @MainActor
    func testRegularWidthPortrait() throws {
        let (app, _) = try checkStations("stationsLayoutAPortraitRegular", style: "tiles", size: Self.portrait,
                                         rowPrefix: "stations.tile.", rows: 8,
                                         shot: "stations-layout-a-duo-open-regular-portrait")
        assertNoSystemSplit(app)
    }

    // MARK: A tile grid

    @MainActor
    func testLayoutABookPose() throws {
        let (app, _) = try checkStations("stationsLayoutABook", style: "tiles", size: Self.book,
                                         rowPrefix: "stations.tile.", rows: 8,
                                         shot: "stations-layout-a-duo-open-book")
        // A tile starts that station through the split's selection: the player opens.
        let late = stationButton(app, prefix: "stations.tile.", named: "Late Night")
        XCTAssertTrue(late.isHittable, "Late Night tile")
        late.tap()
        assertPlayerOpened(app, station: "Late Night")
    }

    /// ⋯ on the Stations rail: Rail D's own panel, inward of the rail, on the trailing page and
    /// off the fold. Tune opens the playing station's player on its Tune segment.
    @MainActor
    func testLayoutABookPoseMoreMenu() throws {
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

    @MainActor
    func testLayoutAPortrait() throws {
        let (app, _) = try checkStations("stationsLayoutAPortrait", style: "tiles", size: Self.portrait,
                                         rowPrefix: "stations.tile.", rows: 8,
                                         shot: "stations-layout-a-duo-open-portrait")
        // The rail's top slot opens the playing station's player.
        app.buttons["stations.rail.nowPlaying"].tap()
        assertPlayerOpened(app, station: "Morning Calm")
    }

    // MARK: B Daytime / After dark

    @MainActor
    func testLayoutBBookPose() throws {
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

    @MainActor
    func testLayoutBPortrait() throws {
        let (app, _) = try checkStations("stationsLayoutBPortrait", style: "editorial", size: Self.portrait,
                                         rowPrefix: "stations.listRow.", rows: 8,
                                         shot: "stations-layout-b-duo-open-portrait")
        let any = app.descendants(matching: .any)
        XCTAssertLessThan(any["stations.section.daytime"].frame.minY, any["stations.section.afterDark"].frame.minY,
                          "Daytime above After dark")
    }

    // MARK: C featured + Switch to

    @MainActor
    func testLayoutCBookPose() throws {
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

    @MainActor
    func testLayoutCPortrait() throws {
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

    // MARK: Settings > Stations layout

    @MainActor
    func testSettingsPickerOnIPhone() throws {
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

    @MainActor
    func testSettingsPickerOnTheDuo() throws {
        let (app, box) = try launch("stationsLayoutSettingsDuo", size: Self.portrait, needsPad: true)
        let rows = try settingsRows(app, box: box)
        for row in rows {
            XCTAssertGreaterThanOrEqual(row.frame.minX, box.minX + 59, "inset to the readable width: \(row.frame)")
            XCTAssertLessThanOrEqual(row.frame.maxX, box.maxX - 59, "inset to the readable width: \(row.frame)")
        }
        save(app, "settings-stations-layout-duo",
             container: app.descendants(matching: .any)["capture.stationsLayoutContainer"])
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ scenario: String, size: CGSize, needsPad: Bool,
                        orientation: UIDeviceOrientation = .portrait,
                        phoneIdiom: Bool? = nil) throws -> (XCUIApplication, CGRect) {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        if needsPad {
            try XCTSkipIf(isPhone, "open-Duo frame (\(size)) runs in the iPad step")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", scenario, "-AeroDJReduceMotion", "YES"]
        // Build 54: the regular-width frames stand in for the open Duo, a phone-idiom device
        // (`DeviceIdiom`, debug-only override). Pass false to see what an iPad window gets.
        if phoneIdiom ?? scenario.contains("Regular") {
            app.launchArguments += ["-AeroDJForcePhoneIdiom", "YES"]
        }
        XCUIDevice.shared.orientation = orientation
        app.launchAfterTerminatingIfRunning()
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
        // Clip to the window before comparing size, as in RailDLayoutTests.settledContainer
        // (lines 375-381): the container is `.contain`, so an unclipped child can make the
        // raw frame (0, 0, 390, 850.67) on an iPhone 16e even when the visible box is 390 × 844.
        let windowFrame = window.frame
        let box = try XCTUnwrap(settledFrame(of: container, "container", clippedTo: windowFrame) {
            abs($0.width - size.width) <= 1 && abs($0.height - size.height) <= 1
        }, "container never settled at \(size) in window \(windowFrame): \(container.frame)")
        return (app, box)
    }

    /// The element's frame once it is non-empty, equal (±0.5 pt) on two polls in a row and
    /// accepted by `isFinal`; nil after `timeout`. When `clippedTo` is set, the frame is
    /// intersected with that rect first, matching `RailDLayoutTests.settledFrame`.
    @MainActor
    private func settledFrame(of element: XCUIElement, _ name: String, timeout: TimeInterval = 10,
                              clippedTo clip: CGRect? = nil,
                              isFinal: (CGRect) -> Bool = { _ in true }) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: CGRect?
        while Date() < deadline {
            var frame = element.exists ? element.frame : .null
            if let clip, !clip.isNull, !clip.isEmpty, !frame.isNull { frame = frame.intersection(clip) }
            if !frame.isNull, !frame.isEmpty, isFinal(frame), let last,
               abs(last.minX - frame.minX) <= 0.5, abs(last.minY - frame.minY) <= 0.5,
               abs(last.width - frame.width) <= 0.5, abs(last.height - frame.height) <= 0.5 {
                return frame
            }
            last = (frame.isNull || frame.isEmpty || !isFinal(frame)) ? nil : frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("\(name) frame did not settle within \(timeout) s (last \(element.frame))")
        return nil
    }

    /// Everything every design must do: no carousel, Rail D 56 pt wide and 8 pt from the
    /// trailing edge, the thumbnail on top with its VoiceOver label, every station present, and
    /// every visible control at least 44 pt, left of the rail and clear of the fold.
    @MainActor
    private func checkStations(_ scenario: String, style: String, size: CGSize, rowPrefix: String, rows: Int,
                               shot: String,
                               orientation: UIDeviceOrientation = .portrait) throws -> (XCUIApplication, CGRect) {
        let (app, box) = try launch(scenario, size: size, needsPad: true, orientation: orientation)
        let band = Self.foldBand(size)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["stations.duo.\(style)"].waitForExistence(timeout: 10),
                      "design \(style) missing\n\(app.debugDescription)")
        XCTAssertFalse(any["stations.carousel"].exists, "#551's carousel is gone on the open Duo")
        XCTAssertFalse(any["stations.grid"].exists, "the old grid is replaced")

        let rail = any["stations.rail"]
        XCTAssertTrue(rail.exists, "Rail D missing")
        // `stations.rail` is `.accessibilityElement(children: .contain)`, so its frame is the
        // union of its children (the 52 pt song bar, the 44 pt plates), not the 56 pt glass the
        // view draws (`.frame(width: RailDLayout.railWidth)`): 2 pt in on each side. Read it as
        // RailDLayoutTests.assertRailEdgeInset does: no wider than the glass, centred 8 pt + 28 pt
        // in from the trailing edge. -Nova
        let railFrame = rail.frame
        XCTAssertLessThanOrEqual(railFrame.width, Self.railGlassWidth + 1, "rail \(railFrame) is wider than the glass")
        XCTAssertGreaterThanOrEqual(railFrame.width, 44, "rail \(railFrame) holds 44 pt plates")
        XCTAssertEqual(railFrame.midX, box.maxX - Self.railEdgeInset - Self.railGlassWidth / 2, accuracy: 1.5,
                       "the 56 pt rail sits 8 pt in from the trailing edge: rail \(railFrame), box \(box)")

        let thumb = app.buttons["stations.rail.nowPlaying"]
        XCTAssertTrue(thumb.exists, "thumbnail missing")
        XCTAssertEqual(thumb.label, "Open player, now playing Morning Calm")
        XCTAssertGreaterThanOrEqual(thumb.frame.width, 44)
        XCTAssertGreaterThanOrEqual(thumb.frame.height, 44)
        XCTAssertTrue(rail.frame.insetBy(dx: -1, dy: -1).contains(thumb.frame), "thumbnail sits in the rail")
        XCTAssertLessThanOrEqual(thumb.frame.minY, rail.frame.minY + 12, "the thumbnail is the top slot")
        assertFullRail(app, rail: rail, thumb: thumb, box: box, bookPose: size.width > size.height,
                       foldMaxX: band.max)

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
                let foldMin = box.minX + band.min
                let foldMax = box.minX + band.max
                XCTAssertFalse(frame.minX < foldMax && frame.maxX > foldMin, "\(name) is on the fold")
            }
        }
        save(app, shot, container: app.descendants(matching: .any)["capture.stationsLayoutContainer"])
        return (app, box)
    }

    /// The rest of Rail D's open-Duo rail under the thumbnail, in the player's order: ⋯,
    /// Play/Pause, Skip, Queue, the sleep timer, the song bar with its times and the live dot.
    /// Every item is at least 44 pt, centred in the 56 pt rail, inside it, and 10 pt from the next;
    /// the rail itself is right of the fold band in the book pose.
    @MainActor
    private func assertFullRail(_ app: XCUIApplication, rail: XCUIElement, thumb: XCUIElement, box: CGRect,
                                bookPose: Bool, foldMaxX: CGFloat? = nil) {
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
            XCTAssertGreaterThan(rail.frame.minX, box.minX + (foldMaxX ?? Self.foldMaxX), "the rail is clear of the fold band")
        }
    }

    /// Build 54: the open Duo at regular width is not the system split. No "Choose a station"
    /// detail, no two-zone Studio, no regular sidebar list beside the Stations screen.
    @MainActor
    private func assertNoSystemSplit(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        XCTAssertFalse(any["split.placeholder"].exists, "the system split's detail is showing\n\(app.debugDescription)")
        XCTAssertFalse(any["layout.studio"].exists, "no two-zone Studio")
        XCTAssertFalse(any["layout.studioStacked"].exists, "no stacked Studio")
    }

    /// The pushed player covers the container: no sidebar column beside it.
    @MainActor
    private func assertPlayerFillsTheWindow(_ app: XCUIApplication, box: CGRect) {
        let player = app.descendants(matching: .any)["capture.stationsLayout.player"]
        let frame = player.frame.intersection(box)
        XCTAssertEqual(frame.width, box.width, accuracy: 1.5, "player \(player.frame) beside a sidebar in \(box)")
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

    /// `container` set (the open-Duo frames only): the shot is that element's own capture, the
    /// 820 × 640 or 640 × 820 frame upright and whole, not the screen around it. Nil (the
    /// iPhone-sized Settings frame) keeps the app screenshot, so those PNGs do not change.
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
