import XCTest
@testable import AeroDJCore

// Owner, Nov 9 2026: while the DJ talks, the album art disappears completely and only the orb
// shows; the art returns when the song plays. -Fry
final class FoldedArtCardLayersTests: XCTestCase {
    func testOnAirShowsOnlyTheOrb() {
        let onAir = FoldedArtCardLayers.layers(isOnAir: true)
        XCTAssertEqual(onAir.artworkOpacity, 0, "no dimmed art behind the orb")
        XCTAssertEqual(onAir.glowOpacity, 0, "no art glow either")
        XCTAssertTrue(onAir.showsOrb)
    }

    func testSongPlayingShowsTheArtAndNoOrb() {
        let playing = FoldedArtCardLayers.layers(isOnAir: false)
        XCTAssertEqual(playing.artworkOpacity, 1)
        XCTAssertEqual(playing.glowOpacity, 0.5, "the art glow is unchanged while a song plays")
        XCTAssertFalse(playing.showsOrb)
    }

    func testShortCrossfadeAndUnchangedOrbSize() {
        XCTAssertGreaterThan(FoldedArtCardLayers.crossfadeSeconds, 0)
        XCTAssertLessThanOrEqual(FoldedArtCardLayers.crossfadeSeconds, 0.5)
        XCTAssertEqual(FoldedArtCardLayers.orbFraction, 0.72)
    }

    /// Source scan of the app's art card: it reads `FoldedArtCardLayers`, keeps one fixed frame,
    /// and no longer draws dimmed art or frosted glass on air.
    func testFoldedArtCardUsesTheLayersAndKeepsItsFrame() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: iosRoot.appendingPathComponent("AeroDJ/FoldedPlayer.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct FoldedArtCard: View {"))
        let end = try XCTUnwrap(source.range(of: "// MARK: - Title", range: start.upperBound..<source.endIndex))
        let card = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(card.contains("FoldedArtCardLayers"))
        XCTAssertTrue(card.contains(".frame(width: side, height: side)"))
        XCTAssertTrue(card.contains(".animation(.easeInOut(duration: FoldedArtCardLayers.crossfadeSeconds), value: isOnAir)"))
        XCTAssertFalse(card.contains(".opacity(0.18)"), "the dimmed on-air art is gone")
        XCTAssertFalse(card.contains("foldedGlass"), "the on-air frosted glass is gone")
    }
}
