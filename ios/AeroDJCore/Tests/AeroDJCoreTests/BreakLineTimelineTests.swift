import XCTest
@testable import AeroDJCore

/// #377 (-Fry): a system interruption during a DJ break pauses the line clock. The next line
/// does not start, one acknowledgement plays, and the script resumes at the interrupted line.
/// Linux green is not device evidence.
final class BreakLineTimelineTests: XCTestCase {
    private func speaking(at line: Int, kind: BreakInterruptionKind = .boundary) -> BreakLineTimeline {
        var timeline = BreakLineTimeline()
        let seconds = Array(repeating: 5.0, count: line + 2)
        timeline.start(lineSeconds: seconds, kind: kind, at: 0)
        if line > 0 {
            timeline.advance(to: Double(line) * 5)
        }
        return timeline
    }

    func testBeganPausesTheTimelineSoTheNextLineDoesNotStart() {
        var timeline = speaking(at: 1)
        XCTAssertEqual(timeline.events, [.scriptLine(0), .scriptLine(1)])
        XCTAssertTrue(timeline.timerArmed)
        XCTAssertEqual(timeline.began(at: 6), .pause(line: 1))
        XCTAssertEqual(timeline.phase, .paused(line: 1))
        XCTAssertTrue(timeline.isHolding)
        XCTAssertFalse(timeline.timerArmed, "the line timer is disarmed")
        let paused = timeline.events
        timeline.advance(to: 100)
        XCTAssertEqual(timeline.events, paused, "a due line does not start while the break is paused")
        XCTAssertFalse(timeline.events.contains(.scriptLine(2)))
        XCTAssertEqual(
            BreakTimelineStopPolicy.untaggedInterruption(.pause(line: 1), isHolding: timeline.isHolding),
            .apply,
            "the untagged interruption stop pauses; it does not halt"
        )
    }

    func testEndedWithShouldResumePlaysOneAcknowledgementThenResumesAtTheInterruptedLine() {
        var timeline = speaking(at: 1)
        timeline.began(at: 6)
        XCTAssertEqual(timeline.ended(shouldResume: true, acknowledgementReady: true, at: 16),
                       .playAcknowledgement(thenLine: 1))
        XCTAssertEqual(timeline.phase, .acknowledging(resumeLine: 1))
        XCTAssertEqual(timeline.events.filter { $0 == .acknowledgement }.count, 1)
        // The acknowledgement's estimated length is 2 s. Finishing it restarts line 1, not line 0.
        timeline.advance(to: 18)
        XCTAssertEqual(timeline.events, [
            .scriptLine(0), .scriptLine(1), .acknowledgement, .scriptLine(1)
        ])
        XCTAssertEqual(timeline.phase, .speaking(line: 1))
        XCTAssertFalse(timeline.events.contains(.scriptLine(2)), "the line after the interrupted one waits its turn")
    }

    func testEndedWithoutShouldResumeStaysPaused() {
        var timeline = speaking(at: 1)
        timeline.began(at: 6)
        XCTAssertEqual(timeline.ended(shouldResume: false, acknowledgementReady: true, at: 16),
                       .stayPaused(line: 1))
        XCTAssertEqual(timeline.phase, .held(line: 1))
        XCTAssertTrue(timeline.isHolding)
        XCTAssertFalse(timeline.timerArmed)
        let held = timeline.events
        timeline.advance(to: 100)
        XCTAssertEqual(timeline.events, held)
        XCTAssertFalse(timeline.events.contains(.acknowledgement))
        XCTAssertEqual(timeline.ended(shouldResume: true, acknowledgementReady: true, at: 20), .none,
                       "a later end does not restart a held break")
        XCTAssertEqual(timeline.began(at: 21), .none)
        XCTAssertEqual(timeline.phase, .held(line: 1))
    }

    func testDuplicateBeganAndEndedAreNoOps() {
        var timeline = speaking(at: 1)
        XCTAssertEqual(timeline.began(at: 6), .pause(line: 1))
        XCTAssertEqual(timeline.began(at: 7), .none)
        XCTAssertEqual(timeline.phase, .paused(line: 1))
        XCTAssertEqual(
            BreakTimelineStopPolicy.untaggedInterruption(.none, isHolding: timeline.isHolding),
            .ignore,
            "a second .began does not pause again and does not halt"
        )
        let paused = timeline.events
        timeline.advance(to: 50)
        XCTAssertEqual(timeline.events, paused)
        XCTAssertEqual(timeline.ended(shouldResume: true, acknowledgementReady: true, at: 16),
                       .playAcknowledgement(thenLine: 1))
        XCTAssertEqual(timeline.ended(shouldResume: true, acknowledgementReady: true, at: 17), .none)
        XCTAssertEqual(timeline.ended(shouldResume: false, acknowledgementReady: true, at: 17), .none)
        XCTAssertEqual(timeline.events.filter { $0 == .acknowledgement }.count, 1)
        XCTAssertEqual(timeline.phase, .acknowledging(resumeLine: 1))
    }

    func testInterruptionDuringTheAcknowledgementKeepsTheOwedLine() {
        var timeline = speaking(at: 1)
        timeline.began(at: 6)
        timeline.ended(shouldResume: true, acknowledgementReady: true, at: 16)
        XCTAssertEqual(timeline.began(at: 17), .pause(line: 1))
        XCTAssertEqual(timeline.phase, .paused(line: 1))
        XCTAssertFalse(timeline.timerArmed)
        timeline.advance(to: 80)
        XCTAssertEqual(timeline.events.filter { $0 == .acknowledgement }.count, 1, "the acknowledgement is not replayed")
        XCTAssertFalse(timeline.events.contains(.scriptLine(2)))
        XCTAssertEqual(timeline.ended(shouldResume: true, acknowledgementReady: true, at: 30), .resume(fromLine: 1))
        XCTAssertEqual(timeline.events.filter { $0 == .acknowledgement }.count, 1)
        XCTAssertEqual(timeline.events.last, .scriptLine(1))
        XCTAssertEqual(timeline.phase, .speaking(line: 1))
    }

    func testInterruptionWithNoBreakOnAirIsANoOp() {
        var timeline = BreakLineTimeline()
        XCTAssertEqual(timeline.began(at: 0), .none)
        XCTAssertEqual(timeline.ended(shouldResume: true, acknowledgementReady: true, at: 10), .none)
        XCTAssertEqual(timeline.ended(shouldResume: false, acknowledgementReady: true, at: 10), .none)
        XCTAssertEqual(timeline.phase, .idle)
        XCTAssertFalse(timeline.isHolding)
        XCTAssertFalse(timeline.timerArmed)
        XCTAssertTrue(timeline.events.isEmpty)
        timeline.advance(to: 100)
        XCTAssertTrue(timeline.events.isEmpty)
    }

    func testInterruptionDuringTalkoverStopsAndDoesNotReplay() {
        var timeline = speaking(at: 0, kind: .talkover)
        XCTAssertEqual(timeline.began(at: 1), .stopTalkover)
        XCTAssertEqual(timeline.phase, .idle)
        XCTAssertFalse(timeline.timerArmed)
        XCTAssertEqual(
            BreakTimelineStopPolicy.untaggedInterruption(.stopTalkover, isHolding: false),
            .halt
        )
        timeline.advance(to: 100)
        XCTAssertEqual(timeline.events, [.scriptLine(0)], "the next talk-over line does not start")
        XCTAssertEqual(timeline.ended(shouldResume: true, acknowledgementReady: true, at: 20), .none)
        XCTAssertFalse(timeline.events.contains(.acknowledgement))
        XCTAssertEqual(timeline.began(at: 21), .none)
    }

    func testTheMixableSessionCategoryIsUnchanged() {
        XCTAssertTrue(AppAudioSessionConfig.mixesWithOthers)
    }

    /// The app target does not build on Linux. This pins the pause path the issue named:
    /// `performSessionStep` still reports `.interruption`, and the adapter applies the pause
    /// policy before any halt.
    func testTheAdapterPausesOnAnUntaggedInterruptionInsteadOfHalting() throws {
        let music = try appSource("MusicKitService.swift")
        XCTAssertTrue(music.contains("stopReason = .interruption"))
        XCTAssertTrue(music.contains("onBreakMustStop?(stopReason)"))
        let adapter = try appSource("InterludePlaybackAdapter.swift")
        let stop = try body(adapter, "nonisolated func stopCurrentInterlude(reason: InterludeStopReason, afterTrack: Int? = nil)")
        let take = try XCTUnwrap(stop.range(of: "self.systemInterruptionStop()"))
        let halt = try XCTUnwrap(stop.range(of: "self.haltAudio()"))
        XCTAssertLessThan(take.lowerBound, halt.lowerBound, "a speaking break is classified before any halt")
        let forwarded = try body(adapter, "private func systemInterruptionStop() -> Bool")
        XCTAssertTrue(forwarded.contains("BreakTimelineStopPolicy.untaggedInterruption"))
        XCTAssertTrue(forwarded.contains("applyInterruption(action)"))
        let pause = try body(adapter, "private func pauseForInterruption(line: Int)")
        XCTAssertTrue(pause.contains("timeout?.cancel()"))
        XCTAssertTrue(pause.contains("clipPlayer?.pause()"))
        XCTAssertTrue(pause.contains("queue = []"))
        XCTAssertFalse(pause.contains("startNextClip"), "pausing does not start the next line")
        let finished = try body(adapter, "private func clipFinished(successful: Bool)")
        let hold = try XCTUnwrap(finished.range(of: "guard !interruption.isHolding else { return }"))
        let next = try XCTUnwrap(finished.range(of: "startNextClip()"))
        XCTAssertLessThan(hold.lowerBound, next.lowerBound, "a held break does not start the next line")
    }

    private func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text between `signature`'s opening brace and its matching closing brace.
    private func body(_ source: String, _ signature: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "missing \(signature)")
        let open = try XCTUnwrap(source.range(of: "{", range: start.upperBound..<source.endIndex))
        var depth = 1
        var i = open.upperBound
        while i < source.endIndex {
            let c = source[i]
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { break } }
            i = source.index(after: i)
        }
        return String(source[open.upperBound..<i])
    }
}
