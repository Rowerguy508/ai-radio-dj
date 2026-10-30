import XCTest
@testable import AeroDJCore

/// The station split's one source of truth (`StationSplitNavigation`). Each device case from
/// Fry's #280 review and Orion's list has its own regression test: the open station must stay
/// visible across a width-class change in both directions, and nothing resets.
final class StationSplitNavigationTests: XCTestCase {
    typealias Nav = StationSplitNavigation<String>
    private let morningCalm = "morning-calm"
    private let lateNight = "late-night"
    private var stations: [String] { [morningCalm, lateNight] }

    /// Launch the way `StationSplitRoot` does. SwiftUI may run the width-class `onChange`
    /// (initial) and the restore `.task` in either order, so both orders are checked.
    private func launched(regular: Bool, restoring id: String?, restoreFirst: Bool) -> Nav {
        var nav = Nav()
        if restoreFirst {
            nav.restore(id, available: stations)
            nav.setRegularWidth(regular)
        } else {
            nav.setRegularWidth(regular)
            nav.restore(id, available: stations)
        }
        return nav
    }

    private func assertOpen(_ nav: Nav, _ id: String, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(nav.selectedID, id, message, file: file, line: line)
        XCTAssertTrue(nav.isStationVisible, message, file: file, line: line)
        XCTAssertEqual(nav.compactColumn, .detail, message, file: file, line: line)
    }

    // MARK: (a) Open Duo, phone idiom

    func testOpenDuoRestoreThenFoldKeepsStation() {
        for restoreFirst in [true, false] {
            var nav = launched(regular: true, restoring: morningCalm, restoreFirst: restoreFirst)
            assertOpen(nav, morningCalm, "open Duo shows the restored station")
            nav.setRegularWidth(false) // fold
            XCTAssertFalse(nav.showsBothColumns)
            assertOpen(nav, morningCalm, "folding the Duo keeps the restored station (restoreFirst \(restoreFirst))")
        }
    }

    // MARK: (c) reverse of (a): closed Duo, then unfold

    func testClosedDuoRestoreThenUnfoldKeepsStation() {
        for restoreFirst in [true, false] {
            var nav = launched(regular: false, restoring: morningCalm, restoreFirst: restoreFirst)
            assertOpen(nav, morningCalm, "closed Duo shows the restored station")
            nav.setRegularWidth(true) // unfold
            XCTAssertTrue(nav.showsBothColumns)
            assertOpen(nav, morningCalm, "unfolding keeps the restored station (restoreFirst \(restoreFirst))")
            nav.setRegularWidth(false) // and fold again
            assertOpen(nav, morningCalm, "fold after unfold keeps it")
        }
    }

    // MARK: (b) Max phone in landscape, then portrait

    func testMaxLandscapeRestoreThenPortraitKeepsStation() {
        for restoreFirst in [true, false] {
            var nav = launched(regular: true, restoring: lateNight, restoreFirst: restoreFirst)
            nav.setRegularWidth(false) // rotate to portrait
            assertOpen(nav, lateNight, "portrait keeps the station restored in landscape (restoreFirst \(restoreFirst))")
        }
    }

    // MARK: (c) reverse of (b): Max phone in portrait, then landscape

    func testMaxPortraitRestoreThenLandscapeKeepsStation() {
        for restoreFirst in [true, false] {
            var nav = launched(regular: false, restoring: lateNight, restoreFirst: restoreFirst)
            nav.setRegularWidth(true) // rotate to landscape
            assertOpen(nav, lateNight, "landscape keeps the station restored in portrait")
            nav.setRegularWidth(false) // and back to portrait
            assertOpen(nav, lateNight, "portrait again keeps it")
        }
    }

    // MARK: iPad Split View and Slide Over

    func testIPadFullWidthRestoreThenSplitViewKeepsStation() {
        var nav = launched(regular: true, restoring: morningCalm, restoreFirst: true)
        nav.setRegularWidth(false) // narrow Split View or Slide Over
        assertOpen(nav, morningCalm, "entering Split View keeps the station")
        nav.setRegularWidth(true) // back to full screen
        assertOpen(nav, morningCalm, "leaving Split View keeps the station")
    }

    func testIPadSplitViewRestoreThenFullWidthKeepsStation() {
        var nav = launched(regular: false, restoring: morningCalm, restoreFirst: false)
        nav.setRegularWidth(true)
        assertOpen(nav, morningCalm, "going full screen keeps the station")
        nav.setRegularWidth(false)
        assertOpen(nav, morningCalm, "returning to Split View keeps the station")
    }

    /// The split may write `.sidebar` while both columns show (and during the collapse,
    /// before the new width class reaches the view). Regular-width writes are ignored.
    func testRegularWidthColumnWritesDoNotDecideTheCollapse() {
        var nav = launched(regular: true, restoring: morningCalm, restoreFirst: true)
        nav.compactColumnWritten(.list)
        nav.setRegularWidth(false)
        assertOpen(nav, morningCalm, "a regular-width .sidebar write must not send the fold to the carousel")
    }

    // MARK: Tapped (not restored) stations

    func testTappedStationInRegularSurvivesCollapse() {
        var nav = Nav(isRegularWidth: true)
        nav.select(lateNight)
        nav.setRegularWidth(false)
        assertOpen(nav, lateNight, "a station opened in regular width stays open in compact")
    }

    func testTappedStationInCompactSurvivesExpand() {
        var nav = Nav(isRegularWidth: false)
        nav.select(lateNight)
        nav.setRegularWidth(true)
        assertOpen(nav, lateNight, "a station opened in compact width stays open in regular")
    }

    // MARK: No selection

    func testNoSelectionShowsListInBothDirections() {
        var nav = launched(regular: true, restoring: nil, restoreFirst: true)
        XCTAssertNil(nav.selectedID)
        XCTAssertFalse(nav.isStationVisible)
        nav.setRegularWidth(false)
        XCTAssertEqual(nav.compactColumn, .list, "nothing selected: the fold shows the carousel")
        XCTAssertFalse(nav.isStationVisible)
        nav.setRegularWidth(true)
        XCTAssertNil(nav.selectedID)
        XCTAssertEqual(nav.compactColumn, .list)
        nav.compactColumnWritten(.detail)
        XCTAssertEqual(nav.compactColumn, .list)
        nav.setRegularWidth(false)
        nav.compactColumnWritten(.detail)
        XCTAssertEqual(nav.compactColumn, .list, "a detail push with nothing selected still shows the list")
    }

    // MARK: Back gesture

    func testCompactBackGestureShowsListAndKeepsSelection() {
        var nav = launched(regular: false, restoring: morningCalm, restoreFirst: true)
        nav.compactColumnWritten(.list) // back
        XCTAssertEqual(nav.compactColumn, .list, "back shows the carousel")
        XCTAssertEqual(nav.selectedID, morningCalm, "back keeps the selection (and playback)")
        XCTAssertFalse(nav.isStationVisible)
        nav.compactColumnWritten(.detail)
        XCTAssertEqual(nav.compactColumn, .detail, "a push returns to the station")
    }

    /// After a compact back, regular width shows the selected station in the detail column,
    /// so the next collapse returns to what was on screen: the station.
    func testBackThenExpandThenCollapseShowsTheStationThatWasVisible() {
        var nav = launched(regular: false, restoring: morningCalm, restoreFirst: true)
        nav.compactColumnWritten(.list)
        nav.setRegularWidth(true)
        XCTAssertTrue(nav.isStationVisible, "regular width shows the selected station")
        nav.setRegularWidth(false)
        assertOpen(nav, morningCalm, "collapse returns to the station that was visible")
    }

    /// Back, then a width change that stays compact (e.g. Slide Over to narrow Split View):
    /// the carousel the listener chose stays.
    func testBackSurvivesACompactToCompactChange() {
        var nav = launched(regular: false, restoring: morningCalm, restoreFirst: true)
        nav.compactColumnWritten(.list)
        nav.setRegularWidth(false)
        XCTAssertEqual(nav.compactColumn, .list)
        XCTAssertEqual(nav.selectedID, morningCalm)
    }

    // MARK: Restore rules

    func testRestoreAppliesOnceAndNeverOverridesATap() {
        var nav = Nav(isRegularWidth: true)
        XCTAssertTrue(nav.restore(morningCalm, available: stations))
        XCTAssertFalse(nav.restore(lateNight, available: stations), "restore applies once")
        XCTAssertEqual(nav.selectedID, morningCalm)

        var tapped = Nav(isRegularWidth: false)
        tapped.select(lateNight)
        XCTAssertFalse(tapped.restore(morningCalm, available: stations), "a tap wins over a late restore")
        XCTAssertEqual(tapped.selectedID, lateNight)
    }

    func testRestoreWaitsForTheStationToExist() {
        var nav = Nav(isRegularWidth: true)
        XCTAssertFalse(nav.restore("created", available: stations), "unknown id is not applied")
        XCTAssertNil(nav.selectedID)
        XCTAssertFalse(nav.didApplyRestore)
        XCTAssertTrue(nav.restore("created", available: stations + ["created"]),
                      "a created station restores once the recipes load")
        nav.setRegularWidth(false)
        assertOpen(nav, "created", "a late restore in regular width survives the fold")
    }

    func testRestoreOfNilDoesNothing() {
        var nav = Nav(isRegularWidth: false)
        XCTAssertFalse(nav.restore(nil, available: stations))
        XCTAssertFalse(nav.didApplyRestore)
        XCTAssertEqual(nav.compactColumn, .list)
    }

    // MARK: No state resets

    func testManyWidthChangesNeverChangeTheSelection() {
        var nav = launched(regular: true, restoring: morningCalm, restoreFirst: true)
        for step in 0..<20 {
            nav.setRegularWidth(step % 3 == 0)
            XCTAssertEqual(nav.selectedID, morningCalm)
            XCTAssertTrue(nav.isStationVisible, "step \(step)")
            XCTAssertTrue(nav.didApplyRestore)
        }
    }

    func testShowsBothColumnsFollowsTheWidthClassOnly() {
        var nav = Nav()
        XCTAssertFalse(nav.showsBothColumns, "unspecified width class is compact")
        nav.setRegularWidth(true)
        XCTAssertTrue(nav.showsBothColumns)
        nav.select(morningCalm)
        nav.setRegularWidth(false)
        XCTAssertFalse(nav.showsBothColumns)
    }
}
