import XCTest
@testable import AeroDJCore

/// #465 item 3: the tent pose decision, its layout and the face rules. The app has no hinge
/// API in the required 26.5 SDK, so these tests are what drive the pose.
final class DuoPoseTests: XCTestCase {
    private let tentSize = (w: 820.0, h: 640.0)

    private func tent(_ degrees: Double, _ status: DuoHingeSample.Status = .partiallyOpen) -> DuoHingeSample {
        DuoHingeSample(status: status, angleDegrees: degrees)
    }

    // MARK: Pose

    func testNoHingeIsAlwaysFlat() {
        // Every iPhone, iPad, and any build without the iOS 27.1 SDK.
        for (w, h) in [(390.0, 844.0), (640, 820), (820, 640), (1032, 1376), (1376, 1032)] {
            XCTAssertEqual(DuoPoseDecision.resolve(hinge: nil, containerWidth: w, containerHeight: h), .flat, "\(w)×\(h)")
            XCTAssertEqual(DuoPoseDecision.resolve(hinge: nil, containerWidth: w, containerHeight: h, previous: .tent), .flat)
        }
    }

    func testPartiallyOpenLandscapeInsideTheBandIsTent() {
        for degrees in [45.0, 60, 90, 120, 135] {
            XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(degrees), containerWidth: tentSize.w,
                                                   containerHeight: tentSize.h), .tent, "\(degrees)°")
        }
    }

    func testOtherStatusesAreFlatAtAnyAngle() {
        for status in [DuoHingeSample.Status.closed, .fullyOpen, .unknown] {
            for degrees in [0.0, 90, 180] {
                XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(degrees, status), containerWidth: tentSize.w,
                                                       containerHeight: tentSize.h, previous: .tent), .flat,
                               "\(status) \(degrees)°")
            }
        }
    }

    func testPortraitFoldIsTheExistingDuoSplitNotTent() {
        // Unfolded upright (640 × 820): the fold is vertical, which is #460's duoHorizontal.
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(90), containerWidth: 640, containerHeight: 820), .flat)
        // Square is not landscape either.
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(90), containerWidth: 700, containerHeight: 700), .flat)
    }

    func testSmallContainersAreFlat() {
        // The closed Duo / phone widths, and a short split-view slice.
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(90), containerWidth: 499, containerHeight: 420), .flat)
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(90), containerWidth: 820, containerHeight: 399), .flat)
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(90), containerWidth: 500, containerHeight: 400), .tent)
    }

    func testNonFiniteInputsAreFlat() {
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(.nan), containerWidth: 820, containerHeight: 640), .flat)
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(.infinity), containerWidth: 820, containerHeight: 640), .flat)
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(90), containerWidth: .infinity, containerHeight: 640), .flat)
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(90), containerWidth: 820, containerHeight: .nan), .flat)
    }

    func testHysteresisHoldsTheTentNearTheEdges() {
        // 40° and 145° do not enter the tent from flat...
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(40), containerWidth: 820, containerHeight: 640), .flat)
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(145), containerWidth: 820, containerHeight: 640), .flat)
        // ...but do not leave it either.
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(40), containerWidth: 820, containerHeight: 640, previous: .tent), .tent)
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(145), containerWidth: 820, containerHeight: 640, previous: .tent), .tent)
        // Past the hold band it leaves.
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(34), containerWidth: 820, containerHeight: 640, previous: .tent), .flat)
        XCTAssertEqual(DuoPoseDecision.resolve(hinge: tent(151), containerWidth: 820, containerHeight: 640, previous: .tent), .flat)
    }

    func testEnterBandSitsInsideHoldBand() {
        XCTAssertLessThan(DuoPoseDecision.holdDegrees.lowerBound, DuoPoseDecision.enterDegrees.lowerBound)
        XCTAssertGreaterThan(DuoPoseDecision.holdDegrees.upperBound, DuoPoseDecision.enterDegrees.upperBound)
    }

    // MARK: Layout

    func testOwnerFrameGeometry() {
        let layout = TentPoseLayout.make(containerWidth: 820, containerHeight: 640, accessibilityText: false)
        XCTAssertEqual(layout.foldBand, 28)
        XCTAssertEqual(layout.faceHeight, 306)
        XCTAssertEqual(layout.lowerHeight, 306)
        XCTAssertEqual(layout.faceHeight + layout.foldBand + layout.lowerHeight, 640)
        // Fold centred on y = 320, as in the mockup.
        XCTAssertEqual(layout.faceHeight + layout.foldBand / 2, 320)
        XCTAssertEqual(layout.clockPointSize, 149.94, accuracy: 0.01)
        XCTAssertEqual(layout.heroSide, 140)
        XCTAssertEqual(layout.stationColumnWidth, 200)
        XCTAssertTrue(layout.usesColumns)
        XCTAssertEqual(layout.controlsPlacement, .onFace)
    }

    func testClockShrinksWithTheContainerButHasAFloor() {
        let narrow = TentPoseLayout.make(containerWidth: 600, containerHeight: 440, accessibilityText: false)
        XCTAssertLessThan(narrow.clockPointSize, 150)
        XCTAssertGreaterThanOrEqual(narrow.clockPointSize, TentPoseLayout.minClockPointSize)
        XCTAssertFalse(narrow.usesColumns, "600 pt cannot hold three columns")
        let tiny = TentPoseLayout.make(containerWidth: 100, containerHeight: 50, accessibilityText: false)
        XCTAssertEqual(tiny.clockPointSize, TentPoseLayout.minClockPointSize)
        XCTAssertEqual(tiny.faceHeight, 11)
        let broken = TentPoseLayout.make(containerWidth: .nan, containerHeight: -10, accessibilityText: false)
        XCTAssertEqual(broken.faceHeight, 0)
        XCTAssertEqual(broken.heroSide, 0)
    }

    func testAccessibilityTextDropsToOneColumn() {
        let layout = TentPoseLayout.make(containerWidth: 820, containerHeight: 640, accessibilityText: true)
        XCTAssertFalse(layout.usesColumns)
    }

    func testLowerHalfPlacementIsOptIn() {
        let layout = TentPoseLayout.make(containerWidth: 820, containerHeight: 640, accessibilityText: false,
                                         controlsPlacement: .lowerHalf)
        XCTAssertEqual(layout.controlsPlacement, .lowerHalf)
    }

    // MARK: Controls

    func testTargetsMeetTheFloors() {
        XCTAssertGreaterThanOrEqual(TentControlsPolicy.playSide, TentControlsPolicy.bigTransportMinSide)
        XCTAssertGreaterThanOrEqual(TentControlsPolicy.skipSide, TentControlsPolicy.bigTransportMinSide)
        XCTAssertGreaterThanOrEqual(TentControlsPolicy.bigTransportMinSide, 60)
        XCTAssertGreaterThanOrEqual(TentControlsPolicy.targetMinSide, TentControlsPolicy.hitTargetFloor)
        XCTAssertEqual(TentControlsPolicy.targetMinSide, 52)
        XCTAssertEqual(TentControlsPolicy.hitTargetFloor, 44)
    }

    func testChipFloorsDoNotCapTallerAccessibilityText() {
        // Dial chips (52) and "Tap to show controls" / the break chip (44) use a
        // minHeight floor. A larger label, as at accessibility text sizes, must grow.
        for floor in [TentControlsPolicy.targetMinSide, TentControlsPolicy.hitTargetFloor] {
            XCTAssertGreaterThanOrEqual(floor, TentControlsPolicy.hitTargetFloor)
            XCTAssertGreaterThan(floor + 20, floor, "floor \(floor) is not a cap")
            XCTAssertEqual(max(floor, 80), 80, "an 80 pt label grows past the \(floor) pt floor")
            XCTAssertEqual(max(floor, 20), floor, "shorter content still meets the floor")
        }
    }

    func testControlsHiddenUntilTouchedAndHideAfterFiveSeconds() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertFalse(TentControlsPolicy.showsControls(lastTouch: nil, now: t0, assistiveTechnology: false))
        XCTAssertTrue(TentControlsPolicy.showsControls(lastTouch: t0, now: t0, assistiveTechnology: false))
        XCTAssertTrue(TentControlsPolicy.showsControls(lastTouch: t0, now: t0.addingTimeInterval(4.9), assistiveTechnology: false))
        XCTAssertFalse(TentControlsPolicy.showsControls(lastTouch: t0, now: t0.addingTimeInterval(5), assistiveTechnology: false))
        // A clock that moved backwards does not keep them up.
        XCTAssertFalse(TentControlsPolicy.showsControls(lastTouch: t0, now: t0.addingTimeInterval(-1), assistiveTechnology: false))
    }

    func testAssistiveTechnologyKeepsControlsUp() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(TentControlsPolicy.showsControls(lastTouch: nil, now: t0, assistiveTechnology: true))
        XCTAssertTrue(TentControlsPolicy.showsControls(lastTouch: t0, now: t0.addingTimeInterval(600), assistiveTechnology: true))
        XCTAssertFalse(TentControlsPolicy.autoHides(assistiveTechnology: true))
        XCTAssertTrue(TentControlsPolicy.autoHides(assistiveTechnology: false))
        XCTAssertFalse(TentControlsPolicy.autoHides(assistiveTechnology: false, holdOpen: true))
    }

    func testReduceMotionIsCrossfadeOnly() {
        XCTAssertEqual(TentControlsPolicy.transition(reduceMotion: true), .crossfade)
        XCTAssertEqual(TentControlsPolicy.transition(reduceMotion: false), .fadeUp)
        XCTAssertEqual(TentControlsPolicy.revealSeconds, 0.25)
    }

    // MARK: Face

    func testOnAirComesOnlyFromConfirmedSpeaking() {
        let notOnAir: [DJStudioState] = [.idle, .preparing(includesBriefing: false),
                                         .ready(includesBriefing: false, seconds: 30),
                                         .failed(.voiceFailed), .failed(.budgetReached),
                                         .failed(.consentReviewRequired(pendingCount: 2))]
        for state in notOnAir {
            XCTAssertNil(TentFace.onAirLabel(state), "\(state)")
            XCTAssertNotEqual(TentFace.hero(state: state, reduceMotion: false, hasTrack: true), .liveOrb)
            XCTAssertEqual(TentFace.nextCaption(state: state), "Up next")
        }
        let speaking = DJStudioState.speaking(includesBriefing: false)
        XCTAssertEqual(TentFace.onAirLabel(speaking), speaking.onAirLabel)
        XCTAssertEqual(TentFace.onAirLabel(speaking), "On Air")
        XCTAssertEqual(TentFace.onAirLabel(.speaking(includesBriefing: true)), "On Air")
        XCTAssertEqual(TentFace.nextCaption(state: speaking), "Up after the break")
    }

    func testHeroFollowsStateAndReduceMotion() {
        let speaking = DJStudioState.speaking(includesBriefing: false)
        XCTAssertEqual(TentFace.hero(state: speaking, reduceMotion: false, hasTrack: true), .liveOrb)
        XCTAssertEqual(TentFace.hero(state: speaking, reduceMotion: true, hasTrack: true), .stillOrb)
        XCTAssertEqual(TentFace.hero(state: .idle, reduceMotion: false, hasTrack: true), .artwork)
        XCTAssertEqual(TentFace.hero(state: .ready(includesBriefing: false, seconds: 3), reduceMotion: false, hasTrack: true), .artwork)
        XCTAssertEqual(TentFace.hero(state: .idle, reduceMotion: false, hasTrack: false), .stationArt)
    }

    func testBreakChipOnlyWhileABreakIsReady() {
        let ready = DJStudioState.ready(includesBriefing: false, seconds: 30)
        let headline = DJStatusPresentation(state: ready).headline
        XCTAssertEqual(TentFace.breakChip(state: ready, headline: headline), "DJ break after this song")
        XCTAssertNil(TentFace.breakChip(state: ready, headline: nil))
        XCTAssertNil(TentFace.breakChip(state: ready, headline: ""))
        for state in [DJStudioState.idle, .preparing(includesBriefing: false), .speaking(includesBriefing: false),
                      .failed(.voiceFailed)] {
            XCTAssertNil(TentFace.breakChip(state: state, headline: DJStatusPresentation(state: state).headline), "\(state)")
        }
    }

    func testAccessibilitySummaryUsesTheAppName() {
        let speaking = DJStudioState.speaking(includesBriefing: false)
        let summary = TentFace.accessibilitySummary(time: "9:41", station: "Morning Calm",
                                                    state: speaking,
                                                    next: (title: "Slow Burn", artist: "Neon Harbor"))
        XCTAssertEqual(summary, "\(AppName.display) radio face. 9:41. Station Morning Calm. On Air. "
                       + "Up after the break: Slow Burn by Neon Harbor")
        XCTAssertTrue(summary.hasPrefix("OnAirly"))
        // The summary is the only VoiceOver readout for On Air and the station;
        // each appears once, and On Air still comes only from onAirLabel.
        XCTAssertEqual(TentFace.onAirLabel(speaking), "On Air")
        XCTAssertEqual(summary.components(separatedBy: "On Air").count - 1, 1)
        XCTAssertEqual(summary.components(separatedBy: "Morning Calm").count - 1, 1)
        let quiet = TentFace.accessibilitySummary(time: "9:41", station: "Morning Calm", state: .idle, next: nil)
        XCTAssertEqual(quiet, "OnAirly radio face. 9:41. Station Morning Calm")
        XCTAssertFalse(quiet.contains("On Air"))
        XCTAssertNil(TentFace.onAirLabel(.idle))
        XCTAssertEqual(quiet.components(separatedBy: "Morning Calm").count - 1, 1)
    }
}
