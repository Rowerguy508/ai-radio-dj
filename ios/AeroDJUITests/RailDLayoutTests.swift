import XCTest
import UIKit

/// Mockup D (owner: "Yes, build it", -Nova): one full-height 56 pt glass rail on the trailing
/// side (⋯, Play/Pause, Skip, Queue, Sleep, the vertical song-position bar, the live dot) on the
/// iPhone, the closed Duo and the open Duo; no horizontal progress bar. Each frame of the mock
/// is a capture (`RailDCaptureContainer`, or the plain capture path on the iPhone), checked and
/// saved here. Required in ios.yml: rail-d-iphone, rail-d-duo-closed, rail-d-duo-open-portrait,
/// rail-d-duo-open-portrait-sidebar, rail-d-duo-open-landscape-spread,
/// rail-d-duo-open-landscape-centred, rail-d-duo-open-landscape-sidebar. Not required:
/// rail-d-duo-open-landscape-book-collapsed (#548, the spread's frame with the rail collapsed).
/// A frame bigger than the simulator window is skipped, as in `AppWideLayoutTests`.
final class RailDLayoutTests: XCTestCase {
    private static let closed = CGSize(width: 390, height: 844)
    private static let portrait = CGSize(width: 640, height: 820)
    private static let landscape = CGSize(width: 820, height: 640)
    /// `RailDCaptureContainer.foldBand`, in container points.
    private static let foldMinX: CGFloat = 396
    private static let foldMaxX: CGFloat = 424
    /// `RailDLayout.railWidth` and `RailDLayout.trailingInset` (spec D: 56 pt glass, 8 pt in).
    private static let railGlassWidth: CGFloat = 56
    private static let railEdgeInset: CGFloat = 8

    override func setUp() {
        continueAfterFailure = false
    }

    /// The other suites launch in portrait; leave the simulator that way.
    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        try await super.tearDown()
    }

    // MARK: Frames

    @MainActor
    func testIPhoneRail() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The iPhone frame is the iPhone's own window")
        let app = try launch("railDPhone", container: nil, orientation: .portrait)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["folded.outer"].waitForExistence(timeout: 15), "the closed reskin\n\(app.debugDescription)")
        let rail = try assertRail(app, id: "folded.closedRail", hasCollapse: false)
        assertNoHorizontalBar(app)
        if let window = settledFrame(of: app.windows.firstMatch, "window") {
            assertRailEdgeInset(rail, trailingEdge: window.maxX)
        }
        try assertClosedChip(app, rail: rail)
        save(app, "rail-d-iphone")
    }

    @MainActor
    func testClosedDuoRail() throws {
        let app = try launch("railDDuoClosed", container: Self.closed, orientation: .portrait)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["folded.outer"].waitForExistence(timeout: 15), "the closed reskin\n\(app.debugDescription)")
        let box = try settledContainer(app, size: Self.closed)
        let rail = try assertRail(app, id: "folded.closedRail", hasCollapse: false)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail), "rail \(rail) left the container \(box)")
        assertRailEdgeInset(rail, trailingEdge: box.maxX)
        assertNoHorizontalBar(app)
        try assertClosedChip(app, rail: rail)
        save(app, "rail-d-duo-closed")
    }

    @MainActor
    func testOpenPortraitRail() throws {
        let app = try launch("railDPortrait", container: Self.portrait, orientation: .portrait)
        let box = try settledContainer(app, size: Self.portrait)
        let rail = try assertRail(app, id: "folded.systemBar", hasCollapse: true)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail))
        assertNoHorizontalBar(app)
        try assertChipLinesUpWithTitle(app)
        let track = try XCTUnwrap(settledFrame(of: app.descendants(matching: .any)["folded.trackColumn"], "track column"))
        XCTAssertLessThan(track.maxX, box.minX + Self.foldMaxX, "art and title stay leading of the fold")
        save(app, "rail-d-duo-open-portrait")
    }

    /// #434 (owner, Nov 23 2026): on the open Duo the art hides while the DJ talks, as on
    /// iPhone. The orb takes the art's frame; the content-column orb is gone (one orb). -Nova
    @MainActor
    func testOpenPortraitOnAirHidesTheArt() throws {
        let app = try launch("railDPortraitOnAir", container: Self.portrait, orientation: .portrait)
        let box = try settledContainer(app, size: Self.portrait)
        let any = app.descendants(matching: .any)
        let rail = try assertRail(app, id: "folded.systemBar", hasCollapse: true)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail))
        XCTAssertTrue(any["dj.onAir"].waitForExistence(timeout: 10), "On Air missing\n\(app.debugDescription)")
        assertOrbOnlyArtCard(app)
        save(app, "rail-d-duo-open-portrait-onair",
             container: app.descendants(matching: .any)["capture.railDContainer"])
    }

    @MainActor
    func testOpenPortraitWithTheSidebar() throws {
        let app = try launch("railDPortraitSidebar", container: Self.portrait, orientation: .portrait)
        let box = try settledContainer(app, size: Self.portrait)
        try assertSidebarRailColumn(app, box: box)
        save(app, "rail-d-duo-open-portrait-sidebar")
    }

    @MainActor
    func testOpenLandscapeSpread() throws {
        let app = try launch("railDLandscapeSpread", container: Self.landscape, orientation: .landscapeLeft)
        let box = try settledContainer(app, size: Self.landscape)
        let any = app.descendants(matching: .any)
        let rail = try assertRail(app, id: "folded.systemBar", hasCollapse: true)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail))
        assertNoHorizontalBar(app)
        let title = try assertChipLinesUpWithTitle(app)
        let foldMin = box.minX + Self.foldMinX
        let foldMax = box.minX + Self.foldMaxX
        // L1: the art in the leading half, the type after the fold.
        let track = try XCTUnwrap(settledFrame(of: any["folded.trackColumn"], "track column"))
        XCTAssertLessThanOrEqual(track.maxX, foldMin + 1, "the art column ends before the fold")
        XCTAssertGreaterThanOrEqual(title.minX, foldMax - 1, "the title starts after the fold")
        XCTAssertTrue(any["duo.upNext"].exists, "Up next in the trailing half")
        XCTAssertGreaterThanOrEqual(any["duo.upNext"].frame.minX, foldMax - 1)
        // Nothing interactive on the fold.
        assertNothingInteractiveOnTheFold(app, box: box, foldMin: foldMin, foldMax: foldMax, top: track.minY)
        save(app, "rail-d-duo-open-landscape-spread",
             container: app.descendants(matching: .any)["capture.railDContainer"])
    }

    @MainActor
    func testOpenLandscapeCentred() throws {
        let app = try launch("railDLandscapeCentred", container: Self.landscape, orientation: .landscapeLeft)
        let box = try settledContainer(app, size: Self.landscape)
        let any = app.descendants(matching: .any)
        let rail = try assertRail(app, id: "folded.systemBar", hasCollapse: true)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail))
        assertNoHorizontalBar(app)
        // Build 54 (4), -Nova: the open Duo (a hinge is reported) is the L1 spread even flat. L2
        // centred the art and title across the fold and pushed Up next past the bottom edge.
        let track = try XCTUnwrap(settledFrame(of: any["folded.trackColumn"], "track column"))
        XCTAssertLessThanOrEqual(track.maxX, box.minX + Self.foldMinX + 1, "the art column ends before the fold")
        let chip = any["dj.ready"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "DJ chip missing\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(chip.frame.minX, box.minX + Self.foldMaxX - 1, "the chip sits after the fold")
        XCTAssertGreaterThanOrEqual(any["duo.upNext"].frame.minX, box.minX + Self.foldMaxX - 1)
        save(app, "rail-d-duo-open-landscape-centred",
             container: app.descendants(matching: .any)["capture.railDContainer"])
    }

    // MARK: Build 54: regular width at the device window, accessibility text

    /// The open Duo's measured window (951 × 669 pt, @3x shots) at the regular width class, as
    /// the device reports it, flat (no fold): the rail player, never the Studio.
    @MainActor
    func testDeviceWindowRegularPlayer() throws {
        try assertDeviceWindowPlayer("railDLandscapeCentred", shot: "rail-d-duo-open-regular-951x669")
    }

    /// The same window with the hinge and a centred fold band forced (book pose).
    @MainActor
    func testDeviceWindowRegularPlayerFold() throws {
        try assertDeviceWindowPlayer("railDLandscapeSpread", shot: "rail-d-duo-open-regular-951x669-fold")
    }

    /// Accessibility text at 820 × 640, regular: still the rail player (`layout.compact` with
    /// the rail), not `layout.studioStacked`, as compact already was.
    @MainActor
    func testOpenLandscapeRegularAccessibilityTextKeepsTheRail() throws {
        let app = try launch("railDLandscapeCentred", container: Self.landscape, orientation: .landscapeLeft,
                             extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
                                     "-AeroDJForcePhoneIdiom", "YES"])
        let box = try settledContainer(app, size: Self.landscape)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(any["layout.studioStacked"].exists, "no stacked Studio on the open Duo at AX sizes")
        XCTAssertFalse(any["layout.studio"].exists)
        // The rail player's route (`DisplayContinuity` .duoHorizontal is `layout.compact`); Play stays reachable.
        let play = app.buttons["transport.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Play/Pause\n\(app.debugDescription)")
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(play.frame), "Play/Pause stays in the window")
        save(app, "rail-d-duo-open-landscape-regular-ax",
             container: app.descendants(matching: .any)["capture.railDContainer"])
    }

    @MainActor
    private func assertDeviceWindowPlayer(_ scenario: String, shot: String) throws {
        let size = CGSize(width: 951, height: 669)
        let app = try launch(scenario, container: size, orientation: .landscapeLeft,
                             extra: ["-AeroDJRailDDeviceWindow", "YES", "-AeroDJForcePhoneIdiom", "YES"])
        let box = try settledContainer(app, size: size)
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["layout.compact"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(any["layout.studio"].exists, "no two-zone Studio")
        XCTAssertFalse(any["layout.studioStacked"].exists)
        let rail = any["folded.systemBar"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5), "the rail\n\(app.debugDescription)")
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail.frame), "rail \(rail.frame) in \(box)")
        XCTAssertGreaterThan(rail.frame.minX, box.midX, "the rail is on the trailing page")
        // Build 54 follow-up: 8 pt from the window's trailing edge, as on Stations.
        assertRailEdgeInset(rail.frame, trailingEdge: box.maxX)
        // The now-playing thumbnail in the top slot, still Collapse (the chevron's action).
        let thumb = app.buttons["folded.collapse"]
        XCTAssertTrue(thumb.exists, "thumbnail missing\n\(app.debugDescription)")
        assertAtLeastPoints(thumb.frame.width, 44, "thumbnail \(thumb.frame)")
        assertAtLeastPoints(thumb.frame.height, 44, "thumbnail \(thumb.frame)")
        XCTAssertLessThanOrEqual(thumb.frame.minY, rail.frame.minY + 12, "the thumbnail is the top slot")
        XCTAssertEqual(thumb.label, "Collapse")
        XCTAssertTrue((thumb.value as? String)?.hasPrefix("Now playing") ?? false,
                      "thumbnail value \(String(describing: thumb.value))")
        let play = app.buttons["transport.playPause"]
        XCTAssertTrue(play.exists)
        assertAtLeastPoints(play.frame.height, 44)
        assertAtLeastPoints(play.frame.width, 44)
        // Build 54 (4): Up next on the second page, opposite the art, wholly inside the window
        // (never clipped at the bottom edge), leading of the rail, under the DJ-break pill.
        let track = try XCTUnwrap(settledFrame(of: any["folded.trackColumn"], "track column"))
        let upNext = any["duo.upNext"]
        XCTAssertTrue(upNext.waitForExistence(timeout: 5), "Up next missing\n\(app.debugDescription)")
        let next = try XCTUnwrap(settledFrame(of: upNext, "Up next"))
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(next), "Up next \(next) is not fully inside \(box)")
        XCTAssertGreaterThanOrEqual(next.minX, track.maxX - 1, "Up next \(next) is opposite the art \(track)")
        XCTAssertGreaterThanOrEqual(next.minX, box.midX, "Up next \(next) is on the second page")
        XCTAssertLessThanOrEqual(next.maxX, rail.frame.minX + 1, "Up next \(next) runs under the rail")
        assertAtLeastPoints(next.height, 44)
        let pill = any["dj.ready"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the DJ-break pill is gone\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(next.minY, pill.frame.maxY - 1, "Up next sits under the DJ-break pill")
        XCTAssertGreaterThanOrEqual(pill.frame.minX, box.midX, "the pill is on the second page")
        // Build 54 (5): the title, chip and Up next share one leading edge; the star sits right
        // after the title block (8 pt in the layout; asserted within 24 pt), top-aligned with it.
        let title = try assertChipLinesUpWithTitle(app)
        // XCUI reports Up next's frame at its text, which sits the card's 12 pt horizontal
        // padding (DuoUpNextList) inside the glass; the card's edge is what lines up with the title.
        let upNextCardInset: CGFloat = 12
        XCTAssertEqual(next.minX - upNextCardInset, title.minX, accuracy: 1,
                       "Up next's card (text \(next) less \(upNextCardInset) pt) lines up with the title \(title)")
        // Build 56 (951 × 669 shots, -Nova): the right column stops at least 16 pt
        // (`RailDLayout.openSpreadRailGutter`) short of the rail glass; it ran into it (≈ 2 pt).
        // The glass is 56 pt, 8 pt in from the window edge (asserted above); `folded.systemBar` is
        // `.contain`, so its own frame is its children's union, not the glass.
        try assertRightColumnClearsTheRail(app, upNextText: next, cardInset: upNextCardInset,
                                           railGlassMinX: box.maxX - Self.railEdgeInset - Self.railGlassWidth)
        let star = app.buttons["nowPlaying.rating"]
        XCTAssertTrue(star.waitForExistence(timeout: 5), "the star is missing\n\(app.debugDescription)")
        let gap = star.frame.minX - title.maxX
        XCTAssertGreaterThanOrEqual(gap, -1, "the star \(star.frame) overlaps the title \(title)")
        XCTAssertLessThanOrEqual(gap, 24, "the star \(star.frame) is not beside the title \(title)")
        XCTAssertLessThan(star.frame.minY, title.maxY, "the star is level with the title block")
        assertAtLeastPoints(star.frame.width, 44)
        assertAtLeastPoints(star.frame.height, 44)
        XCTAssertLessThanOrEqual(star.frame.maxX, rail.frame.minX + 1)
        save(app, shot, container: app.descendants(matching: .any)["capture.railDContainer"])
    }

    /// The open Duo's L1 trailing page against the rail: the Up next card (XCUI reports it at its
    /// text, `cardInset` inside the glass card, `DuoUpNextList .padding(.horizontal, 12)`) and the
    /// station chips row ending in Tune both end at least `minimumGap` before the rail glass.
    @MainActor
    private func assertRightColumnClearsTheRail(_ app: XCUIApplication, upNextText: CGRect, cardInset: CGFloat,
                                                railGlassMinX: CGFloat, minimumGap: CGFloat = 16,
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        let cardMaxX = upNextText.maxX + cardInset
        XCTAssertGreaterThanOrEqual(railGlassMinX - cardMaxX, minimumGap - 0.5,
                                    "Up next's card ends at \(cardMaxX) (text \(upNextText) plus \(cardInset) pt), "
                                        + "the rail glass starts at \(railGlassMinX)", file: file, line: line)
        // Typed and `.firstMatch`: one button, one dial, never an ambiguous match.
        let tune = app.buttons.matching(identifier: "duo.stationTune").firstMatch
        XCTAssertTrue(tune.waitForExistence(timeout: 5), "Tune missing\n\(app.debugDescription)", file: file, line: line)
        let tuneFrame = try XCTUnwrap(settledFrame(of: tune, "Tune"), file: file, line: line)
        assertAtLeastPoints(tuneFrame.width, 44, "Tune \(tuneFrame)", file: file, line: line)
        assertAtLeastPoints(tuneFrame.height, 44, "Tune \(tuneFrame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(railGlassMinX - tuneFrame.maxX, minimumGap - 0.5,
                                    "Tune \(tuneFrame) ends within \(minimumGap) pt of the rail glass at \(railGlassMinX)",
                                    file: file, line: line)
        let dial = app.descendants(matching: .any).matching(identifier: "duo.stationDial").firstMatch
        XCTAssertTrue(dial.exists, "the station chips row\n\(app.debugDescription)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(railGlassMinX - dial.frame.maxX, minimumGap - 0.5,
                                    "the chips row \(dial.frame) ends within \(minimumGap) pt of the rail glass at \(railGlassMinX)",
                                    file: file, line: line)
    }

    @MainActor
    func testOpenLandscapeWithTheSidebar() throws {
        let app = try launch("railDLandscapeSidebar", container: Self.landscape, orientation: .landscapeLeft)
        let box = try settledContainer(app, size: Self.landscape)
        try assertSidebarRailColumn(app, box: box)
        save(app, "rail-d-duo-open-landscape-sidebar",
             container: app.descendants(matching: .any)["capture.railDContainer"])
    }

    /// #548, owner's Nov 17 9:53 AM call: the open Duo in book pose with the rail collapsed
    /// keeps Rail D. The column moves to the leading side of the fold with the closed screen's
    /// rail (`folded.closedRail`) beside it; the song position is the rail's vertical bar and the
    /// column has no progress bar. Same frame as the spread (820 x 640, fold 396…424), then
    /// Collapse. Show rail brings the full rail back. -Nova
    @MainActor
    func testOpenLandscapeBookPoseCollapsed() throws {
        let app = try launch("railDLandscapeSpread", container: Self.landscape, orientation: .landscapeLeft)
        let box = try settledContainer(app, size: Self.landscape)
        let any = app.descendants(matching: .any)
        let collapse = app.buttons["folded.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10), "Collapse missing\n\(app.debugDescription)")
        collapse.tap()
        XCTAssertTrue(any["folded.bookColumn"].waitForExistence(timeout: 10),
                      "the collapsed book pose is not the book column\n\(app.debugDescription)")
        XCTAssertFalse(any["folded.systemBar"].exists, "the full rail is still up")
        let rail = try assertRail(app, id: "folded.closedRail", hasCollapse: false)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail))
        assertNoHorizontalBar(app)
        let column = try XCTUnwrap(settledFrame(of: any["folded.bookColumn.column"], "book column"))
        let bar = any["playback.progress"].frame
        XCTAssertGreaterThanOrEqual(bar.minX, column.maxX - 1, "the song-position bar \(bar) is in the column \(column)")
        XCTAssertGreaterThanOrEqual(rail.minX, column.maxX - 1, "the rail is trailing of the column")
        let foldMin = box.minX + Self.foldMinX
        let foldMax = box.minX + Self.foldMaxX
        XCTAssertLessThanOrEqual(column.maxX, foldMin + 1, "the column ends before the fold")
        XCTAssertLessThanOrEqual(rail.maxX, foldMin + 1, "the rail ends before the fold")
        let expand = app.buttons["folded.expandRail"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "Show rail missing\n\(app.debugDescription)")
        XCTAssertTrue(expand.isHittable)
        assertAtLeastPoints(expand.frame.width, 44)
        assertAtLeastPoints(expand.frame.height, 44)
        // Nothing interactive on the fold.
        assertNothingInteractiveOnTheFold(app, box: box, foldMin: foldMin, foldMax: foldMax)
        save(app, "rail-d-duo-open-landscape-book-collapsed",
             container: app.descendants(matching: .any)["capture.railDContainer"])
        // Show rail: back to the L1 spread with the full rail.
        expand.tap()
        XCTAssertTrue(any["folded.systemBar"].waitForExistence(timeout: 10), "Show rail did not bring the rail back")
        XCTAssertFalse(any["folded.bookColumn"].exists)
    }

    // MARK: DJ states (Echo, #558): debug-only extra shots, not required in ios.yml

    @MainActor
    func testOpenLandscapeSpreadOnAir() throws {
        try assertDJState("railDLandscapeSpreadOnAir", layout: .spread, onAir: true,
                          shot: "rail-d-duo-open-landscape-spread-onair")
    }

    @MainActor
    func testOpenLandscapeCentredOnAir() throws {
        try assertDJState("railDLandscapeCentredOnAir", layout: .centred, onAir: true,
                          shot: "rail-d-duo-open-landscape-centred-onair")
    }

    @MainActor
    func testOpenLandscapeSidebarOnAir() throws {
        try assertDJState("railDLandscapeSidebarOnAir", layout: .sidebar, onAir: true,
                          shot: "rail-d-duo-open-landscape-sidebar-onair")
    }

    @MainActor
    func testOpenLandscapeSpreadVoiceUnavailable() throws {
        try assertDJState("railDLandscapeSpreadVoiceUnavailable", layout: .spread, onAir: false,
                          shot: "rail-d-duo-open-landscape-spread-voice-unavailable")
    }

    @MainActor
    func testOpenLandscapeCentredVoiceUnavailable() throws {
        try assertDJState("railDLandscapeCentredVoiceUnavailable", layout: .centred, onAir: false,
                          shot: "rail-d-duo-open-landscape-centred-voice-unavailable")
    }

    @MainActor
    func testOpenLandscapeSidebarVoiceUnavailable() throws {
        try assertDJState("railDLandscapeSidebarVoiceUnavailable", layout: .sidebar, onAir: false,
                          shot: "rail-d-duo-open-landscape-sidebar-voice-unavailable")
    }

    private enum LandscapeLayout { case spread, centred, sidebar }

    /// The rail, no horizontal bar, and the DJ state (the On Air pill, or the "DJ voice
    /// unavailable" caption) inside the frame, leading of the rail and off the fold.
    @MainActor
    private func assertDJState(_ scenario: String, layout: LandscapeLayout, onAir: Bool, shot: String) throws {
        let app = try launch(scenario, container: Self.landscape, orientation: .landscapeLeft)
        let box = try settledContainer(app, size: Self.landscape)
        let any = app.descendants(matching: .any)
        if layout == .sidebar {
            XCTAssertTrue(any["split.sidebar"].waitForExistence(timeout: 10), "the Stations sidebar is not open\n\(app.debugDescription)")
            XCTAssertTrue(any["folded.railColumn"].waitForExistence(timeout: 10),
                          "the sidebar-open detail is not the rail column\n\(app.debugDescription)")
        }
        let rail = try assertRail(app, id: "folded.systemBar", hasCollapse: true)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail))
        assertNoHorizontalBar(app)
        let state = onAir
            ? any["dj.onAir"]
            : any.matching(NSPredicate(format: "label CONTAINS[c] %@", "DJ voice unavailable")).firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10),
                      "\(onAir ? "On Air" : "voice unavailable") missing\n\(app.debugDescription)")
        let frame = try XCTUnwrap(settledFrame(of: state, "DJ state"))
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(frame), "DJ state \(frame) left the container \(box)")
        XCTAssertLessThanOrEqual(frame.maxX, rail.minX + 1, "DJ state \(frame) runs under the rail \(rail)")
        if layout != .sidebar {
            let foldMin = box.minX + Self.foldMinX
            let foldMax = box.minX + Self.foldMaxX
            XCTAssertFalse(frame.minX < foldMax && frame.maxX > foldMin, "DJ state \(frame) sits on the fold")
            // #434: the open Duo's landscape is the L1 spread (#577); the art hides on air.
            if onAir { assertOrbOnlyArtCard(app) }
        }
        save(app, shot,
             container: app.descendants(matching: .any)["capture.railDContainer"])
    }

    // MARK: Checks

    /// #434: the art card shows only the orb (the on-air captures expose its layer id) and the
    /// content column draws no second orb.
    @MainActor
    private func assertOrbOnlyArtCard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["folded.artCard.orb"].waitForExistence(timeout: 5),
                      "the art card shows the orb while on air\n\(app.debugDescription)", file: file, line: line)
        XCTAssertFalse(any["folded.artCard.artwork"].exists, "the art is hidden while on air", file: file, line: line)
        XCTAssertFalse(any["folded.visualizer"].exists, "one orb: no content-column orb", file: file, line: line)
    }

    /// Echo (#558): the closed rail keeps the DJ chip in the content column, lined up with the
    /// title, one line, leading of the rail.
    @MainActor
    private func assertClosedChip(_ app: XCUIApplication, rail: CGRect,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        try assertChipLinesUpWithTitle(app, file: file, line: line)
        let chip = try XCTUnwrap(settledFrame(of: app.descendants(matching: .any)["dj.ready"], "chip"), file: file, line: line)
        XCTAssertLessThanOrEqual(chip.maxX, rail.minX + 1, "the chip \(chip) runs under the rail \(rail)", file: file, line: line)
        XCTAssertLessThan(chip.height, 44, "the DJ chip wrapped: \(chip)", file: file, line: line)
    }

    /// Every rail control hittable, at least 44 × 44 and inside the rail; the vertical bar in
    /// the rail, under Sleep and above the live dot, taller than wide.
    @MainActor
    @discardableResult
    private func assertRail(_ app: XCUIApplication, id: String, hasCollapse: Bool,
                            file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let any = app.descendants(matching: .any)
        let railElement = any[id]
        XCTAssertTrue(railElement.waitForExistence(timeout: 10), "\(id) missing\n\(app.debugDescription)", file: file, line: line)
        let rail = try XCTUnwrap(settledFrame(of: railElement, id), file: file, line: line)
        XCTAssertLessThanOrEqual(rail.width, 64, "the rail is 56 pt: \(rail)", file: file, line: line)
        var controls: [(String, XCUIElement)] = [("more", any["folded.more"]),
                                                 ("play", app.buttons["transport.playPause"]),
                                                 ("skip", app.buttons["transport.skip"]),
                                                 ("queue", app.buttons["queue.affordance"]),
                                                 ("sleep", app.buttons["folded.sleepTimer"])]
        if hasCollapse { controls.insert(("collapse", app.buttons["folded.collapse"]), at: 0) }
        for (name, element) in controls {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(name) missing\n\(app.debugDescription)", file: file, line: line)
            let frame = element.frame
            let detail = "\(name) \(frame) rail \(rail)"
            XCTAssertTrue(element.isHittable, "\(detail) is not hittable", file: file, line: line)
            assertAtLeastPoints(frame.width, 44, detail, file: file, line: line)
            assertAtLeastPoints(frame.height, 44, detail, file: file, line: line)
            XCTAssertTrue(rail.insetBy(dx: -4, dy: -4).contains(CGPoint(x: frame.midX, y: frame.midY)),
                          "\(detail) left the rail", file: file, line: line)
        }
        let dot = any["folded.liveDot"]
        XCTAssertTrue(dot.waitForExistence(timeout: 5), "live dot missing", file: file, line: line)
        let bar = any["playback.progress"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the vertical bar is missing\n\(app.debugDescription)", file: file, line: line)
        XCTAssertTrue(any["folded.railScrubber"].exists, "the rail scrubber container", file: file, line: line)
        let barFrame = bar.frame
        let detail = "bar \(barFrame) rail \(rail) sleep \(app.buttons["folded.sleepTimer"].frame) dot \(dot.frame)"
        XCTAssertGreaterThan(barFrame.height, barFrame.width, "the bar is vertical: \(detail)", file: file, line: line)
        assertAtLeastPoints(barFrame.width, 44, "the bar is a 44 pt target: \(detail)", file: file, line: line)
        assertAtLeastPoints(barFrame.height, 44 + 36, "a 44 pt track plus the times: \(detail)", file: file, line: line)
        XCTAssertTrue(rail.insetBy(dx: -4, dy: -4).contains(barFrame), "the bar is in the rail: \(detail)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(barFrame.minY, app.buttons["folded.sleepTimer"].frame.maxY - 1, detail, file: file, line: line)
        XCTAssertLessThanOrEqual(barFrame.maxY, dot.frame.minY + 1, detail, file: file, line: line)
        XCTAssertTrue(bar.isHittable, "the bar is not hittable: \(detail)", file: file, line: line)
        XCTAssertEqual(bar.label, "Song position", file: file, line: line)
        return rail
    }

    /// The rail's 8 pt trailing inset, read from its centre. `folded.closedRail` is an
    /// `.accessibilityElement(children: .contain)`, so its frame is the union of its children
    /// (the 52 pt scrubber, the 44 pt plates), not the 56 pt glass: 2 pt in on each side, which
    /// made a maxX check read 10 pt on a rail drawn at 8. The centre is the same for both. -Nova
    @MainActor
    private func assertRailEdgeInset(_ rail: CGRect, trailingEdge: CGFloat,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let expectedMidX = trailingEdge - Self.railEdgeInset - Self.railGlassWidth / 2
        XCTAssertEqual(rail.midX, expectedMidX, accuracy: 1.5,
                       "the 56 pt rail sits 8 pt in from the trailing edge: rail \(rail), edge \(trailingEdge)",
                       file: file, line: line)
        XCTAssertLessThanOrEqual(rail.width, Self.railGlassWidth + 1, "rail \(rail) is wider than the glass",
                                 file: file, line: line)
    }

    /// Nothing interactive on the fold: every existing, non-empty, hittable button (and the
    /// song-position bar) inside the container stays off `foldMin…foldMax`, and more than five
    /// controls were checked. With `top`, controls above it (the header row) are skipped.
    @MainActor
    private func assertNothingInteractiveOnTheFold(_ app: XCUIApplication, box: CGRect,
                                                   foldMin: CGFloat, foldMax: CGFloat, top: CGFloat? = nil,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let any = app.descendants(matching: .any)
        var checked = 0
        for element in app.buttons.allElementsBoundByIndex + [any["playback.progress"]] where element.exists {
            let frame = element.frame
            guard !frame.isEmpty, top.map({ frame.minY >= $0 - 1 }) ?? true,
                  box.intersects(frame), element.isHittable else { continue }
            checked += 1
            XCTAssertFalse(frame.minX < foldMax && frame.maxX > foldMin,
                           "\(element.identifier) \(element.label) \(frame) sits on the fold \(foldMin)…\(foldMax)",
                           file: file, line: line)
        }
        XCTAssertGreaterThan(checked, 5, "the fold check saw too few controls", file: file, line: line)
    }

    /// No horizontal progress bar anywhere: only the rail's bar carries `playback.progress`,
    /// and the horizontal scrubber's container (`playback.scrubber`) is gone.
    @MainActor
    private func assertNoHorizontalBar(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let any = app.descendants(matching: .any)
        XCTAssertFalse(any["playback.scrubber"].exists, "the horizontal scrubber is back", file: file, line: line)
        let bars = any.matching(NSPredicate(format: "identifier == %@", "playback.progress")).allElementsBoundByIndex
        XCTAssertEqual(bars.count, 1, "one song-position bar", file: file, line: line)
        for bar in bars {
            XCTAssertGreaterThan(bar.frame.height, bar.frame.width, "a horizontal bar: \(bar.frame)", file: file, line: line)
        }
    }

    /// The DJ chip's leading edge is the title's (the mock's centred chip was the bug).
    @MainActor
    @discardableResult
    private func assertChipLinesUpWithTitle(_ app: XCUIApplication,
                                            file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let any = app.descendants(matching: .any)
        let title = any["folded.titleBlock"]
        let chip = any["dj.ready"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "title missing\n\(app.debugDescription)", file: file, line: line)
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "DJ chip missing\n\(app.debugDescription)", file: file, line: line)
        let titleFrame = try XCTUnwrap(settledFrame(of: title, "title"), file: file, line: line)
        let chipFrame = try XCTUnwrap(settledFrame(of: chip, "chip"), file: file, line: line)
        XCTAssertEqual(chipFrame.minX, titleFrame.minX, accuracy: 0.5,
                       "chip \(chipFrame) is not left-aligned with the title \(titleFrame)", file: file, line: line)
        XCTAssertGreaterThan(chipFrame.minY, titleFrame.minY, "the chip sits under the title", file: file, line: line)
        return titleFrame
    }

    /// The sidebar stays side by side (no overlay) and the player keeps the full rail, the
    /// Collapse chevron, the left-aligned chip and a one-line chip.
    @MainActor
    private func assertSidebarRailColumn(_ app: XCUIApplication, box: CGRect) throws {
        let any = app.descendants(matching: .any)
        let sidebar = any["split.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the Stations sidebar is not open\n\(app.debugDescription)")
        XCTAssertTrue(any["folded.railColumn"].waitForExistence(timeout: 10),
                      "the sidebar-open detail is not the rail column\n\(app.debugDescription)")
        let rail = try assertRail(app, id: "folded.systemBar", hasCollapse: true)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(rail))
        assertNoHorizontalBar(app)
        let sidebarFrame = try XCTUnwrap(settledFrame(of: sidebar, "sidebar"))
        let column = try XCTUnwrap(settledFrame(of: any["folded.railColumn"], "rail column"))
        XCTAssertGreaterThanOrEqual(column.minX, sidebarFrame.maxX - 1, "side by side, not an overlay")
        XCTAssertGreaterThanOrEqual(rail.minX, column.maxX - 1)
        XCTAssertTrue(app.buttons["folded.collapse"].isHittable, "the chevron stays")
        try assertChipLinesUpWithTitle(app)
        let chip = any["dj.ready"].frame
        XCTAssertLessThan(chip.height, 44, "the DJ chip wrapped: \(chip)")
        XCTAssertLessThanOrEqual(chip.maxX, column.maxX + 1, "the chip stays in the column")
    }

    // MARK: Launch

    @MainActor
    private func launch(_ scenario: String, container: CGSize?, orientation: UIDeviceOrientation,
                        extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeroDJTestStation", "YES", "-AeroDJStudioCapture", "YES",
                               "-AeroDJStudioCaptureScenario", scenario] + extra
        XCUIDevice.shared.orientation = orientation
        // railDPhone uses the plain PlayingScreen path and never sets capture.railDContainer.
        // transport.playPause is on every RailD frame (closed rail and open rail).
        app.launchUntilAccessible(readyIdentifiers: ["transport.playPause", "capture.failed"], in: self)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window\n\(app.debugDescription)")
        if let container {
            try XCTSkipUnless(window.frame.width >= container.width && window.frame.height >= container.height,
                              "window \(window.frame.size) is smaller than the \(container) container")
        }
        let loading = app.descendants(matching: .any)["capture.loading"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 20), .completed, "capture still loading\n\(app.debugDescription)")
        let failed = app.descendants(matching: .any)["capture.failed"]
        if failed.exists { XCTFail(failed.label) }
        // A spinner in the shot means it was taken mid-load.
        let spinners = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.activityIndicators)
        _ = XCTWaiter().wait(for: [spinners], timeout: 10)
        return app
    }

    /// The container's frame once it has its final size, polled, never a fixed sleep.
    ///
    /// Read inside the window: `capture.railDContainer` is a `.contain` element, so its frame
    /// is the union of its children, which the clip shape does not clip. When the frame is the
    /// whole window (closed Duo, 390 x 844, on an iPhone 16e), the container is centred in the
    /// safe area, not the window, and a child reaches the window's top, so the raw frame read
    /// (0, 0, 390, 850.67) and never matched. What the shot shows is the part in the window. -Nova
    @MainActor
    private func settledContainer(_ app: XCUIApplication, size: CGSize) throws -> CGRect {
        let container = app.descendants(matching: .any)["capture.railDContainer"]
        XCTAssertTrue(container.waitForExistence(timeout: 10), "container missing\n\(app.debugDescription)")
        let window = app.windows.firstMatch.frame
        return try XCTUnwrap(settledFrame(of: container, "container", clippedTo: window) {
            abs($0.width - size.width) <= 1 && abs($0.height - size.height) <= 1
        }, "container never settled at \(size) in window \(window): \(container.frame)")
    }

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

    /// `container` set (the open-landscape frames only): the shot is that element's own
    /// capture, the 820 × 640 frame upright and whole, not the screen around it. Nil (the
    /// iPhone, closed Duo, and open-portrait frames) keeps the app screenshot, so those PNGs
    /// do not change.
    @MainActor
    private func save(_ app: XCUIApplication, _ name: String, container: XCUIElement? = nil) {
        let shot = container.map { $0.screenshot() } ?? app.screenshot()
        let png: Data
        let attachment: XCTAttachment
        // An element screenshot after `XCUIDevice.shared.orientation = .landscapeLeft` can
        // still arrive taller than wide, or with a non-`.up` imageOrientation, because the
        // hosted iPad sim keeps a portrait-origin framebuffer. The a903baba
        // studio-screenshots were 2360 × 1640, status bar vertical on the right, and the
        // 820 × 640 container cut off at the bottom. Normalise those so the PNG is the
        // upright, wider-than-tall frame. Portrait and closed shots never enter this path.
        if container != nil, XCUIDevice.shared.orientation.isLandscape {
            let image = uprightOpenLandscapeImage(shot.image)
            png = image.pngData() ?? shot.pngRepresentation
            attachment = XCTAttachment(image: image)
        } else {
            png = shot.pngRepresentation
            attachment = XCTAttachment(screenshot: shot)
        }
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["STUDIO_SCREENSHOT_DIR"], !dir.isEmpty {
            let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)_\(device).png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: url)
        }
    }

    /// Bake a non-`.up` orientation into the pixels. If the bitmap is still taller than wide
    /// (the landscape frame captured from a portrait framebuffer), rotate 90° counterclockwise:
    /// that puts the right-edge status bar on top and yields the 820 × 640 frame.
    private func uprightOpenLandscapeImage(_ image: UIImage) -> UIImage {
        let baked = image.imageOrientation == .up ? image : drawnUpright(image)
        guard baked.size.height > baked.size.width else { return baked }
        return rotated90Counterclockwise(baked)
    }

    private func drawnUpright(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let size = image.size
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func rotated90Counterclockwise(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.rotate(by: -.pi / 2)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
