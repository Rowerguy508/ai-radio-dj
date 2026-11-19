#if DEBUG || AERODJ_P0_DIAG
import Foundation
import XCTest
@testable import AeroDJCore

/// #526 S0b (-Echo): DIAG-only AirPlay gap-break handoff row. Pure assembly: codes,
/// milliseconds and outputLatency only. Not device evidence.
final class AirPlayGapHandoffTraceTests: XCTestCase {

    // MARK: Row assembly

    /// A complete handoff: song end is t=0; later steps are milliseconds on the same clock.
    func testCompleteHandoffRowUsesRelativeMillisecondsOnOneClock() throws {
        var trace = AirPlayGapHandoffTrace()
        XCTAssertNil(trace.begin(afterTrack: 3, outputLatency: 0.18, at: 10.000))
        XCTAssertNil(trace.mark(.firstPlay, outputLatency: 0.184, at: 10.042))
        XCTAssertNil(trace.mark(.lastFinish, at: 11.850))
        XCTAssertNil(trace.mark(.sessionOff, at: 11.855))
        XCTAssertNil(trace.mark(.nextPlay, at: 11.902))
        let row = try XCTUnwrap(trace.mark(.musicPlaying, at: 12.010))
        XCTAssertEqual(row.afterTrack, 3)
        XCTAssertEqual(row.outcome, .complete)
        XCTAssertEqual(row.milliseconds[.songEnd], 0)
        XCTAssertEqual(row.milliseconds[.firstPlay], 42)
        XCTAssertEqual(row.milliseconds[.lastFinish], 1850)
        XCTAssertEqual(row.milliseconds[.sessionOff], 1855)
        XCTAssertEqual(row.milliseconds[.nextPlay], 1902)
        XCTAssertEqual(row.milliseconds[.musicPlaying], 2010)
        XCTAssertEqual(row.outputLatencyMs, 184, "a later valid latency (at first play) replaces the earlier one")
        XCTAssertTrue(row.missing.isEmpty)
        XCTAssertEqual(row.detail,
                       "kind=handoff after=3 result=complete songEnd=0 firstPlay=42 lastFinish=1850 sessionOff=1855 nextPlay=1902 musicPlaying=2010 latency=184 missing=-")
    }

    /// A skipped break still emits one row; missing steps are listed, never dropped.
    func testSkippedBreakReportsEveryMissingStep() throws {
        var trace = AirPlayGapHandoffTrace()
        _ = trace.begin(afterTrack: 3, outputLatency: 0.18, at: 5)
        trace.note(.skipped)
        XCTAssertNil(trace.mark(.nextPlay, at: 5.080))
        let row = try XCTUnwrap(trace.mark(.musicPlaying, at: 5.200))
        XCTAssertEqual(row.outcome, .skipped)
        XCTAssertEqual(row.missing, [.firstPlay, .lastFinish, .sessionOff])
        XCTAssertEqual(row.milliseconds[.songEnd], 0)
        XCTAssertEqual(row.milliseconds[.nextPlay], 80)
        XCTAssertEqual(row.milliseconds[.musicPlaying], 200)
        XCTAssertNil(row.milliseconds[.firstPlay])
        XCTAssertEqual(row.detail,
                       "kind=handoff after=3 result=skipped songEnd=0 firstPlay=- lastFinish=- sessionOff=- nextPlay=80 musicPlaying=200 latency=180 missing=firstPlay+lastFinish+sessionOff")
    }

    /// Timeout: lastFinish is missing and named, later steps still record.
    func testTimeoutReportsMissingLastFinish() throws {
        var trace = AirPlayGapHandoffTrace()
        _ = trace.begin(afterTrack: 1, at: 0)
        _ = trace.mark(.firstPlay, at: 0.040)
        trace.note(.timedOut)
        _ = trace.mark(.sessionOff, at: 2.000)
        _ = trace.mark(.nextPlay, at: 2.050)
        let row = try XCTUnwrap(trace.mark(.musicPlaying, at: 2.200))
        XCTAssertEqual(row.outcome, .timedOut)
        XCTAssertEqual(row.missing, [.lastFinish])
        XCTAssertEqual(row.detail,
                       "kind=handoff after=1 result=timedOut songEnd=0 firstPlay=40 lastFinish=- sessionOff=2000 nextPlay=2050 musicPlaying=2200 latency=- missing=lastFinish")
    }

    /// A failed first `play()` is reported, not dropped; finalize lists the rest.
    func testFailedStartIsReportedOnFinalize() throws {
        var trace = AirPlayGapHandoffTrace()
        _ = trace.begin(afterTrack: 2, at: 1.0)
        trace.note(.failed)
        let row = try XCTUnwrap(trace.finalize())
        XCTAssertEqual(row.outcome, .failed)
        XCTAssertEqual(row.missing, [.firstPlay, .lastFinish, .sessionOff, .nextPlay, .musicPlaying])
        XCTAssertTrue(row.detail.contains("result=failed"))
        XCTAssertTrue(row.detail.contains("missing=firstPlay+lastFinish+sessionOff+nextPlay+musicPlaying"))
    }

    /// First stamp for a step wins; a second mark does not move it.
    func testFirstStampWins() throws {
        var trace = AirPlayGapHandoffTrace()
        _ = trace.begin(afterTrack: 0, at: 0)
        _ = trace.mark(.firstPlay, at: 0.100)
        _ = trace.mark(.firstPlay, at: 0.500)
        _ = trace.mark(.lastFinish, at: 1)
        _ = trace.mark(.sessionOff, at: 1)
        _ = trace.mark(.nextPlay, at: 1)
        let row = try XCTUnwrap(trace.mark(.musicPlaying, at: 1))
        XCTAssertEqual(row.milliseconds[.firstPlay], 100)
    }

    /// The confirmStart `.playing` stamp is kept when beginPoll sees `.playing` later:
    /// one row per start, with the earlier time.
    func testConfirmStartPlayingStampIsKeptWhenThePollStampsLater() throws {
        var trace = P0EventTrace()
        _ = trace.airPlayGapHandoffBegin(afterTrack: 1, at: 0)
        _ = trace.airPlayGapHandoffMark(.firstPlay, at: 0.040)
        _ = trace.airPlayGapHandoffMark(.lastFinish, at: 1.000)
        _ = trace.airPlayGapHandoffMark(.sessionOff, at: 1.005)
        _ = trace.airPlayGapHandoffMark(.nextPlay, at: 1.050)
        let row = try XCTUnwrap(trace.airPlayGapHandoffMark(.musicPlaying, at: 1.100))
        XCTAssertTrue(row.detail.contains("musicPlaying=1100"), row.detail)
        XCTAssertNil(trace.airPlayGapHandoffMark(.musicPlaying, at: 1.900), "a later poll stamp must not emit or move it")
        XCTAssertEqual(trace.rows.filter { $0.detail.contains("kind=handoff") }.count, 1)
    }

    /// A new begin finalizes a still-open break so it is never silently dropped.
    func testBeginFlushesAnOpenBreakWithMissingSteps() throws {
        var trace = AirPlayGapHandoffTrace()
        _ = trace.begin(afterTrack: 4, at: 0)
        _ = trace.mark(.firstPlay, at: 0.050)
        let flushed = try XCTUnwrap(trace.begin(afterTrack: 5, at: 8))
        XCTAssertEqual(flushed.afterTrack, 4)
        XCTAssertEqual(flushed.outcome, .incomplete)
        XCTAssertEqual(flushed.missing, [.lastFinish, .sessionOff, .nextPlay, .musicPlaying])
        XCTAssertTrue(trace.isOpen)
        let second = try XCTUnwrap(trace.finalize())
        XCTAssertEqual(second.afterTrack, 5)
        XCTAssertEqual(second.outcome, .skipped, "no firstPlay on the new break: treated as skipped")
    }

    /// Invalid or nil latency is `-`, never a made-up number.
    func testInvalidLatencyIsMissing() throws {
        XCTAssertNil(AirPlayGapHandoffTrace.latencyMs(nil))
        XCTAssertNil(AirPlayGapHandoffTrace.latencyMs(.nan))
        XCTAssertNil(AirPlayGapHandoffTrace.latencyMs(.infinity))
        XCTAssertNil(AirPlayGapHandoffTrace.latencyMs(-0.1))
        XCTAssertEqual(AirPlayGapHandoffTrace.latencyMs(0), 0)
        XCTAssertEqual(AirPlayGapHandoffTrace.latencyMs(2.0), 2000)
        var trace = AirPlayGapHandoffTrace()
        _ = trace.begin(afterTrack: 0, outputLatency: .nan, at: 0)
        let row = try XCTUnwrap(trace.finalize())
        XCTAssertNil(row.outputLatencyMs)
        XCTAssertTrue(row.detail.contains("latency=-"))
    }

    /// A `.playing` mark before next `play()` is ignored, so a leftover poll cannot close the row early.
    func testPlayingBeforeNextPlayIsIgnored() throws {
        var trace = AirPlayGapHandoffTrace()
        _ = trace.begin(afterTrack: 0, at: 0)
        _ = trace.mark(.firstPlay, at: 0.1)
        XCTAssertNil(trace.mark(.musicPlaying, at: 0.2))
        XCTAssertTrue(trace.isOpen)
        _ = trace.mark(.nextPlay, at: 0.3)
        let row = try XCTUnwrap(trace.mark(.musicPlaying, at: 0.4))
        XCTAssertEqual(row.milliseconds[.musicPlaying], 400)
        XCTAssertEqual(row.milliseconds[.nextPlay], 300)
    }

    // MARK: Privacy

    /// The formatter only emits known keys, integer milliseconds, reason codes, `+` in
    /// `missing`, or `-`. No title, track id, station name, port name, UID or device name.
    func testRowContainsCodesAndMillisecondsOnly() throws {
        var trace = AirPlayGapHandoffTrace()
        _ = trace.begin(afterTrack: 7, outputLatency: 0.2, at: 0)
        _ = trace.mark(.firstPlay, at: 0.01)
        let row = try XCTUnwrap(trace.finalize())
        let allowedKeys: Set<String> = [
            "kind", "after", "result", "songEnd", "firstPlay", "lastFinish",
            "sessionOff", "nextPlay", "musicPlaying", "latency", "missing",
        ]
        let allowedCodes = Set(AirPlayGapHandoffTrace.Step.allCases.map(\.rawValue)
                               + AirPlayGapHandoffTrace.Outcome.allCases.map(\.rawValue)
                               + ["handoff"])
        for pair in row.detail.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            XCTAssertEqual(parts.count, 2, String(pair))
            XCTAssertTrue(allowedKeys.contains(String(parts[0])), "unexpected key \(parts[0])")
            for token in parts[1].split(separator: "+") {
                let value = String(token)
                XCTAssertTrue(allowedCodes.contains(value) || Int(value) != nil || value == "-",
                              "\(row.detail): \(value)")
            }
        }
        for forbidden in ["Morning Light", "uid", "Apple TV", "Living Room", "station", "trackID"] {
            XCTAssertFalse(row.detail.localizedCaseInsensitiveContains(forbidden), row.detail)
        }
    }

    // MARK: P0EventTrace emission

    /// The P0 row is assembled from the same `at:` clock `record(_:at:)` uses, and matches
    /// the Core formatter.
    func testP0EventTraceEmitsTheHandoffRowOnTheRecordClock() throws {
        var trace = P0EventTrace()
        XCTAssertNil(trace.airPlayGapHandoffBegin(afterTrack: 3, outputLatency: 0.18, at: 10.0))
        XCTAssertNil(trace.airPlayGapHandoffMark(.firstPlay, outputLatency: 0.184, at: 10.042))
        XCTAssertNil(trace.airPlayGapHandoffMark(.lastFinish, at: 11.850))
        XCTAssertNil(trace.airPlayGapHandoffMark(.sessionOff, at: 11.855))
        XCTAssertNil(trace.airPlayGapHandoffMark(.nextPlay, at: 11.902))
        let row = try XCTUnwrap(trace.airPlayGapHandoffMark(.musicPlaying, at: 12.010))
        XCTAssertEqual(row.event, .sessionRoute)
        XCTAssertEqual(row.detail,
                       "kind=handoff after=3 result=complete songEnd=0 firstPlay=42 lastFinish=1850 sessionOff=1855 nextPlay=1902 musicPlaying=2010 latency=184 missing=-")
        XCTAssertEqual(row.t, 12.0, "the row's t is the record clock, rounded to 1 decimal")
    }

    func testP0EventTraceDoesNotBeginAHandoffOnTheHeadphonePath() {
        // talkoverAllowed defaults to true (not AirPlay). onBoundary must not open a session.
        XCTAssertTrue(DJLongFormRouteState.shared.talkoverAllowed)
        var trace = P0EventTrace()
        _ = trace.onBoundary(.naturalEnd(finishedEntryID: "e"), finishedIndex: 2, at: 1)
        // Nothing to finalize: no row.
        XCTAssertNil(trace.airPlayGapHandoffFinalize(at: 2))
        XCTAssertFalse(trace.rows.contains { $0.detail.contains("kind=handoff") })
    }

    // MARK: App wiring (source checks)

    private static var ios: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Atlas's bar: the adapter hook sits inside `#if DEBUG || AERODJ_P0_DIAG` so Release
    /// compiles it out (the same gate as `P0EventTrace`).
    func testAdapterHookIsInsideTheDebugOrDiagGate() throws {
        let source = try String(contentsOf: Self.ios.appendingPathComponent("AeroDJ/InterludePlaybackAdapter.swift"),
                                encoding: .utf8)
        let hits = Self.unguardedLines(in: source, token: "recordAirPlayGapHandoff")
        XCTAssertTrue(source.contains("recordAirPlayGapHandoff"), "the adapter hook is missing")
        XCTAssertTrue(hits.isEmpty, "adapter hook must sit inside #if DEBUG || AERODJ_P0_DIAG; unguarded lines \(hits)")
        XCTAssertTrue(source.contains("#if DEBUG || AERODJ_P0_DIAG"))
    }

    /// Clip-finish and `setActive(false)` (`completeNarration`) only record a timestamp.
    /// No new await or session call, and no outputLatency read on those paths.
    func testClipFinishAndSessionOffHooksDoNotCallTheSessionOrAwait() throws {
        let source = try String(contentsOf: Self.ios.appendingPathComponent("AeroDJ/InterludePlaybackAdapter.swift"),
                                encoding: .utf8)
        let lastFinish = Self.block(around: "recordAirPlayGapHandoff(.lastFinish)", in: source)
        let sessionOff = Self.block(around: "recordAirPlayGapHandoff(.sessionOff)", in: source)
        for (name, block) in [("lastFinish", lastFinish), ("sessionOff", sessionOff)] {
            let body = try XCTUnwrap(block, name)
            for forbidden in ["setActive", "setCategory", "await ", "outputLatency"] {
                XCTAssertFalse(body.contains(forbidden), "\(name) hook must not contain \(forbidden):\n\(body)")
            }
            XCTAssertTrue(body.contains("#if DEBUG || AERODJ_P0_DIAG"), name)
        }
    }

    /// The Core type itself is compiled only under the DIAG/DEBUG gate.
    func testCoreTypeIsCompiledOutOfRelease() throws {
        let url = Self.ios.appendingPathComponent("AeroDJCore/Sources/AeroDJCore/Playback/AirPlayGapHandoffTrace.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let first = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .first { !$0.hasPrefix("//") && !$0.isEmpty }
        XCTAssertEqual(first, "#if DEBUG || AERODJ_P0_DIAG")
        XCTAssertTrue(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
    }

    /// Any MusicKitService hook (needed only for MusicKit `.playing`) must also be gated.
    func testMusicKitPlayingHookIsGatedIfPresent() throws {
        let source = try String(contentsOf: Self.ios.appendingPathComponent("AeroDJ/MusicKitService.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("airPlayGapHandoffMark(.musicPlaying"), "confirmStart hook missing")
        let gate = try XCTUnwrap(Self.block(around: "airPlayGapHandoffMark(.musicPlaying", in: source, window: 8))
        XCTAssertTrue(gate.contains("#if DEBUG || AERODJ_P0_DIAG"), "same gate as the adapter hooks")
        for forbidden in ["try ", "throw "] {
            XCTAssertFalse(gate.contains(forbidden), forbidden)
        }
        let hits = Self.unguardedLines(in: source, token: "airPlayGapHandoffMark(.musicPlaying",
                                       also: ["DEBUG", "AERODJ_P0_DIAG"])
        XCTAssertTrue(hits.isEmpty, "confirmStart hook must be inside a DIAG/DEBUG gate; unguarded \(hits)")
        // The hook only records a timestamp: no new session call or await next to it.
        let block = try XCTUnwrap(Self.block(around: "airPlayGapHandoffMark(.musicPlaying", in: source, window: 8))
        for forbidden in ["setActive", "setCategory", "await "] {
            XCTAssertFalse(block.contains(forbidden), forbidden)
        }
    }

    // MARK: Scanner

    /// Lines that name `token` outside a DEBUG / AERODJ_P0_DIAG gate. A branch is gated
    /// when every `||` alternative contains `DEBUG` or `AERODJ_P0_DIAG`.
    static func unguardedLines(in source: String, token: String, also extra: [String] = []) -> [Int] {
        var stack: [Bool] = []
        var hits: [Int] = []
        var inBlock = false
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let code = stripComments(raw, inBlockComment: &inBlock)
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#if\t") {
                let condition = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                stack.append(isDiagOrDebugOnly(condition))
                continue
            }
            if trimmed.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1] = false }
                continue
            }
            if trimmed == "#else" {
                if !stack.isEmpty { stack[stack.count - 1] = false }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if code.contains(token), !stack.contains(true) { hits.append(index + 1) }
        }
        return hits
    }


    /// Drops `//` and `/* */` comments, keeping string literals.
    static func stripComments(_ line: String, inBlockComment: inout Bool) -> String {
        var out = ""
        var inString = false
        var chars = Array(line)[...]
        while let c = chars.first {
            if inBlockComment {
                if c == "*", chars.dropFirst().first == "/" { inBlockComment = false; chars = chars.dropFirst(2) } else { chars = chars.dropFirst() }
                continue
            }
            if inString {
                out.append(c)
                if c == "\\", let n = chars.dropFirst().first { out.append(n); chars = chars.dropFirst(2); continue }
                if c == "\"" { inString = false }
                chars = chars.dropFirst()
                continue
            }
            if c == "/", chars.dropFirst().first == "/" { break }
            if c == "/", chars.dropFirst().first == "*" { inBlockComment = true; chars = chars.dropFirst(2); continue }
            if c == "\"" { inString = true }
            out.append(c)
            chars = chars.dropFirst()
        }
        return out
    }

    static func isDiagOrDebugOnly(_ condition: String) -> Bool {
        let c = condition.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        let alternatives = c.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
        return alternatives.allSatisfy { alt in
            let terms = alt.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
            return terms.contains("DEBUG") || terms.contains("AERODJ_P0_DIAG")
        }
    }

    static func block(around needle: String, in source: String, window: Int = 4) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains(needle) }) else { return nil }
        let start = max(0, i - window)
        let end = min(lines.count, i + window + 1)
        return lines[start..<end].joined(separator: "\n")
    }
}
#endif
