import XCTest
@testable import AeroDJCore

/// Outer-to-inner continuity (#465 item 5, #492). The layout decision and the
/// session that survives it. No view is built here.
final class DisplayContinuityTests: XCTestCase {
    private let phone = (width: 390.0, height: 844.0)
    private let duo = (width: 640.0, height: 820.0)

    func testPhonePortraitStaysBottomControlsAtEitherSizeClass() {
        for regular in [false, true] {
            for ax in [false, true] {
                let layout = DisplayContinuity.layout(hasRegularWidth: regular,
                                                      containerWidth: phone.width,
                                                      containerHeight: phone.height,
                                                      accessibilityTextSize: ax)
                XCTAssertEqual(layout, .phoneBottom, "regular \(regular) ax \(ax)")
                XCTAssertEqual(layout.controlPlacement, .phoneBottom)
            }
        }
    }

    /// Every phone-width container matches the old column rule, at both size classes.
    /// Width under `studioMinWidth` never becomes Studio, even when the class is regular.
    func testPhoneWidthsMatchTheCompactArm() {
        let widths = [320.0, 390, 402, 430, 440, 499]
        let heights = [700.0, 844, 932]
        for width in widths {
            for height in heights {
                let old = FoldedColumnLayout.controlPlacement(containerWidth: width, containerHeight: height)
                for regular in [false, true] {
                    for ax in [false, true] {
                        let layout = DisplayContinuity.layout(hasRegularWidth: regular,
                                                              containerWidth: width,
                                                              containerHeight: height,
                                                              accessibilityTextSize: ax)
                        XCTAssertEqual(layout.controlPlacement, old,
                                       "\(width)x\(height) regular \(regular) ax \(ax)")
                        let mode = StudioLayoutMode.resolve(hasRegularWidth: regular,
                                                            containerWidth: width,
                                                            accessibilityTextSize: ax)
                        XCTAssertEqual(mode, .compact, "a phone width never opens the Studio")
                    }
                }
            }
        }
    }

    func testUnfoldedDuoUsesTheSameDecisionAtBothSizeClasses() {
        for regular in [false, true] {
            let layout = DisplayContinuity.layout(hasRegularWidth: regular,
                                                  containerWidth: duo.width,
                                                  containerHeight: duo.height,
                                                  accessibilityTextSize: false)
            XCTAssertEqual(layout, .duoHorizontal, "regular \(regular)")
            XCTAssertEqual(layout.controlPlacement,
                           FoldedColumnLayout.controlPlacement(containerWidth: duo.width,
                                                               containerHeight: duo.height))
        }
    }

    /// #542 (2.0 design, after build 49): at the Studio threshold a wide-and-tall container
    /// is the rail layout, not the two-zone Studio. Accessibility sizes keep the stacked
    /// Studio. Only a regular container too short for the rail still opens the Studio.
    func testRegularWidthAtTheStudioThresholdIsTheRailUnlessShort() {
        let width = StudioLayoutMetrics.studioMinWidth
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: width,
                                                containerHeight: 680, accessibilityTextSize: false), .duoHorizontal)
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: width,
                                                containerHeight: 680, accessibilityTextSize: true), .studioStacked)
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: width,
                                                containerHeight: 599, accessibilityTextSize: false), .studio,
                       "wide but shorter than the landscape rail keeps the Studio")
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: false, containerWidth: width + 64,
                                                containerHeight: 900, accessibilityTextSize: false), .duoHorizontal,
                       "compact class never opens the Studio, however wide")
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: width - 1,
                                                containerHeight: 820, accessibilityTextSize: false), .duoHorizontal)
    }

    /// The compact probe (652 × 680) keeps the centred column. The regular probe
    /// (780 × 680) is now wide-and-tall, so it is the rail layout (#542), not the Studio.
    func testResizeProbeSizesMatchTheExistingSwitch() {
        let minimum = StudioLayoutMetrics.studioMinWidth
        let compact = DisplayContinuity.layout(hasRegularWidth: false, containerWidth: minimum - 64,
                                               containerHeight: 680, accessibilityTextSize: false)
        XCTAssertEqual(compact, .centredColumn)
        let regular = DisplayContinuity.layout(hasRegularWidth: true, containerWidth: minimum + 64,
                                              containerHeight: 680, accessibilityTextSize: false)
        XCTAssertEqual(regular, .duoHorizontal)
        XCTAssertEqual(DisplayContinuity.screenMode(regular), .compact, "the rail is the FoldedPlayer branch")
    }

    // MARK: #542, Duo tablet mode on build 49

    /// Root cause 1: a regular width class at 716+ took the old two-zone Studio. Every
    /// wide-and-tall container, portrait or landscape, is now the rail at either class.
    func testRegularWidthAt716AndWiderIsTheRailWhenTall() {
        let sizes: [(Double, Double)] = [(716, 820), (820, 1180), (1032, 1376), (1180, 820),
                                         (1366, 1024), (716, 600)]
        for (width, height) in sizes {
            for regular in [false, true] {
                let layout = DisplayContinuity.layout(hasRegularWidth: regular, containerWidth: width,
                                                      containerHeight: height, accessibilityTextSize: false)
                XCTAssertEqual(layout, .duoHorizontal, "\(width)×\(height) regular \(regular)")
                XCTAssertEqual(DisplayContinuity.screenMode(layout), .compact)
            }
        }
    }

    /// Root cause 1, second half: regular width at 500–715 and tall took the two-pane
    /// arrangement. The layout decision there is the rail at both classes; `PlayingScreen`
    /// no longer routes the arrangement.
    func testRegularWidth500To715IsTheRailWhenTall() {
        for width in [500.0, 540, 640, 700, 715] {
            for height in [716.0, 820, 900] {
                for regular in [false, true] {
                    XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: regular, containerWidth: width,
                                                            containerHeight: height, accessibilityTextSize: false),
                                   .duoHorizontal, "\(width)×\(height) regular \(regular)")
                }
            }
        }
    }

    /// Root cause 2: 820 × 640 landscape (the open Duo turned sideways) was the centred column.
    func testDuoLandscape820x640IsTheRail() {
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 820, containerHeight: 640), .duoHorizontal)
        for regular in [false, true] {
            XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: regular, containerWidth: 820,
                                                    containerHeight: 640, accessibilityTextSize: false),
                           .duoHorizontal, "regular \(regular)")
        }
    }

    /// The landscape rule's edges: 716+ wide and 600+ tall. Narrower or shorter stays the
    /// centred column, so phones sideways and the 652 × 680 probe are unchanged.
    func testLandscapeRailThresholds() {
        let min = FoldedColumnLayout.landscapeDuoMinWidth
        XCTAssertEqual(min, 716)
        XCTAssertEqual(FoldedColumnLayout.landscapeDuoMinHeight, 600)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: min, containerHeight: 600), .duoHorizontal)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: min, containerHeight: 599), .centredColumn)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: min - 1, containerHeight: 640), .centredColumn)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 932, containerHeight: 430), .centredColumn)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: .infinity, containerHeight: 640), .phoneBottom)
        XCTAssertEqual(FoldedColumnLayout.controlPlacement(containerWidth: 820, containerHeight: .nan), .centredColumn)
        // The rail fits at the shortest landscape height.
        XCTAssertTrue(DuoRailLayout.fits(containerHeight: FoldedColumnLayout.landscapeDuoMinHeight, showsTransport: true))
    }

    /// Accessibility text sizes keep the stacked Studio wherever the Studio gate opens
    /// (regular, 716+), however tall. Compact width at AX sizes is unchanged.
    func testAccessibilitySizesStayStacked() {
        let sizes: [(Double, Double)] = [(716, 599), (716, 820), (820, 640), (1032, 1376), (1366, 1024)]
        for (width, height) in sizes {
            XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: width,
                                                    containerHeight: height, accessibilityTextSize: true),
                           .studioStacked, "\(width)×\(height)")
        }
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: false, containerWidth: 820,
                                                containerHeight: 640, accessibilityTextSize: true), .duoHorizontal)
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: 640,
                                                containerHeight: 820, accessibilityTextSize: true), .duoHorizontal)
        XCTAssertEqual(DisplayContinuity.screenMode(.studioStacked), .studioStacked)
        XCTAssertEqual(DisplayContinuity.screenMode(.studio), .studio)
    }

    /// The layout log names are fixed strings: no station, track or user content.
    func testLayoutLogNames() {
        let all: [DisplayContinuity.Layout] = [.phoneBottom, .centredColumn, .duoHorizontal, .studio, .studioStacked]
        XCTAssertEqual(all.map(DisplayContinuity.logName),
                       ["phoneBottom", "centredColumn", "duoRail", "studio", "studioStacked"])
    }

    func testOpeningThePhoneKeepsStationScrollPlaybackAndLoadCount() {
        let session = DisplayContinuity.Session(
            selectedStationID: "morning-calm",
            scrollAnchor: DisplayContinuity.rowAnchor(4),
            playbackToken: DisplayContinuity.playbackToken(transport: .playing, trackID: "1"),
            loadCount: 1)
        let folded = DisplayContinuity.layout(hasRegularWidth: false,
                                              containerWidth: phone.width,
                                              containerHeight: phone.height,
                                              accessibilityTextSize: false)
        let unfolded = DisplayContinuity.layout(hasRegularWidth: true,
                                                containerWidth: duo.width,
                                                containerHeight: duo.height,
                                                accessibilityTextSize: false)
        XCTAssertEqual(folded, .phoneBottom)
        XCTAssertEqual(unfolded, .duoHorizontal)
        XCTAssertNotEqual(folded, unfolded)
        let opened = session.opening(to: unfolded)
        XCTAssertEqual(opened, session)
        XCTAssertEqual(opened.selectedStationID, "morning-calm")
        XCTAssertEqual(opened.scrollAnchor, "continuity.row.4")
        XCTAssertEqual(opened.playbackToken, "playing|1")
        XCTAssertEqual(opened.loadCount, 1)
        XCTAssertEqual(opened.loaded().loadCount, 2, "only an explicit load increments")
        XCTAssertEqual(session.loadCount, 1, "opening does not mutate the previous session")
    }

    func testAppearKeepsAStoredAnchorAndDoesNotLoad() {
        let stored = DisplayContinuity.Session(
            selectedStationID: "late-night",
            scrollAnchor: "late-night",
            playbackToken: DisplayContinuity.playbackToken(transport: .paused, trackID: "2"),
            loadCount: 3)
        let appeared = stored.appeared(defaultAnchor: "morning-calm")
        XCTAssertEqual(appeared, stored)
        XCTAssertEqual(appeared.loadCount, 3)

        var empty = stored
        empty.scrollAnchor = nil
        let seeded = empty.appeared(defaultAnchor: "morning-calm")
        XCTAssertEqual(seeded.scrollAnchor, "morning-calm")
        XCTAssertEqual(seeded.selectedStationID, stored.selectedStationID)
        XCTAssertEqual(seeded.playbackToken, stored.playbackToken)
        XCTAssertEqual(seeded.loadCount, 3)

        empty.scrollAnchor = ""
        XCTAssertEqual(empty.appeared(defaultAnchor: DisplayContinuity.titleAnchor).scrollAnchor,
                       DisplayContinuity.titleAnchor)
    }

    func testScrolledAnchorReplacesThePreviousOneWithoutALoad() {
        let session = DisplayContinuity.Session(
            selectedStationID: "morning-calm", scrollAnchor: DisplayContinuity.artAnchor,
            playbackToken: "playing|1", loadCount: 0)
        let next = session.scrolled(to: DisplayContinuity.rowAnchor(4))
        XCTAssertEqual(next.scrollAnchor, "continuity.row.4")
        XCTAssertEqual(next.loadCount, 0)
        XCTAssertEqual(next.selectedStationID, session.selectedStationID)
        XCTAssertEqual(next.playbackToken, session.playbackToken)
        XCTAssertNil(session.scrolled(to: nil).scrollAnchor)
    }

    func testPlaybackTokenNamesTransportAndTrack() {
        XCTAssertEqual(DisplayContinuity.playbackToken(transport: .playing, trackID: "1"), "playing|1")
        XCTAssertEqual(DisplayContinuity.playbackToken(transport: .paused, trackID: nil), "paused|")
        XCTAssertEqual(DisplayContinuity.playbackToken(transport: .stopped, trackID: nil), "stopped|")
    }

    /// An art write can land before a separate arm() call. Passing the new
    /// scroller's layout on the write arms first, then ignores the art.
    func testArtWriteBeforeArmingDoesNotReplaceTheStoredId() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        XCTAssertEqual(machine.phase, .idle)
        let result = machine.write(DisplayContinuity.artAnchor,
                                   stored: DisplayContinuity.titleAnchor,
                                   layout: "duoRail")
        XCTAssertEqual(result, .ignore)
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertEqual(machine.held, DisplayContinuity.titleAnchor)
        XCTAssertEqual(machine.layout, "duoRail")
    }

    /// The 0.45s layout animation is not a release. Later art writes stay ignored
    /// until the scroller adopts the held id or the user scrolls. No clock.
    func testArtWriteAfterTheLayoutAnimationStaysIgnoredUntilAdoptionOrUserScroll() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        machine.arm(held: DisplayContinuity.rowAnchor(4), layout: "phoneBottom")
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor), .ignore)
        XCTAssertEqual(machine.phase, .armed)
        // A later frame, as after the 0.45s mode animation, still reports the art.
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor), .ignore)
        XCTAssertEqual(machine.write(DisplayContinuity.titleAnchor), .ignore,
                       "a first-layout title is not a user scroll")
        XCTAssertEqual(machine.write(""), .ignore)
        XCTAssertEqual(machine.write(nil), .ignore)
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertEqual(machine.held, DisplayContinuity.rowAnchor(4))
    }

    func testScrollerAdoptionAcceptsTheHeldIdAndStillIgnoresALaterArtWrite() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        machine.arm(held: DisplayContinuity.rowAnchor(4), layout: "duoRail")
        XCTAssertEqual(machine.write(DisplayContinuity.rowAnchor(4)), .accept)
        XCTAssertEqual(machine.phase, .adopted)
        XCTAssertEqual(machine.write(DisplayContinuity.rowAnchor(4)), .accept)
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor), .ignore,
                       "adoption is not a release; a late art write cannot jump")
        XCTAssertEqual(machine.phase, .adopted)
    }

    func testUserScrollBackToTheArtIsKept() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        machine.arm(held: DisplayContinuity.titleAnchor, layout: "duoRail")
        XCTAssertEqual(machine.write(DisplayContinuity.titleAnchor), .accept)
        XCTAssertEqual(machine.phase, .adopted)
        machine.noteUserScrolled()
        XCTAssertEqual(machine.phase, .userScrolled)
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor), .accept)
        XCTAssertEqual(machine.phase, .released)
        XCTAssertEqual(machine.write(DisplayContinuity.titleAnchor), .accept,
                       "after release, later writes stay accepted")
    }

    func testUserScrollWhileArmedReleasesWithoutWaitingForAdoption() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        machine.arm(held: DisplayContinuity.titleAnchor, layout: "duoRail")
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor), .ignore)
        machine.noteUserScrolled()
        XCTAssertEqual(machine.phase, .userScrolled)
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor), .accept)
        XCTAssertEqual(machine.phase, .released)
    }

    func testANewLayoutRearmsAFreshStoredIdAndTheSameLayoutDoesNot() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        machine.arm(held: DisplayContinuity.titleAnchor, layout: "phoneBottom")
        XCTAssertEqual(machine.write(DisplayContinuity.titleAnchor), .accept)
        machine.noteUserScrolled()
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor), .accept)
        XCTAssertEqual(machine.phase, .released)
        machine.arm(held: DisplayContinuity.artAnchor, layout: "phoneBottom")
        XCTAssertEqual(machine.phase, .released, "same layout stays released")
        machine.arm(held: DisplayContinuity.rowAnchor(4), layout: "duoRail")
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertEqual(machine.held, DisplayContinuity.rowAnchor(4))
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor, stored: DisplayContinuity.rowAnchor(4),
                                     layout: "duoRail"), .ignore)
    }

    func testNothingStoredStaysIdleAndAcceptsWrites() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        machine.arm(held: "", layout: "duoRail")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor), .accept)
    }
    // MARK: Release whatever the input (#492, Atlas on 42a53bc6)

    /// The rebuilt scroller writes the held id back (its own adoption echo), then
    /// the art while the 0.45s animation settles. Neither is a release, and the
    /// art is not stored.
    func testAdoptionEchoAndASettleArtWriteDoNotRelease() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        let held = DisplayContinuity.rowAnchor(4)
        XCTAssertEqual(machine.write(held, stored: held, layout: "openHalves"), .accept)
        XCTAssertEqual(machine.phase, .adopted)
        XCTAssertEqual(machine.write(held, stored: held, layout: "openHalves"), .accept, "echo")
        XCTAssertEqual(machine.phase, .adopted, "the echo is not a release")
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor, stored: held, layout: "openHalves"), .ignore,
                       "a settle art write is not stored")
        XCTAssertEqual(machine.write(nil, stored: held, layout: "openHalves"), .ignore)
        XCTAssertEqual(machine.phase, .adopted)
        XCTAssertEqual(machine.held, held)
    }

    /// The scroller's first id (the title when the art is not drawn) is a settle id too.
    func testTheScrollersFirstIdIsASettleWriteAfterAdoption() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        let held = DisplayContinuity.rowAnchor(4)
        machine.noteScrollerIDs([DisplayContinuity.titleAnchor, held], stored: held, layout: "compactUpper")
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertEqual(machine.write(held, stored: held, layout: "compactUpper"), .accept)
        XCTAssertEqual(machine.write(DisplayContinuity.titleAnchor, stored: held, layout: "compactUpper"), .ignore)
        XCTAssertEqual(machine.phase, .adopted)
    }

    /// VoiceOver, trackpad, mouse and `scrollTo` send no drag. After adoption a move
    /// to another id releases and is kept, on every OS.
    func testAPositionChangeAfterAdoptionReleasesWithoutADrag() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        let held = DisplayContinuity.rowAnchor(4)
        XCTAssertEqual(machine.write(held, stored: held, layout: "openHalves"), .accept)
        XCTAssertEqual(machine.write(DisplayContinuity.rowAnchor(5), stored: held, layout: "openHalves"), .accept)
        XCTAssertEqual(machine.phase, .released)
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor, stored: DisplayContinuity.rowAnchor(5),
                                     layout: "openHalves"), .accept,
                       "after release a scroll back to the art is kept")
    }

    /// A user scroll phase (iOS 18+) or drag (iOS 17) after adoption: the art is kept.
    func testAUserScrollPhaseAfterAdoptionKeepsTheArt() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        let held = DisplayContinuity.rowAnchor(4)
        XCTAssertEqual(machine.write(held, stored: held, layout: "openHalves"), .accept)
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor, stored: held, layout: "openHalves"), .ignore)
        machine.noteUserScrolled()
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor, stored: held, layout: "openHalves"), .accept)
        XCTAssertEqual(machine.phase, .released)
    }

    /// The held id is not in the new scroller: it can never adopt, so release
    /// instead of staying armed. No clock.
    func testAHeldIdMissingFromTheNewScrollerReleases() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        let held = DisplayContinuity.rowAnchor(4)
        machine.noteScrollerIDs([DisplayContinuity.artAnchor, DisplayContinuity.titleAnchor],
                                stored: held, layout: "centredColumn")
        XCTAssertEqual(machine.phase, .released)
        XCTAssertEqual(machine.write(DisplayContinuity.titleAnchor, stored: held, layout: "centredColumn"), .accept)
    }

    func testAHeldIdThatDisappearsAfterAdoptionReleases() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        let held = DisplayContinuity.rowAnchor(4)
        machine.noteScrollerIDs([DisplayContinuity.artAnchor, held], stored: held, layout: "openHalves")
        XCTAssertEqual(machine.write(held, stored: held, layout: "openHalves"), .accept)
        XCTAssertEqual(machine.phase, .adopted)
        machine.noteScrollerIDs([DisplayContinuity.artAnchor], stored: held, layout: "openHalves")
        XCTAssertEqual(machine.phase, .released)
    }

    /// A scroller that has laid out nothing yet reports no ids. That is not a miss.
    func testAnEmptyIdListDoesNotRelease() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        let held = DisplayContinuity.rowAnchor(4)
        machine.noteScrollerIDs([], stored: held, layout: "openHalves")
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor, stored: held, layout: "openHalves"), .ignore)
    }

    /// Echo's fix stays: the same scroller does not re-arm after release, even when
    /// its ids arrive again.
    func testTheSameLayoutDoesNotRearmOnItsIds() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        let held = DisplayContinuity.rowAnchor(4)
        XCTAssertEqual(machine.write(held, stored: held, layout: "openHalves"), .accept)
        machine.noteUserScrolled()
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor, stored: held, layout: "openHalves"), .accept)
        machine.noteScrollerIDs([DisplayContinuity.artAnchor, held], stored: DisplayContinuity.artAnchor,
                                layout: "openHalves")
        XCTAssertEqual(machine.phase, .released)
    }

    /// Echo's repro: an idle scroller (nothing stored) keeps every write on the
    /// same layout. It must never re-arm on the id it just stored.
    func testAnIdleScrollerKeepsThreeWritesOnTheSameLayout() {
        for withIDs in [false, true] {
            var machine = DisplayContinuity.ScrollAnchorMachine()
            var stored = ""
            for id in ["a", "b", "c"] {
                if withIDs { machine.noteScrollerIDs(["a", "b", "c"], stored: stored, layout: "openHalves") }
                XCTAssertEqual(machine.write(id, stored: stored, layout: "openHalves"), .accept)
                stored = id
            }
            XCTAssertEqual(stored, "c")
            XCTAssertEqual(machine.phase, .idle)
        }
    }

    /// A stored id set outside the scroller while it is held: hold the new id.
    func testAStoredIdChangedOutsideTheScrollerIsHeld() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        machine.arm(held: DisplayContinuity.titleAnchor, layout: "outerUpper")
        let jump = DisplayContinuity.rowAnchor(4)
        XCTAssertEqual(machine.write(DisplayContinuity.artAnchor, stored: jump, layout: "outerUpper"), .ignore)
        XCTAssertEqual(machine.held, jump)
        XCTAssertEqual(machine.write(jump, stored: jump, layout: "outerUpper"), .accept)
        XCTAssertEqual(machine.phase, .adopted)
    }

    func testPhaseNamesForTheReadout() {
        var machine = DisplayContinuity.ScrollAnchorMachine()
        XCTAssertEqual(machine.phaseName, "idle")
        machine.arm(held: DisplayContinuity.titleAnchor, layout: "openHalves")
        XCTAssertEqual(machine.phaseName, "armed")
        _ = machine.write(DisplayContinuity.titleAnchor)
        XCTAssertEqual(machine.phaseName, "adopted")
        machine.noteUserScrolled()
        XCTAssertEqual(machine.phaseName, "userScrolled")
        _ = machine.write(DisplayContinuity.artAnchor)
        XCTAssertEqual(machine.phaseName, "released")
    }
}

