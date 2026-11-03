import XCTest
@testable import AeroDJCore

/// #388 (-Nova): a never while the DJ talks over the music. Decisions by song ID from each cue's
/// `SpokenAttribution.trackMetadata` only (Echo). Fictional titles; none of them may reach a trace row.
final class StationRatingTalkoverTests: XCTestCase {
    private let never = "cat-quill"
    private let other = "cat-tangle"

    private func cue(_ text: String, briefing: Bool = false, id: UUID = UUID()) -> NarrationCue {
        NarrationCue(id: id, order: 0, group: 0, kind: .transition, text: text, estimatedSeconds: 2, maxSeconds: 8,
                     sourceItemID: briefing ? UUID() : nil, source: briefing ? .calendar : nil,
                     provenance: briefing ? "Calendar" : nil)
    }

    private func clip(_ c: NarrationCue, _ seconds: Double = 2) -> RenderedClip {
        RenderedClip(cueID: c.id, audio: CachedAudio(data: Data([1]), seconds: seconds, providerID: "device", voiceID: "v"),
                     cacheKey: "k", attempts: [])
    }

    private func timeCheck(cueID: UUID) -> DJPlannedTimeCheck {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return DJPlannedTimeCheck(cueID: cueID, plannedAt: Date(timeIntervalSince1970: 0),
                                  templates: [.on: "It's {time}."], calendar: calendar, style: .twelveHour)
    }

    /// "That was Quillfeather Avenue." / briefing / "It's 9:45." / connector / "Up next, Tanglewick Harbour."
    private func sampleBreak() -> (PreparedDJBreak, [NarrationCue]) {
        let back = cue("That was Quillfeather Avenue by Marrow Juniper.")
        let brief = cue("Your calendar has a dentist visit at four.", briefing: true)
        let time = cue("It's 9:45.")
        let connector = cue("Stay with me.")
        let intro = cue("Up next, Tanglewick Harbour by Osric Velle.")
        let cues = [back, brief, time, connector, intro]
        var prepared = PreparedDJBreak(
            afterTrack: 3, cues: cues, clips: cues.map { clip($0) },
            attributions: [back.id: .trackMetadata(trackIDs: [never]),
                           brief.id: .personalContext(itemID: brief.sourceItemID!, source: .calendar, provenance: "Calendar"),
                           time.id: .presenter, connector.id: .presenter,
                           intro.id: .trackMetadata(trackIDs: [other])],
            talkOverCueID: intro.id)
        prepared.timeCheck = timeCheck(cueID: time.id)
        prepared.timeCheckAirTime = Date(timeIntervalSince1970: 100)
        return (prepared, cues)
    }

    // MARK: Lines

    func testLinesFollowClipOrderAndCarryOnlyIDsAndTheBriefingFlag() {
        let (prepared, _) = sampleBreak()
        XCTAssertEqual(StationRatingBreakLine.lines(for: prepared), [
            StationRatingBreakLine(trackIDs: [never]), StationRatingBreakLine(isBriefing: true),
            StationRatingBreakLine(), StationRatingBreakLine(), StationRatingBreakLine(trackIDs: [other]),
        ])
        XCTAssertEqual(StationRatingBreakLine.lines(for: prepared).count, BreakResumeLine.lines(for: prepared).count)
    }

    func testTheCombinedLineNamesBothSongs() {
        let line = StationRatingBreakLine(trackIDs: [never, other])
        XCTAssertTrue(line.names([never]))
        XCTAssertTrue(line.names([other]))
        XCTAssertFalse(line.names(["cat-else"]))
        XCTAssertFalse(StationRatingBreakLine(isBriefing: true).names([never]), "a briefing item never names a song")
    }

    // MARK: Narrowing (Echo's #387 N2)

    func testNarrowingDropsOnlyTheCuesThatNameTheSong() throws {
        let (prepared, cues) = sampleBreak()
        let rest = try XCTUnwrap(StationRatingBreakNarrowing.narrowed(prepared, excluding: [never]))
        XCTAssertEqual(rest.cues.map(\.id), cues.dropFirst().map(\.id), "only the back-announce goes")
        XCTAssertEqual(rest.clips.map(\.cueID), cues.dropFirst().map(\.id))
        XCTAssertNil(rest.attributions[cues[0].id])
        XCTAssertEqual(rest.cues.filter(\.isContent).count, 1, "the briefing item is never omitted")
        XCTAssertEqual(rest.timeCheck?.cueID, cues[2].id, "the time check stays, with its air time")
        XCTAssertNotNil(rest.timeCheckAirTime)
        XCTAssertEqual(rest.talkOverCueID, cues[4].id, "the closing survives")
    }

    func testNarrowingTheClosingClearsTheTalkOverHook() throws {
        let (prepared, cues) = sampleBreak()
        let rest = try XCTUnwrap(StationRatingBreakNarrowing.narrowed(prepared, excluding: [other]))
        XCTAssertEqual(rest.cues.map(\.id), Array(cues.prefix(4)).map(\.id))
        XCTAssertNil(rest.talkOverCueID)
        XCTAssertEqual(rest.cues.filter(\.isContent).count, 1)
    }

    func testNarrowingNothingOrEverything() {
        let (prepared, _) = sampleBreak()
        XCTAssertEqual(StationRatingBreakNarrowing.narrowed(prepared, excluding: ["cat-else"]), prepared)
        XCTAssertEqual(StationRatingBreakNarrowing.narrowed(prepared, excluding: []), prepared)
        let only = cue("Up next, Tanglewick Harbour.")
        let lone = PreparedDJBreak(afterTrack: 0, cues: [only], clips: [clip(only)],
                                   attributions: [only.id: .trackMetadata(trackIDs: [other])])
        XCTAssertNil(StationRatingBreakNarrowing.narrowed(lone, excluding: [other]), "nothing left: no break")
    }

    /// Mutation check: a title in the text without the ID in the attribution is NOT matched. The
    /// decision is by ID only (Echo); the completeness test keeps the IDs right.
    func testNarrowingNeverMatchesByTitle() {
        let named = cue("Up next, Tanglewick Harbour.")
        let prepared = PreparedDJBreak(afterTrack: 0, cues: [named], clips: [clip(named)], attributions: [named.id: .presenter])
        XCTAssertEqual(StationRatingBreakNarrowing.narrowed(prepared, excluding: [other]), prepared)
    }

    // MARK: Talk-over cut (Orion's spec)

    private func speaking(_ cut: inout StationRatingTalkoverCut) {
        let (prepared, _) = sampleBreak()
        cut.speechStarted(afterTrack: 3, lines: StationRatingBreakLine.lines(for: prepared),
                          resumeLines: BreakResumeLine.lines(for: prepared))
    }

    func testASpeakingCueThatNamesTheSongFadesAndDropsTheBreak() {
        var cut = StationRatingTalkoverCut()
        speaking(&cut)
        let action = cut.ratingChanged(excluded: [never], speakingLine: 0)
        XCTAssertEqual(action, .fadeAndDropBreak(afterTrack: 3, StationRatingWithdrawnLines(
            line: 0, timeChecks: 1, other: 3, briefing: 1)))
        XCTAssertTrue(cut.faded)
    }

    func testASpeakingCueThatDoesNotNameTheSongPlaysOn() {
        var cut = StationRatingTalkoverCut()
        speaking(&cut)
        // The briefing item is on air; the nevered song is only in the closing.
        XCTAssertEqual(cut.ratingChanged(excluded: [other], speakingLine: 1), .dropQueued(afterTrack: 3, lines: [4]),
                       "the speaking line plays on; only the queued closing that names the song goes")
        XCTAssertFalse(cut.faded)
        XCTAssertEqual(cut.ratingChanged(excluded: [other], speakingLine: 2), .none, "already dropped once")
        // Nothing queued names it either: nothing at all.
        var quiet = StationRatingTalkoverCut()
        speaking(&quiet)
        XCTAssertEqual(quiet.ratingChanged(excluded: [never], speakingLine: 1), .none, "the back-announce already aired")
        XCTAssertEqual(quiet.ratingChanged(excluded: ["cat-else"], speakingLine: 0), .none, "an unrelated song")
    }

    func testTheCutFiresOnce() {
        var cut = StationRatingTalkoverCut()
        speaking(&cut)
        XCTAssertNotEqual(cut.ratingChanged(excluded: [never], speakingLine: 0), .none)
        XCTAssertEqual(cut.ratingChanged(excluded: [never], speakingLine: 0), .none)
        XCTAssertEqual(cut.ratingChanged(excluded: [never, other], speakingLine: 4), .none)
    }

    func testNothingWhenNotSpeakingOrAlreadyStopped() {
        var cut = StationRatingTalkoverCut()
        XCTAssertEqual(cut.ratingChanged(excluded: [never], speakingLine: 0), .none, "no talk-over started")
        speaking(&cut)
        // An interruption already stopped the voice: the adapter reports no speaking line.
        XCTAssertEqual(cut.ratingChanged(excluded: [never], speakingLine: nil), .none)
        XCTAssertEqual(cut.ratingChanged(excluded: [never], speakingLine: 9), .none, "out of range fails quiet")
        cut.speechEnded()
        XCTAssertEqual(cut.ratingChanged(excluded: [never], speakingLine: 0), .none, "the voice ended")
        XCTAssertEqual(cut, StationRatingTalkoverCut())
    }

    func testTheFadedLineCountsOnlyLinesNotAlreadyDropped() {
        var cut = StationRatingTalkoverCut()
        speaking(&cut)
        XCTAssertEqual(cut.ratingChanged(excluded: [other], speakingLine: 0), .dropQueued(afterTrack: 3, lines: [4]))
        XCTAssertEqual(cut.ratingChanged(excluded: [other, never], speakingLine: 0), .fadeAndDropBreak(
            afterTrack: 3, StationRatingWithdrawnLines(line: 0, timeChecks: 1, other: 2, briefing: 1)))
    }

    func testUnknownResumeLinesCountAsOther() {
        var cut = StationRatingTalkoverCut()
        cut.speechStarted(afterTrack: 1, lines: [StationRatingBreakLine(trackIDs: [never]), StationRatingBreakLine()],
                          resumeLines: [])
        XCTAssertEqual(cut.ratingChanged(excluded: [never], speakingLine: 0),
                       .fadeAndDropBreak(afterTrack: 1, StationRatingWithdrawnLines(line: 0, timeChecks: 0, other: 2)))
    }

    // MARK: Paused gap break (gate narrowed by N2)

    func testTheGateWithdrawsOnlyABreakThatNamesTheSong() {
        let (prepared, _) = sampleBreak()
        let lines = StationRatingBreakLine.lines(for: prepared)
        var gate = StationRatingResumeGate()
        gate.breakOpened(afterTrack: 3, lines: lines)
        XCTAssertFalse(gate.boundaryDropped(afterTrack: 3, excluding: ["cat-else"]))
        XCTAssertTrue(gate.mayResume, "no line names the song: it resumes")
        XCTAssertTrue(gate.boundaryDropped(afterTrack: 3, excluding: [never]))
        XCTAssertFalse(gate.mayResume)
        gate.breakClosed()
        XCTAssertEqual(gate.openLines, [])

        var unknown = StationRatingResumeGate()
        unknown.breakOpened(afterTrack: 3)
        XCTAssertTrue(unknown.boundaryDropped(afterTrack: 3, excluding: ["cat-else"]), "unknown lines: withdrawn, as before")
        var old = StationRatingResumeGate()
        old.breakOpened(afterTrack: 3, lines: lines)
        XCTAssertTrue(old.boundaryDropped(afterTrack: 3), "no song set: the old drop")
        XCTAssertFalse(old.boundaryDropped(afterTrack: 2, excluding: [never]), "another boundary")
    }

    // MARK: Withdrawn counts (Echo's nit)

    func testBriefingItemsCountApartFromOtherLines() {
        let (prepared, _) = sampleBreak()
        let w = StationRatingWithdrawnLines.remaining(BreakResumeLine.lines(for: prepared), from: 1,
                                                      ratingLines: StationRatingBreakLine.lines(for: prepared))
        XCTAssertEqual(w, StationRatingWithdrawnLines(line: 1, timeChecks: 1, other: 2, briefing: 1))
        XCTAssertEqual(w.count, 4)
        let unknown = StationRatingWithdrawnLines.remaining(BreakResumeLine.lines(for: prepared), from: 1)
        XCTAssertEqual(unknown, StationRatingWithdrawnLines(line: 1, timeChecks: 1, other: 3, briefing: 0))
    }

    #if DEBUG || AERODJ_P0_DIAG
    func testTheRatedNeverRowIsCodesAndCountsOnly() {
        var trace = P0EventTrace()
        var cut = StationRatingTalkoverCut()
        speaking(&cut)
        guard case .fadeAndDropBreak(let k, let dropped) = cut.ratingChanged(excluded: [never], speakingLine: 0) else {
            return XCTFail("fires")
        }
        let row = trace.talkoverRatedNever(dropped, afterTrack: k, at: 5)
        XCTAssertEqual(row.event, .breakInterruption)
        XCTAssertEqual(row.detail, "kind=breakDropped reason=ratedNever after=3 line=0 dropped=5 timeChecks=1 otherCues=3 briefingCues=1")
        let codes = Set(P0TraceCode.allCases.map(\.rawValue))
        for pair in row.detail.split(separator: " ") {
            let value = String(pair.split(separator: "=", maxSplits: 1)[1])
            XCTAssertTrue(Int(value) != nil || value == "-" || codes.contains(value), "\(pair) is a number or a code")
        }
        for fixture in ["Quillfeather", "Marrow", "Tanglewick", "Osric", never, other, "never", "dentist", "Calendar"] {
            XCTAssertFalse(row.detail.contains(fixture), "no song, title, artist, rating or briefing text: \(fixture)")
        }
    }
    #endif
}
