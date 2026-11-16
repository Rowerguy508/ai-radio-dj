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

    func testRegularWidthAtTheStudioThresholdStillOpensTheStudio() {
        let width = StudioLayoutMetrics.studioMinWidth
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: width,
                                                containerHeight: 680, accessibilityTextSize: false), .studio)
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: width,
                                                containerHeight: 680, accessibilityTextSize: true), .studioStacked)
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: false, containerWidth: width + 64,
                                                containerHeight: 900, accessibilityTextSize: false), .duoHorizontal,
                       "compact class never opens the Studio, however wide")
        XCTAssertEqual(DisplayContinuity.layout(hasRegularWidth: true, containerWidth: width - 1,
                                                containerHeight: 820, accessibilityTextSize: false), .duoHorizontal)
    }

    func testResizeProbeSizesMatchTheExistingSwitch() {
        let minimum = StudioLayoutMetrics.studioMinWidth
        let compact = DisplayContinuity.layout(hasRegularWidth: false, containerWidth: minimum - 64,
                                               containerHeight: 680, accessibilityTextSize: false)
        XCTAssertEqual(compact, .centredColumn)
        let regular = DisplayContinuity.layout(hasRegularWidth: true, containerWidth: minimum + 64,
                                              containerHeight: 680, accessibilityTextSize: false)
        XCTAssertEqual(regular, .studio)
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
}
