import XCTest
@testable import AeroDJCore

// Build 39 review follow-ups (-Fry): Echo's #410 nit 2 (an abandoned hand-out drops its mark)
// and Sentinel's #410 n8 (the weather mark is keyed on the kind).

// MARK: Echo's #410 nit 2: the attribution stage

final class FactAttributionStageTests: XCTestCase {
    private let weatherLine: [FactAttributionMark?] = [nil, .appleWeather]

    func testAStagedMarkShowsOnItsLineOnly() {
        var stage = FactAttributionStage()
        stage.stage(weatherLine, afterTrack: 3)
        stage.lineStarted(0, of: 2, afterTrack: 3)
        XCTAssertNil(stage.shown)
        stage.lineStarted(1, of: 2, afterTrack: 3)
        XCTAssertEqual(stage.shown, .appleWeather)
        stage.lineStarted(1, of: 3, afterTrack: 3)
        XCTAssertNil(stage.shown, "a count mismatch shows nothing")
        stage.lineStarted(1, of: 2, afterTrack: 4)
        XCTAssertNil(stage.shown, "another break's stage shows nothing")
        stage.stage([nil, nil], afterTrack: 3)
        XCTAssertNil(stage.stagedTrack, "a break with no marks stages nothing")
    }

    /// The hand-out is abandoned before the break starts: its stage goes, so a later break for
    /// the same track (re-planned without the weather line) can never show the Apple mark.
    func testAnAbandonedHandOutDropsItsStage() {
        var stage = FactAttributionStage()
        stage.stage(weatherLine, afterTrack: 3)
        stage.handOutAbandoned(afterTrack: 3, speakingTrack: nil)
        XCTAssertNil(stage.stagedTrack)
        stage.lineStarted(1, of: 2, afterTrack: 3)
        XCTAssertNil(stage.shown, "no stale mark")
    }

    /// Abandoned with the mark already on screen and nothing speaking: the mark goes too.
    func testAnAbandonWithNothingSpeakingClearsTheShownMark() {
        var stage = FactAttributionStage()
        stage.stage(weatherLine, afterTrack: 3)
        stage.lineStarted(1, of: 2, afterTrack: 3)
        stage.handOutAbandoned(afterTrack: nil, speakingTrack: nil)
        XCTAssertNil(stage.shown)
    }

    /// The talk-over path stages the next break while one is on air: abandoning that hand-out
    /// keeps the on-air break's mark and its stage.
    func testAnAbandonWhileABreakSpeaksKeepsThatBreaksMark() {
        var stage = FactAttributionStage()
        stage.stage(weatherLine, afterTrack: 3)
        stage.lineStarted(1, of: 2, afterTrack: 3)
        stage.handOutAbandoned(afterTrack: 4, speakingTrack: 3)
        XCTAssertEqual(stage.shown, .appleWeather)
        XCTAssertEqual(stage.stagedTrack, 3)
        stage.handOutAbandoned(afterTrack: 3, speakingTrack: 3)
        XCTAssertEqual(stage.stagedTrack, 3, "the speaking break's own stage stays")
    }

    func testABreakThatWillNotPlayDropsItsStage() {
        var stage = FactAttributionStage()
        stage.stage(weatherLine, afterTrack: 5)
        stage.breakNotPlayed(afterTrack: 5, whileAnotherSpeaks: false)
        XCTAssertNil(stage.stagedTrack)
        stage.lineStarted(1, of: 2, afterTrack: 5)
        XCTAssertNil(stage.shown)

        stage.stage(weatherLine, afterTrack: 5)
        stage.lineStarted(1, of: 2, afterTrack: 5)
        stage.breakNotPlayed(afterTrack: 6, whileAnotherSpeaks: true)
        XCTAssertEqual(stage.shown, .appleWeather, "another break on air keeps its mark")
        stage.breakNotPlayed(afterTrack: 6, whileAnotherSpeaks: false)
        XCTAssertNil(stage.shown)
    }

    func testTheBreakEndingClearsEverything() {
        var stage = FactAttributionStage()
        stage.stage(weatherLine, afterTrack: 3)
        stage.lineStarted(1, of: 2, afterTrack: 3)
        stage.breakEnded()
        XCTAssertNil(stage.shown)
        XCTAssertNil(stage.stagedTrack)
    }

    func testHandedOutTrackIsOnlyTheHandedOutPhase() {
        var stop = PendingPlayStop()
        XCTAssertNil(stop.handedOutTrack)
        stop.handOut(afterTrack: 7)
        XCTAssertEqual(stop.handedOutTrack, 7)
        stop.abandonHandOut()
        XCTAssertNil(stop.handedOutTrack)
        stop.handOut(afterTrack: 8)
        _ = stop.begin(afterTrack: 8, mayAutoResume: false)
        XCTAssertNil(stop.handedOutTrack, "begun: no longer a hand-out to abandon")
    }

    // App wiring (source checks; the app target does not build on Linux).

    func testThePlayerRoutesEveryAbandonAndEndThroughTheStage() throws {
        let adapter = try appSource("InterludePlaybackAdapter.swift")
        XCTAssertFalse(adapter.contains("stagedMarks"), "one stage, in core")
        let abandon = try body(adapter, "    func abandonHandOut() {")
        XCTAssertTrue(abandon.contains("pendingPlay.handedOutTrack"))
        XCTAssertTrue(abandon.contains("attribution.handOutAbandoned("), "Echo's nit 2: the abandon clears the stage")
        let unplayed = try body(adapter, "private func abandonUnplayedBreak(")
        XCTAssertTrue(unplayed.contains("attribution.breakNotPlayed("))
        let cancelled = try body(adapter, "private func cancelledPendingPlay(")
        XCTAssertTrue(cancelled.contains("attribution.breakNotPlayed("))
        let finish = try body(adapter, "func finishBreak(")
        XCTAssertTrue(finish.contains("attribution.breakEnded()"))
        let show = try body(adapter, "private func showAttributionMark(")
        XCTAssertTrue(show.contains("attribution.lineStarted("))
    }
}

// MARK: Sentinel's #410 n8: the weather mark is keyed on the kind

final class FactAttributionMarkKindTests: XCTestCase {
    func testAWeatherFactKeepsTheAppleMarkWhateverItsProvider() {
        let gdeltWeather = FactProvenance.make(kind: .weather, id: UUID(), provider: FactAttribution.gdeltProviderID)
        XCTAssertEqual(FactAttributionMark.mark(forProvenance: gdeltWeather), .appleWeather,
                       "the WeatherKit mark is a display requirement; no provider ID displaces it")
        let gdeltNews = FactProvenance.make(kind: .news, id: UUID(), provider: FactAttribution.gdeltProviderID)
        XCTAssertEqual(FactAttributionMark.mark(forProvenance: gdeltNews), .gdelt)
    }
}

// MARK: Helpers

private func appSource(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

/// From `marker` to the first line that closes a member at four spaces of indent.
private func body(_ source: String, _ marker: String) throws -> String {
    let start = try XCTUnwrap(source.range(of: marker), "missing \(marker)")
    let rest = source[start.lowerBound...]
    let end = try XCTUnwrap(rest.range(of: "\n    }\n") ?? rest.range(of: "\n}\n"), "no end for \(marker)")
    return String(rest[..<end.upperBound])
}
