import XCTest
@testable import AeroDJCore

/// DJ personality → words (Echo, build 27). Warm stays the default; the tone is chosen only
/// through `DJScriptWriter`'s phrase bank.
final class DJToneTests: XCTestCase {
    func testDefaultPersonalityAndWriterSpeakWarm() {
        XCTAssertEqual(StationConfiguration().personality, .warm)
        XCTAssertEqual(StationConfiguration().personality.editorialTone, .warm)
        XCTAssertEqual(DJScriptWriter(seed: 1).tone, .warm)
    }

    func testEachPersonalityMapsToItsTone() {
        let expected: [DJPersonality: EditorialTone] = [
            .warm: .warm, .upbeat: .classic, .laidBack: .lateNight, .minimal: .warm,
        ]
        XCTAssertEqual(Set(expected.keys), Set(DJPersonality.allCases), "every personality is mapped")
        for p in DJPersonality.allCases {
            XCTAssertEqual(p.editorialTone, expected[p], "\(p)")
        }
        XCTAssertNotEqual(EditorialTone.classic, .warm)
        XCTAssertNotEqual(EditorialTone.lateNight, .warm)
        XCTAssertNotEqual(EditorialTone.classic, .lateNight)
        // Minimal keeps its shorter cap; the words are warm's.
        XCTAssertEqual(StationConfiguration(personality: .minimal).cadence().maxTransitionSeconds, 6)
    }

    func testSwitchingToneKeepsWhereBreaksFallAndOnlyChangesTheWords() {
        let tracks = djTracks(30)
        var warm = DJScriptWriter(cadence: .init(talkFraction: 0.5, minSongsBetweenBreaks: 1), seed: 9)
        var switched = DJScriptWriter(cadence: .init(talkFraction: 0.5, minSongsBetweenBreaks: 1), seed: 9)
        switched.use(tone: .lateNight)
        XCTAssertEqual(switched.tone, .lateNight)
        let a = warm.plan(tracks: tracks, briefing: nil, hour: 10)
        let b = switched.plan(tracks: tracks, briefing: nil, hour: 10)
        XCTAssertEqual(a.breaks.map(\.afterTrack), b.breaks.map(\.afterTrack), "tone never moves breaks")
        let lateLines = Set(EditorialTone.lateNight.allLines.filter { !$0.contains("{") })
        let warmLines = Set(EditorialTone.warm.allLines.filter { !$0.contains("{") })
        let spoken = b.breaks.flatMap(\.cues).map(\.text)
        XCTAssertFalse(spoken.contains { warmLines.contains($0) }, "no warm words after the switch")
        XCTAssertTrue(spoken.contains { lateLines.contains($0) }, "late-night words are used")
        for djBreak in b.breaks {
            let next = tracks[djBreak.afterTrack + 1]
            XCTAssertTrue(EditorialTone.lateNight.closing.contains {
                TemplatePool.fill($0, ["nextTitle": next.title, "nextArtist": next.artist]) == djBreak.cues.last!.text
            }, djBreak.cues.last!.text)
        }
        // Same tone again is a no-op: pools keep cycling instead of restarting.
        var same = DJScriptWriter(seed: 2)
        same.use(tone: .warm)
        XCTAssertEqual(same.tone, .warm)
    }

    func testOneGreetingPerSessionSurvivesAToneSwitch() {
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 3)
        _ = writer.plan(tracks: djTracks(6), briefing: nil, hour: 9)
        writer.use(tone: .classic)
        let later = writer.plan(tracks: djTracks(6), briefing: nil, hour: 9)
        let greetings = Set(EditorialTone.classic.greetings.values.joined())
        XCTAssertFalse(later.breaks.flatMap(\.cues).contains { greetings.contains($0.text) }, "greeted once already")
    }
}
