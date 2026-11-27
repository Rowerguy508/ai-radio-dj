import XCTest
@testable import AeroDJCore

private struct FixedVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

/// #304 (-Fry, from Echo's finding): a song with no usable duration logs `durationUnknown` once,
/// at song start. Its boundary records the same reason and is not logged a second time as
/// `notPlanned`. Other boundaries are logged exactly as before.
@MainActor
final class DurationUnknownLoggedOnceTests: XCTestCase {
    private func session() async -> DJBreakSession {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: FixedVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let s = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await s.start()
        await s.queueStarted(djTracks(8))
        return s
    }

    /// What the app logs for one song: the song-start skip, then the boundary skip if any.
    private func appLogLines(_ s: DJBreakSession, index: Int, duration: TimeInterval?) async -> [String] {
        var lines: [String] = []
        if let skip = PlaybackLog.songStartSkipReason(duration: duration) {
            lines.append(PlaybackLog.breakSkipped(after: index, reason: skip))
            s.songStartedWithoutDuration(index: index)
        } else if let duration {
            await s.songStarted(index: index, remaining: .seconds(duration))
        }
        if await s.naturalBoundary(afterTrack: index) == nil,
           let reason = PlaybackLog.boundarySkipToLog(s.lastNoBreak) {
            lines.append(PlaybackLog.breakSkipped(after: index, reason: reason))
        }
        return lines
    }

    func testNoDurationSongWithAPlannedBreakLogsOneLine() async {
        let s = await session()
        XCTAssertEqual(s.plannedBoundaries.first, 0)
        let lines = await appLogLines(s, index: 0, duration: nil)
        XCTAssertEqual(lines, ["break skipped after=0 reason=durationUnknown"])
        XCTAssertEqual(s.lastNoBreak?.reason, .durationUnknown)
        XCTAssertEqual(s.lastNoBreak?.cadencePlanned, true)
    }

    func testNoDurationSongWithoutAPlannedBreakAlsoLogsOneLine() async {
        let s = await session()
        _ = await appLogLines(s, index: 0, duration: 180)
        XCTAssertFalse(s.plannedBoundaries.contains(1))
        let lines = await appLogLines(s, index: 1, duration: .nan)
        XCTAssertEqual(lines, ["break skipped after=1 reason=durationUnknown"])
    }

    func testOrdinaryUnplannedBoundaryStillLogsNotPlanned() async {
        let s = await session()
        _ = await appLogLines(s, index: 0, duration: 180)
        let lines = await appLogLines(s, index: 1, duration: 180)
        XCTAssertEqual(lines, ["break skipped after=1 reason=notPlanned"])
    }

    func testASongThatLaterGetsADurationIsNoLongerTreatedAsUnknown() async {
        let s = await session()
        s.songStartedWithoutDuration(index: 1)
        await s.songStarted(index: 1, remaining: .seconds(180))   // a replay with a known duration
        _ = await s.naturalBoundary(afterTrack: 1)
        XCTAssertEqual(s.lastNoBreak?.reason, .notPlanned)
    }

    func testANewQueueForgetsUnknownDurations() async {
        let s = await session()
        s.songStartedWithoutDuration(index: 1)
        await s.queueStarted(djTracks(8))
        _ = await s.naturalBoundary(afterTrack: 1)
        XCTAssertEqual(s.lastNoBreak?.reason, .notPlanned)
    }

    /// Echo's #116 finding: on the tap-first path the song starts while queue setup is pending.
    /// The mark is held and re-applied after `queueStarted`, so the first song logs one line.
    func testTapFirstSetupKeepsTheMarkForTheNewQueuesFirstSong() async {
        let s = await session()
        let reservation = s.reserveQueueSetup()
        var lines: [String] = []
        if let skip = PlaybackLog.songStartSkipReason(duration: nil) {
            lines.append(PlaybackLog.breakSkipped(after: 0, reason: skip))
            s.songStartedWithoutDuration(index: 0)
        }
        XCTAssertTrue(s.testQueueSetupPending)
        await s.beginQueueInBackground(reservation, djTracks(8)).value
        XCTAssertFalse(s.testQueueSetupPending)
        XCTAssertNil(s.testHeldSongStartIndex)
        if await s.naturalBoundary(afterTrack: 0) == nil,
           let reason = PlaybackLog.boundarySkipToLog(s.lastNoBreak) {
            lines.append(PlaybackLog.breakSkipped(after: 0, reason: reason))
        }
        XCTAssertEqual(lines, ["break skipped after=0 reason=durationUnknown"])
        XCTAssertEqual(s.lastNoBreak?.reason, .durationUnknown)
    }

    func testAKnownDurationStartDuringSetupDropsTheHeldMark() async {
        let s = await session()
        let reservation = s.reserveQueueSetup()
        s.songStartedWithoutDuration(index: 0)
        await s.songStarted(index: 0, remaining: .seconds(180))
        await s.beginQueueInBackground(reservation, djTracks(8)).value
        XCTAssertNotEqual(s.lastNoBreak?.reason, .durationUnknown)
        _ = await s.naturalBoundary(afterTrack: 0)
        XCTAssertNotEqual(s.lastNoBreak?.reason, .durationUnknown)
    }

    func testAReleasedOrCancelledSetupDropsTheHeldMark() async {
        let s = await session()
        let released = s.reserveQueueSetup()
        s.songStartedWithoutDuration(index: 1)
        s.releaseQueueSetup(released)
        _ = await s.naturalBoundary(afterTrack: 1)
        XCTAssertEqual(s.lastNoBreak?.reason, .notPlanned)

        let cancelled = s.reserveQueueSetup()
        s.songStartedWithoutDuration(index: 1)
        s.cancelBackgroundQueueSetup()
        await s.beginQueueInBackground(cancelled, djTracks(8)).value
        await s.queueStarted(djTracks(8))
        _ = await s.naturalBoundary(afterTrack: 1)
        XCTAssertEqual(s.lastNoBreak?.reason, .notPlanned)
    }

    func testBoundarySkipToLogDropsOnlyDurationUnknown() {
        XCTAssertNil(PlaybackLog.boundarySkipToLog((.durationUnknown, true)))
        XCTAssertEqual(PlaybackLog.boundarySkipToLog(nil), .notPlanned)
        XCTAssertEqual(PlaybackLog.boundarySkipToLog((.notReadyAtBoundary, true)), .notReadyAtBoundary)
        XCTAssertEqual(PlaybackLog.boundarySkipToLog((.cancelled, false)), .cancelled)
    }
}
