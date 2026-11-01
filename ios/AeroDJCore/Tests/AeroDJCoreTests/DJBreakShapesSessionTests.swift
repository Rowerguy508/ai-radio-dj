import XCTest
@testable import AeroDJCore

/// Lane 2 (-Fry): natural break shapes through `DJBreakSession`, the app's only planner caller.
/// A replan or a new queue discards planned breaks that never air; the shape and anti-repeat
/// memory must follow what is kept, not what was planned away. Async methods throughout: Swift
/// 6.2 Linux test discovery needs them in a @MainActor test class.
private struct ShapesVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class DJBreakShapesSessionTests: XCTestCase {
    private func rig(seed: UInt64) async -> (DJBreakSession, StationConfigurationModel) {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: ShapesVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed, hour: { 14 })
        await session.start()
        return (session, station)
    }

    private func ordered(_ plan: [Int: DJBreak]) -> [DJBreak] { plan.sorted { $0.key < $1.key }.map(\.value) }

    /// No shape twice in a row and no identical line inside the window, over the breaks as planned.
    private func assertNatural(_ breaks: [DJBreak], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let shapes = breaks.compactMap(\.shape)
        XCTAssertGreaterThan(shapes.count, 3, "\(label): natural shapes are on in the session", file: file, line: line)
        for (a, b) in zip(breaks, breaks.dropFirst()) {
            if let x = a.shape, let y = b.shape {
                XCTAssertNotEqual(x, y, "\(label): \(x) twice in a row at \(a.afterTrack)/\(b.afterTrack)", file: file, line: line)
            }
        }
        let window = DJBreakShapeConfig.natural.recentBreakWindow
        let texts = breaks.map { $0.cues.filter { !$0.isContent }.map(\.text) }
        for (i, lines) in texts.enumerated() {
            let earlier = Set(texts[max(0, i - window)..<i].flatMap { $0 })
            for text in lines { XCTAssertFalse(earlier.contains(text), "\(label) break \(i) \(String(describing: breaks[i].shape)) after \(breaks[i].afterTrack): \(text)", file: file, line: line) }
        }
    }

    func testSessionPlansNaturalShapes() async {
        for seed in UInt64(0)..<10 {
            let (session, _) = await rig(seed: seed)
            await session.queueStarted(djTracks(90))
            let plan = ordered(session.testPlannedBreaks)
            assertNatural(plan, "seed \(seed)")
            for b in plan where b.shape != nil {
                let gap = b.cues.count > 1 && b.talkOverCueID == b.cues.last?.id ? PreparedDJBreak.talkOverGapSeconds : 0
                XCTAssertLessThanOrEqual(b.estimatedSeconds + gap, 12, "seed \(seed): 12 s cap with the pause")
            }
        }
    }

    func testReplanFollowsTheKeptBreaksNotThePlannedAwayOnes() async {
        for seed in UInt64(0)..<30 {
            let (session, station) = await rig(seed: seed)
            await session.queueStarted(djTracks(90))
            await station.setCommentary(.chatty)          // cadence change: re-plans after the playing song
            await station.saveChanges()
            await session.songStarted(index: 3, remaining: .seconds(180))
            assertNatural(ordered(session.testPlannedBreaks), "seed \(seed) after replan")
        }
    }

    func testNewQueueFollowsWhatPlayedNotThePlannedAwayBreaks() async {
        for seed in UInt64(0)..<30 {
            let (session, _) = await rig(seed: seed)
            await session.queueStarted(djTracks(90))
            await session.songStarted(index: 12, remaining: .seconds(180))
            let played = ordered(session.testPlannedBreaks.filter { $0.key <= 12 })
            // Different songs: the same song played again may reuse its intro line once the
            // stricter draws run out (required lines relax to the last 2 breaks).
            await session.queueStarted((0..<40).map { DJTrack(id: "n\($0)", title: "Tune \($0)", artist: "Band \($0)") })
            let next = ordered(session.testPlannedBreaks)
            assertNatural(played + next, "seed \(seed) across queues")
        }
    }
}
