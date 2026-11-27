import XCTest
@testable import AeroDJCore

/// Release logs carry the session's real skip reason, not a blanket `notPlanned`.
final class SkipReasonLogTests: XCTestCase {
    func testNoBreakLogsTheSessionsOwnReason() {
        for reason in [DJBreakSkipReason.notReadyAtBoundary, .cancelled, .timedOut, .renderFailed,
                       .overBreakBudget, .sourceRevoked, .interrupted] {
            XCTAssertEqual(PlaybackLog.noBreakReason((reason, true)), reason)
            XCTAssertEqual(PlaybackLog.breakSkipped(after: 0, reason: PlaybackLog.noBreakReason((reason, false))),
                           "break skipped after=0 reason=\(reason.rawValue)")
        }
    }

    func testNoRecordedReasonIsNotPlanned() {
        XCTAssertEqual(PlaybackLog.noBreakReason(nil), .notPlanned)
    }

    func testHandedOutSkipsMapToFixedReasons() {
        XCTAssertEqual(PlaybackLog.handedOutReason(.emptyLine), .renderFailed)
        XCTAssertEqual(PlaybackLog.handedOutReason(.decodeFailed), .renderFailed)
        XCTAssertEqual(PlaybackLog.handedOutReason(.notPlayable), .notPlanned)
    }

    /// PlayerView must not hard-code `.notPlanned` when it logs a skipped break.
    func testPlayerViewLogsTheRealReason() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/PlayerView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("logBreakSkipped(after: finishedIndex, reason: .notPlanned)"))
        XCTAssertTrue(source.contains("PlaybackLog.noBreakReason(djSession.lastNoBreak)"))
        XCTAssertTrue(source.contains("PlaybackLog.handedOutReason(reason)"))
    }

    /// Echo's #304 finding: TalkoverCoordinator's gap break with an empty line or no clips used
    /// to skip the interlude without a log line. It now logs `.renderFailed`, the same reason
    /// PlayerView's handed-out path logs for `.emptyLine`, before the skip.
    func testTalkoverEmptyBreakLogsTheSkipBeforeSkipping() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/TalkoverCoordinator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let open = try XCTUnwrap(source.range(of: "guard !line.isEmpty, !clips.isEmpty else {"),
                                 "the empty-break guard moved")
        let close = try XCTUnwrap(source.range(of: "return", range: open.upperBound..<source.endIndex))
        let block = String(source[open.upperBound..<close.lowerBound])
        let log = try XCTUnwrap(block.range(of: "music.logBreakSkipped(after: k, reason: PlaybackLog.handedOutReason(.emptyLine))"),
                                "the empty break is logged")
        let skip = try XCTUnwrap(block.range(of: "music.skipInterlude()"))
        XCTAssertLessThan(log.lowerBound, skip.lowerBound, "logged before the interlude is skipped")
        XCTAssertTrue(block.contains("djSession.playbackFailed(afterTrack: k)"))
        XCTAssertEqual(PlaybackLog.handedOutReason(.emptyLine), .renderFailed)
    }

    // MARK: - #304 R3: nil or non-positive song duration logs .durationUnknown

    func testSongStartSkipReasonFlagsMissingOrInvalidDuration() {
        XCTAssertEqual(PlaybackLog.songStartSkipReason(duration: nil), .durationUnknown)
        XCTAssertEqual(PlaybackLog.songStartSkipReason(duration: 0), .durationUnknown)
        XCTAssertEqual(PlaybackLog.songStartSkipReason(duration: -12), .durationUnknown)
        XCTAssertEqual(PlaybackLog.songStartSkipReason(duration: .nan), .durationUnknown)
        XCTAssertEqual(PlaybackLog.songStartSkipReason(duration: .infinity), .durationUnknown)
        XCTAssertNil(PlaybackLog.songStartSkipReason(duration: 185.0))
        XCTAssertEqual(PlaybackLog.breakSkipped(after: 2, reason: .durationUnknown),
                       "break skipped after=2 reason=durationUnknown")
    }

    func testDurationUnknownSkipStaysQuietInPresentationState() {
        var presentation = DJPresentationModel()
        let state = presentation.apply(.breakSkipped(afterTrack: 2, .durationUnknown))
        XCTAssertEqual(state, .idle)
    }

    /// PlayerView logs `.durationUnknown` when `onSongStarted` receives no usable duration
    /// and captures `music` weakly to avoid a retain cycle on `music.onSongStarted`.
    func testPlayerViewLogsNilDurationSkip() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/PlayerView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("music.onSongStarted = { [djSession, talkover, weak music]"))
        XCTAssertTrue(source.contains("PlaybackLog.songStartSkipReason(duration: duration)"))
        XCTAssertTrue(source.contains("music?.logBreakSkipped(after: index, reason: skip)"))
    }
}
