import XCTest
@testable import AeroDJCore

final class FoldedOuterLayoutTests: XCTestCase {

    func testPlayRingFitsInsideTheTransportCapsule() {
        // 68, not the mockup's 64: the reskin is the iPhone player, and #484 fixes Play/Pause at 68.
        XCTAssertEqual(FoldedOuterLayout.playSide, 68)
        XCTAssertEqual(FoldedOuterLayout.playRingWidth, 6)
        XCTAssertEqual(FoldedOuterLayout.playOuterSide, 80)
        XCTAssertLessThanOrEqual(FoldedOuterLayout.playOuterSide, FoldedOuterLayout.transportHeight)
        XCTAssertEqual(FoldedOuterLayout.transportHeight, 80)
        XCTAssertEqual(FoldedOuterLayout.transportRadius, 40)
        XCTAssertEqual(FoldedOuterLayout.skipSide, 52)
    }

    func testMockupGuttersAndRadii() {
        XCTAssertEqual(FoldedOuterLayout.contentInset, 24)
        XCTAssertEqual(FoldedOuterLayout.artInset, 30)
        XCTAssertEqual(FoldedOuterLayout.artRadius, 28)
        XCTAssertEqual(FoldedOuterLayout.playRingOpacity, 0.25, accuracy: 0.0001)
    }

    func testOnAirComesOnlyFromTheStateLabel() {
        XCTAssertEqual(FoldedOuterLayout.status(of: .speaking(includesBriefing: false)),
                       .onAir("On Air"))
        XCTAssertEqual(FoldedOuterLayout.status(of: .speaking(includesBriefing: true)),
                       .onAir("On Air"))
        // The same function, fed only the label, matches. A second flag is not consulted.
        XCTAssertEqual(FoldedOuterLayout.status(onAirLabel: DJStudioState.speaking(includesBriefing: false).onAirLabel),
                       .onAir("On Air"))
    }

    func testIdlePreparingAndReadyAreMicDownNeverOnAir() {
        let quiet: [DJStudioState] = [
            .idle,
            .preparing(includesBriefing: false),
            .preparing(includesBriefing: true),
            .ready(includesBriefing: false, seconds: 24),
            .ready(includesBriefing: true, seconds: 8),
        ]
        for state in quiet {
            XCTAssertEqual(FoldedOuterLayout.status(of: state), .micDown, "\(state)")
            XCTAssertNil(state.onAirLabel, "\(state) must not publish an On Air label")
            XCTAssertFalse(state.isOnAir, "\(state)")
        }
    }

    func testAFailedBreakIsAQuietSkip() {
        let failed: [DJStudioState] = [
            .failed(.voiceFailed),
            .failed(.budgetReached),
            .failed(.consentReviewRequired(pendingCount: 1)),
        ]
        for state in failed {
            XCTAssertEqual(FoldedOuterLayout.status(of: state), .micDown, "\(state)")
            XCTAssertNil(state.onAirLabel, "a failed break must not light On Air")
        }
    }

    func testAnEmptyOrNilLabelIsNeverOnAir() {
        XCTAssertEqual(FoldedOuterLayout.status(onAirLabel: nil), .micDown)
        XCTAssertEqual(FoldedOuterLayout.status(onAirLabel: ""), .micDown)
        XCTAssertEqual(FoldedOuterLayout.status(onAirLabel: "On Air"), .onAir("On Air"))
    }

    /// The reskin ships ungated: no DEBUG flag, launch argument or defaults key is left.
    func testTheReskinHasNoFlag() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = try String(contentsOf: iosRoot.appendingPathComponent(
            "AeroDJCore/Sources/AeroDJCore/Studio/FoldedOuterLayout.swift"), encoding: .utf8)
        for path in ["AeroDJ/FoldedPlayer.swift", "AeroDJ/PlayingScreen.swift"] {
            let source = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("FoldedOuterLayout.isEnabled"), path)
            XCTAssertFalse(source.contains("AeroDJFoldedOuterReskin"), path)
            XCTAssertFalse(source.contains("enableDefaultsKey"), path)
        }
        XCTAssertFalse(helper.contains("isEnabled"))
        XCTAssertFalse(helper.contains("AeroDJFoldedOuterReskin"))
    }

    /// PlayingScreen and FoldedPlayer share one reskin rule; it never depends on height, so
    /// the screen's height (above the nav bar) and the player's (below it) cannot disagree.
    func testReskinRuleMatchesPhoneBottomAtEveryHeight() {
        for width in stride(from: 280.0, through: 1400, by: 10) {
            for height in [0.0, 400, 600, 715, 716, 717, 760, 844, 1180, .infinity] {
                let phone = FoldedColumnLayout.controlPlacement(containerWidth: width,
                                                                containerHeight: height) == .phoneBottom
                XCTAssertEqual(FoldedOuterLayout.usesOuterReskin(containerWidth: width, showsTrack: true),
                               phone, "w \(width) h \(height)")
                XCTAssertFalse(FoldedOuterLayout.usesOuterReskin(containerWidth: width, showsTrack: false),
                               "no track never takes the reskin (w \(width))")
            }
        }
        XCTAssertTrue(FoldedOuterLayout.usesOuterReskin(containerWidth: 390, showsTrack: true))
        XCTAssertFalse(FoldedOuterLayout.usesOuterReskin(containerWidth: 640, showsTrack: true))
    }

    func testAContainerOverrideWinsOverTheCallersWidth() {
        let wide = FoldedOuterLayout.ContainerSize(width: 540, height: 760)
        let phone = FoldedOuterLayout.ContainerSize(width: 390, height: 844)
        XCTAssertFalse(FoldedOuterLayout.usesOuterReskin(containerWidth: 390, override: wide, showsTrack: true))
        XCTAssertTrue(FoldedOuterLayout.usesOuterReskin(containerWidth: 820, override: phone, showsTrack: true))
        XCTAssertEqual(FoldedOuterLayout.usesOuterReskin(containerWidth: 390, override: nil, showsTrack: true),
                       FoldedOuterLayout.usesOuterReskin(containerWidth: 390, showsTrack: true))
    }

    /// Both callers go through the shared rule, so neither can drift to its own condition.
    func testPlayingScreenAndFoldedPlayerUseTheSharedRule() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["AeroDJ/FoldedPlayer.swift", "AeroDJ/PlayingScreen.swift"] {
            let source = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains("FoldedOuterLayout.usesOuterReskin("), path)
        }
    }

    /// compactBody and FoldedStyle stay for the non-track phone states: this file must not rewrite their tokens.
    func testFoldedStyleTokensOnTheCompactPathAreUnchanged() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: iosRoot.appendingPathComponent("AeroDJ/FoldedPlayer.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("static let artRadius: CGFloat = 24"))
        XCTAssertTrue(source.contains("static let contentInset: CGFloat = 32"))
        XCTAssertTrue(source.contains("static let toolbarHeight: CGFloat = 52"))
        XCTAssertTrue(source.contains("private func compactBody(in size: CGSize)"))
        // A track at phone width takes the reskin; every other phone state keeps compactBody.
        XCTAssertTrue(source.contains("compactBody(in: geo.size)"))
        XCTAssertTrue(source.contains("foldedOuterBody(in: geo.size)"))
        // On Air in the new status helper is only ever taken from onAirLabel.
        let helper = try String(contentsOf: iosRoot.appendingPathComponent(
            "AeroDJCore/Sources/AeroDJCore/Studio/FoldedOuterLayout.swift"), encoding: .utf8)
        XCTAssertTrue(helper.contains("status(onAirLabel:"))
        XCTAssertFalse(helper.contains("isOnAir ?"),
                       "do not derive the pill from isOnAir; use onAirLabel only")
    }

    // MARK: #537 declutter (closed reskin only)

    func testTitleAndArtistAreOneLineEach() {
        XCTAssertEqual(FoldedOuterLayout.titleLineLimit, 1)
        XCTAssertEqual(FoldedOuterLayout.artistLineLimit, 1)
    }

    func testFreedSpaceGoesToTheArt() {
        // The NEXT row (44 + 12) and the Playing-from toolbar (52 + 12 + 8) are gone.
        XCTAssertEqual(FoldedOuterLayout.artReserveBelowBefore537 - FoldedOuterLayout.artReserveBelow, 128)
        // Phone and closed-Duo heights that were height-capped: the art never shrinks and
        // grows wherever the height was the limit.
        for (width, height) in [(390.0, 763.0), (375.0, 600.0), (390.0, 700.0), (430.0, 840.0), (320.0, 480.0)] {
            let before = FoldedOuterLayout.artSide(containerWidth: width, containerHeight: height,
                                                   minSide: 140, maxSide: 420,
                                                   reserveBelow: FoldedOuterLayout.artReserveBelowBefore537)
            let after = FoldedOuterLayout.artSide(containerWidth: width, containerHeight: height,
                                                  minSide: 140, maxSide: 420)
            XCTAssertGreaterThanOrEqual(after, before, "\(width)x\(height)")
            XCTAssertLessThanOrEqual(after, width - FoldedOuterLayout.artInset * 2, "art stays inside its insets")
        }
        // 390 x 763 (an iPhone under the status bar): 293 pt before, width-capped 330 now.
        XCTAssertEqual(FoldedOuterLayout.artSide(containerWidth: 390, containerHeight: 763, minSide: 140, maxSide: 420), 330)
        XCTAssertEqual(FoldedOuterLayout.artSide(containerWidth: 390, containerHeight: 763, minSide: 140, maxSide: 420,
                                                 reserveBelow: FoldedOuterLayout.artReserveBelowBefore537), 293)
        // The floor still wins on a tiny container.
        XCTAssertEqual(FoldedOuterLayout.artSide(containerWidth: 200, containerHeight: 300, minSide: 140, maxSide: 420), 140)
    }

    func testMicChipIsAnArtBadgeOnlyWhileLive() {
        XCTAssertEqual(FoldedOuterLayout.artBadge(for: .onAir("On Air"), statusPinned: false), .onAir("On Air"))
        XCTAssertNil(FoldedOuterLayout.artBadge(for: .micDown, statusPinned: false), "mic down draws no chip")
        // AX sizes pin ON AIR above the scrubber (testAX5OnAirPinnedAboveScrubber), so no badge too.
        XCTAssertNil(FoldedOuterLayout.artBadge(for: .onAir("On Air"), statusPinned: true))
        XCTAssertNil(FoldedOuterLayout.artBadge(for: .micDown, statusPinned: true))
        XCTAssertEqual(FoldedOuterLayout.pinnedPill(for: .onAir("On Air")), .onAir("On Air"))
        XCTAssertNil(FoldedOuterLayout.pinnedPill(for: .micDown))
        for state in [DJStudioState.idle, .ready(includesBriefing: false, seconds: 3)] {
            XCTAssertNil(FoldedOuterLayout.artBadge(for: FoldedOuterLayout.status(of: state), statusPinned: false), "\(state)")
        }
    }

    func testClosedMoreMenuTakesQueueTuneAndTheStar() {
        XCTAssertEqual(FoldedOuterLayout.closedMoreItems(showsWorkspaceButtons: true, canRate: true), [.queue, .tune, .rating])
        XCTAssertEqual(FoldedOuterLayout.closedMoreItems(showsWorkspaceButtons: true, canRate: false), [.queue, .tune])
        XCTAssertEqual(FoldedOuterLayout.closedMoreItems(showsWorkspaceButtons: false, canRate: false), [.queue],
                       "the Playing-from chip always opened the queue")
    }

    /// The closed reskin no longer draws the NEXT row, the Playing-from toolbar, the star or the
    /// Mic down pill; compactBody and the wide bodies keep FoldedToolbar and the rating button.
    func testClosedReskinSourceDropsTheCutRows() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: iosRoot.appendingPathComponent("AeroDJ/FoldedPlayer.swift"), encoding: .utf8)
        func slice(from start: String, to end: String) throws -> Substring {
            let a = try XCTUnwrap(source.range(of: start), start)
            let b = try XCTUnwrap(source.range(of: end, range: a.upperBound..<source.endIndex), end)
            return source[a.lowerBound..<b.lowerBound]
        }
        let controls = try slice(from: "private func outerControls(pinsStatus: Bool)", to: "private extension View")
        XCTAssertFalse(controls.contains("FoldedToolbar("), "no Playing-from row when closed")
        XCTAssertFalse(controls.contains("FoldedOuterUpNext"), "no NEXT row when closed")
        XCTAssertFalse(source.contains("struct FoldedOuterUpNext"))
        let titleRow = try slice(from: "private struct FoldedOuterTitleRow", to: "private struct FoldedOuterDJLine")
        XCTAssertFalse(titleRow.contains("SongRatingButton"), "the star lives in the ⋯ menu")
        XCTAssertFalse(titleRow.contains("FoldedOuterStatusPill"), "no Mic down chip in the title row")
        XCTAssertTrue(titleRow.contains("FoldedOuterLayout.titleLineLimit"))
        // The other bodies are untouched: compactBody's controls still draw the toolbar.
        let compact = try slice(from: "private func controls(contentInset:", to: "extension FoldedPlayer {")
        XCTAssertTrue(compact.contains("FoldedToolbar("))
    }

    // MARK: #537 closed trailing rail

    func testClosedRailHoldsTheRailPlates() {
        XCTAssertEqual(FoldedOuterLayout.closedRailWidth, 56)
        // The #479 rail's play/pause and skip plates are 44 pt and must fit with room to spare.
        XCTAssertGreaterThanOrEqual(DuoRailLayout.controlSize, 44)
        XCTAssertGreaterThanOrEqual(FoldedOuterLayout.closedRailWidth, DuoRailLayout.controlSize + 12)
        XCTAssertEqual(FoldedOuterLayout.artReserveBelowWithRail, 254, "342 less the 80 pt transport and its 8 pt gap")
    }

    func testArtBesideTheRailFitsItsColumn() {
        for (width, height) in [(390.0, 763.0), (375.0, 600.0), (430.0, 840.0), (320.0, 480.0), (390.0, 520.0)] {
            let side = FoldedOuterLayout.artSideBesideRail(containerWidth: width, containerHeight: height,
                                                           minSide: 140, maxSide: 420)
            let column = FoldedOuterLayout.columnWidthBesideRail(containerWidth: width)
            XCTAssertLessThanOrEqual(side, max(140, column - FoldedOuterLayout.artInsetBesideRail * 2), "\(width)x\(height)")
            XCTAssertGreaterThanOrEqual(side, 140)
        }
        // 390 x 763: width-limited, 390 - 56 - 8 - 48 = 278 (the transport row's height is freed,
        // but the phone is width-limited, so the art is 52 pt narrower than without the rail).
        XCTAssertEqual(FoldedOuterLayout.artSideBesideRail(containerWidth: 390, containerHeight: 763,
                                                           minSide: 140, maxSide: 420), 278)
        // A short container is height-limited, and there the freed 88 pt goes to the art.
        let short = FoldedOuterLayout.artSideBesideRail(containerWidth: 390, containerHeight: 520, minSide: 140, maxSide: 420)
        let shortNoRail = FoldedOuterLayout.artSide(containerWidth: 390, containerHeight: 520, minSide: 140, maxSide: 420)
        XCTAssertGreaterThan(short, shortNoRail)
    }

    /// Transport is on the closed rail now. Mockup D (-Nova): the song position moved to the
    /// rail too (a vertical bar), and so did ⋯ (the header has none now).
    func testClosedReskinTransportIsOnTheRail() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let player = try String(contentsOf: iosRoot.appendingPathComponent("AeroDJ/FoldedPlayer.swift"), encoding: .utf8)
        let a = try XCTUnwrap(player.range(of: "private func outerControls(pinsStatus: Bool)"))
        let b = try XCTUnwrap(player.range(of: "private extension View", range: a.upperBound..<player.endIndex))
        let controls = player[a.lowerBound..<b.lowerBound]
        XCTAssertFalse(controls.contains("FoldedOuterTransport"), "play/skip moved to the rail")
        XCTAssertFalse(controls.contains("PlaybackScrubber("), "mockup D: no horizontal scrubber when closed")
        XCTAssertTrue(player.contains("ClosedVerticalRail("))
        let rail = try String(contentsOf: iosRoot.appendingPathComponent("AeroDJ/DuoVerticalRail.swift"), encoding: .utf8)
        let r = try XCTUnwrap(rail.range(of: "struct ClosedVerticalRail"))
        let end = try XCTUnwrap(rail.range(of: "// MARK: - Glass", range: r.upperBound..<rail.endIndex))
        let closed = rail[r.lowerBound..<end.lowerBound]
        XCTAssertTrue(closed.contains("DuoRailPlayPauseButton("), "the #479 play/pause (transport.playPause)")
        XCTAssertTrue(closed.contains("identifier: \"transport.skip\""))
        // The rail draws the ⋯ it is handed (the closed FoldedMoreMenu, `folded.more`); it does
        // not build a second one of its own.
        XCTAssertFalse(closed.contains("folded.more"), "one ⋯ on the closed screen: the one passed in")
        XCTAssertTrue(closed.contains("more()"))
        XCTAssertTrue(closed.contains("RailScrubber("), "mockup D: the vertical song-position bar")
        XCTAssertTrue(closed.contains("\"queue.affordance\""), "mockup D: Queue is a rail button")
        let h = try XCTUnwrap(player.range(of: "private struct FoldedOuterHeader"))
        let hEnd = try XCTUnwrap(player.range(of: "private struct FoldedOuterTitleRow", range: h.upperBound..<player.endIndex))
        XCTAssertFalse(player[h.lowerBound..<hEnd.lowerBound].contains("FoldedMoreMenu("), "⋯ moved to the rail")
    }
}
