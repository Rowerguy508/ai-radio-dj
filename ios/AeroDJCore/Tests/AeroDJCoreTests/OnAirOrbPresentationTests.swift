import XCTest
@testable import AeroDJCore

// #434 (owner, Nov 23 2026): Idle and Starting move into the folded player; the DJ talking
// state keeps the lava-lamp orb; on the open Duo the art hides while the DJ talks, as on
// iPhone; landscape centred adds an orb in the gap by the trailing rail. -Nova
final class OnAirOrbPresentationTests: XCTestCase {
    private let track = TrackInfo(id: "t1", title: "Morning Light", artistName: "Artist")

    // MARK: Folded (iPhone and the closed Duo share this path)

    func testFoldedPlayingShowsTheArtAndNoOrb() {
        let p = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: false, pose: .folded)
        XCTAssertEqual(p.card, .artwork)
        XCTAssertFalse(p.showsContentColumnOrb)
        XCTAssertNil(p.railGapOrb(playerWidth: 820, artSide: 320, trailingReserve: 0))
    }

    func testFoldedTalkingIsUnchangedOrbOnlyCard() {
        let p = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: true, pose: .folded)
        XCTAssertEqual(p.card, .talking)
        XCTAssertEqual(FoldedArtCardLayers.layers(stage: .talking), FoldedArtCardLayers.layers(isOnAir: true),
                       "the shipping iPhone on-air card is unchanged")
        XCTAssertEqual(FoldedArtCardLayers.layers(stage: .artwork), FoldedArtCardLayers.layers(isOnAir: false),
                       "the shipping iPhone playing card is unchanged")
        XCTAssertFalse(p.showsContentColumnOrb)
        XCTAssertFalse(p.showsRailGapOrb)
    }

    func testFoldedIdleAndStartingMoveIntoTheArtFrame() {
        XCTAssertEqual(OnAirOrbPresentation.resolve(content: .nothingPlaying, isOnAir: false, pose: .folded).card, .idle)
        XCTAssertEqual(OnAirOrbPresentation.resolve(content: .starting(stationName: "Morning Calm"),
                                                    isOnAir: false, pose: .folded).card, .starting)
    }

    func testOtherNoTrackStatesKeepTheirPages() {
        for content: NowPlayingContent in [.connecting, .needsAuthorization, .accessDenied, .subscriptionRequired,
                                           .startFailed(stationName: "Morning Calm"),
                                           .startUnavailable(stationName: "Morning Calm")] {
            XCTAssertNil(OnAirOrbPresentation.resolve(content: content, isOnAir: false, pose: .folded).card, "\(content)")
            XCTAssertFalse(FoldedOuterLayout.reskinShows(content), "\(content)")
        }
    }

    func testTheReskinTakesIdleAndStartingButStillNeedsPhoneWidth() {
        XCTAssertTrue(FoldedOuterLayout.reskinShows(.track(track)))
        XCTAssertTrue(FoldedOuterLayout.reskinShows(.nothingPlaying))
        XCTAssertTrue(FoldedOuterLayout.reskinShows(.starting(stationName: "Morning Calm")))
        XCTAssertTrue(FoldedOuterLayout.usesOuterReskin(containerWidth: 390,
                                                        showsTrack: FoldedOuterLayout.reskinShows(.nothingPlaying)))
        XCTAssertFalse(FoldedOuterLayout.usesOuterReskin(containerWidth: 820,
                                                         showsTrack: FoldedOuterLayout.reskinShows(.nothingPlaying)),
                       "the open Duo and iPad keep their own idle pages")
    }

    // MARK: Open Duo

    func testOpenDuoHidesTheArtWhileTheDJTalksLikeIPhone() {
        for pose: OnAirOrbPose in [.openDuoHalves, .openDuoSpread] {
            let talking = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: true, pose: pose)
            XCTAssertEqual(talking.card, .talking, "\(pose)")
            XCTAssertFalse(talking.showsContentColumnOrb, "one orb on screen (\(pose))")
            XCTAssertFalse(talking.showsRailGapOrb, "\(pose)")
            let playing = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: false, pose: pose)
            XCTAssertEqual(playing.card, .artwork, "\(pose)")
            XCTAssertFalse(playing.showsContentColumnOrb, "\(pose)")
        }
    }

    func testOpenDuoIdleAndStartingAreUnchanged() {
        for pose: OnAirOrbPose in [.openDuoHalves, .openDuoSpread, .centred, .wideHalves] {
            XCTAssertNil(OnAirOrbPresentation.resolve(content: .nothingPlaying, isOnAir: false, pose: pose).card)
            XCTAssertNil(OnAirOrbPresentation.resolve(content: .starting(stationName: "Morning Calm"),
                                                      isOnAir: false, pose: pose).card)
        }
    }

    func testRegularWidthHalvesKeepTodaysArtAndColumnOrb() {
        let talking = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: true, pose: .wideHalves)
        XCTAssertEqual(talking.card, .artwork, "iPad keeps the art (keepArtVisible)")
        XCTAssertTrue(talking.showsContentColumnOrb)
        XCTAssertEqual(talking.showsContentColumnOrb, DuoPresentation.showsVisualizer(isOnAir: true))
        XCTAssertFalse(OnAirOrbPresentation.resolve(content: .track(track), isOnAir: false,
                                                    pose: .wideHalves).showsContentColumnOrb)
    }

    // MARK: Landscape centred

    func testCentredHidesTheArtAndPutsTheOneOrbByTheRail() {
        let talking = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: true, pose: .centred)
        XCTAssertEqual(talking.card, .cleared)
        XCTAssertTrue(talking.showsRailGapOrb)
        XCTAssertFalse(talking.showsContentColumnOrb)
        let cleared = FoldedArtCardLayers.layers(stage: .cleared)
        XCTAssertEqual(cleared.artworkOpacity, 0)
        XCTAssertEqual(cleared.glowOpacity, 0)
        XCTAssertFalse(cleared.showsOrb, "the orb is by the rail, not in the frame")
        let playing = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: false, pose: .centred)
        XCTAssertEqual(playing.card, .artwork)
        XCTAssertFalse(playing.showsRailGapOrb)
    }

    func testRailGapOrbIsCentredInTheGapAndSizedFromTheArt() throws {
        let p = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: true, pose: .centred)
        // 760 pt player, 320 pt art: the art ends 540 pt in; the gap is 220 pt wide.
        let orb = try XCTUnwrap(p.railGapOrb(playerWidth: 760, artSide: 320, trailingReserve: 0))
        XCTAssertEqual(orb.side, 320 * OnAirOrbPresentation.railGapOrbFraction, accuracy: 0.001)
        XCTAssertEqual(OnAirOrbPresentation.railGapOrbFraction, 0.42)
        // Offset from the art's centre to the gap's centre: 160 + 110.
        XCTAssertEqual(orb.offsetFromArtCentre, 270, accuracy: 0.001)
        // The orb stays inside the gap with its margin on both sides.
        XCTAssertGreaterThanOrEqual(orb.offsetFromArtCentre - orb.side / 2, 160 + OnAirOrbPresentation.railGapMargin - 0.001)
        XCTAssertLessThanOrEqual(orb.offsetFromArtCentre + orb.side / 2, 380 - OnAirOrbPresentation.railGapMargin + 0.001)
    }

    func testRailGapOrbShrinksToTheGapAndDropsBelow44() throws {
        let p = OnAirOrbPresentation.resolve(content: .track(track), isOnAir: true, pose: .centred)
        // A system bar inside the player takes 56 pt of the gap: 220 - 56 = 164, less 2 × 16.
        let narrow = try XCTUnwrap(p.railGapOrb(playerWidth: 760, artSide: 400, trailingReserve: 56))
        XCTAssertLessThanOrEqual(narrow.side, (760 - 400) / 2 - 56 - 2 * OnAirOrbPresentation.railGapMargin + 0.001)
        XCTAssertGreaterThanOrEqual(narrow.side, 44)
        XCTAssertNil(p.railGapOrb(playerWidth: 500, artSide: 400, trailingReserve: 0), "no room: no orb")
        XCTAssertNil(p.railGapOrb(playerWidth: .nan, artSide: 320, trailingReserve: 0))
    }

    // MARK: Card stages

    func testIdleEmberAndStartingOrbSizes() {
        XCTAssertEqual(FoldedArtCardLayers.orbFraction(for: .talking), 0.72)
        XCTAssertEqual(FoldedArtCardLayers.orbFraction(for: .idle), 0.36)
        XCTAssertEqual(FoldedArtCardLayers.orbFraction(for: .starting), 0.52)
        XCTAssertEqual(FoldedArtCardLayers.orbFraction(for: .artwork), 0)
        XCTAssertEqual(FoldedArtCardLayers.startingRingScale, 1.1)
        XCTAssertEqual(FoldedArtCardLayers.startingRingArcFraction, 240.0 / 360.0, accuracy: 1e-9)
        // Smallest default-size art (FoldedStyle.artMinSide 140): the ember is still at least 44 pt.
        XCTAssertGreaterThanOrEqual(140 * FoldedArtCardLayers.orbFraction(for: .idle), 44)
        // Accessibility sizes (art floor 72): the drawn orb never drops under 44 pt or past the card.
        XCTAssertEqual(FoldedArtCardLayers.orbSide(for: .idle, cardSide: 72), 44)
        XCTAssertEqual(FoldedArtCardLayers.orbSide(for: .idle, cardSide: 40), 40)
        XCTAssertEqual(FoldedArtCardLayers.orbSide(for: .starting, cardSide: 300), 156, accuracy: 0.001)
        XCTAssertEqual(FoldedArtCardLayers.orbSide(for: .talking, cardSide: 300), 216, accuracy: 0.001)
        for stage: ArtCardStage in [.idle, .starting] {
            let layers = FoldedArtCardLayers.layers(stage: stage)
            XCTAssertEqual(layers.artworkOpacity, 0, "\(stage)")
            XCTAssertEqual(layers.glowOpacity, 0, "\(stage)")
            XCTAssertFalse(layers.showsOrb, "the lava orb is the talking state only (\(stage))")
        }
    }

    func testStartingRingIsAHeldArcAndClosesUnderReduceMotion() {
        XCTAssertEqual(DJOrbPolicy.startingRingArc(reduceMotion: false), FoldedArtCardLayers.startingRingArcFraction)
        XCTAssertEqual(DJOrbPolicy.startingRingArc(reduceMotion: true), 1, "a complete static circle")
    }

    // MARK: App wiring (source scan; the SwiftUI files only build on iOS CI)

    private func appSource(_ path: String) throws -> String {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testBothReskinCallersUseTheNewContentRule() throws {
        for path in ["AeroDJ/FoldedPlayer.swift", "AeroDJ/PlayingScreen.swift"] {
            let source = try appSource(path)
            XCTAssertTrue(source.contains("FoldedOuterLayout.reskinShows(content)"), path)
            XCTAssertFalse(source.contains("usesOuterReskin(containerWidth: Double(geo.size.width), showsTrack: heroTrack != nil)"), path)
        }
    }

    func testThePlayerReadsTheOrbPresentationAndKeepsTheStartCopy() throws {
        let player = try appSource("AeroDJ/FoldedPlayer.swift")
        XCTAssertTrue(player.contains("OnAirOrbPresentation.resolve("))
        XCTAssertTrue(player.contains("private struct FoldedStartCard: View {"))
        XCTAssertTrue(player.contains("folded.railGapOrb"))
        // The placeholder keeps the copy and ids the UI tests read; only the system spinner goes.
        XCTAssertTrue(player.contains("NowPlayingPlaceholder(content: content, actions: actions, showsSpinner: false)"))
        let placeholder = try appSource("AeroDJ/PlaybackComponents.swift")
        XCTAssertTrue(placeholder.contains("if showsSpinner, content.showsStartSpinner {"))
    }

    // MARK: Colour (Orion, Nov 23: idle and starting take the talking orb's art-derived colour)

    func testIdleAndStartingTakeTheTalkingOrbsArtDerivedColour() {
        let talking = DJOrbFill.source(for: .talking, track: track)
        XCTAssertEqual(talking, .artwork(track), "the talking orb is coloured by the track's art")
        XCTAssertEqual(talking, DJOrbFill.source(track: track))
        for stage: ArtCardStage in [.idle, .starting] {
            XCTAssertEqual(DJOrbFill.source(for: stage, track: track), talking, "\(stage) uses the same source")
        }
    }

    func testNoArtFallsBackToTheTalkingOrbsNeutralFill() {
        XCTAssertEqual(DJOrbFill.source(track: nil), .neutral)
        for stage: ArtCardStage in [.talking, .idle, .starting] {
            XCTAssertEqual(DJOrbFill.source(for: stage, track: nil), .neutral, "\(stage)")
        }
        // The one neutral fallback the talking orb already drew (white 0.55 → 0.28); no new palette.
        XCTAssertEqual(DJOrbFill.neutralWhites, [0.55, 0.28])
        XCTAssertNil(DJOrbFill.source(for: .artwork, track: track), "the art card draws the art, not an orb")
        XCTAssertNil(DJOrbFill.source(for: .cleared, track: track))
    }

    func testBothOrbViewsDrawTheSharedFillAndNoMockupPalette() throws {
        let lava = try appSource("AeroDJ/DJLavaOrb.swift")
        XCTAssertTrue(lava.contains("DJOrbFill.source("), "the talking orb reads the shared source")
        XCTAssertTrue(lava.contains("struct DJOrbArtFill: View"))
        let player = try appSource("AeroDJ/FoldedPlayer.swift")
        let start = try XCTUnwrap(player.range(of: "private struct FoldedStartCard: View {"))
        let end = try XCTUnwrap(player.range(of: "// MARK: - Art card", range: start.upperBound..<player.endIndex))
        let card = String(player[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(card.contains("DJOrbFill.source(for: stage"))
        XCTAssertTrue(card.contains("DJOrbArtFill("))
        for token in ["0x8C", "0x5A", "0x2A", "0xF8", "0xE0", "0xC4", "0x7A", "0xF0", "Color(red:"] {
            XCTAssertFalse(card.contains(token), "no fixed mockup colour (\(token))")
        }
    }
}

