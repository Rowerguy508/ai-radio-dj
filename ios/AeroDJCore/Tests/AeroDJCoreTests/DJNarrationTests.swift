import XCTest
@testable import AeroDJCore

/// Fake voice for DJ tests: duration = words * 0.4 s; optional delay, failure.
struct DJFakeVoice: VoiceProvider {
    var id = "device"
    var delay: Duration = .zero
    var fails = false
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        if delay > .zero { try await Task.sleep(for: delay) }
        if fails { throw URLError(.cannotConnectToHost) }
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data("\(id):\(text)".utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: text.count, provider: id, cacheKey: nil)
    }
}

/// Collects preparation events in order (observer callbacks are synchronous on the preparer actor).
final class DJEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DJBreakPreparer.DJBreakEvent] = []
    func add(_ e: DJBreakPreparer.DJBreakEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [DJBreakPreparer.DJBreakEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

let djVoice = VoiceProfile(id: "host", name: "Host")

func djRenderer(paid: DJFakeVoice? = nil, paidTimeout: Duration = .seconds(2), free: DJFakeVoice? = DJFakeVoice(),
                capMicrodollars: Int = 1_000_000) -> VoiceRenderer {
    var routes: [VoiceRoute] = []
    if let paid {
        routes.append(VoiceRoute(providerID: "cloud", provider: paid, voice: djVoice,
                                 microdollarsPerThousandCharacters: 30_000, timeout: paidTimeout))
    }
    if let free { routes.append(VoiceRoute(providerID: "device", provider: free, voice: djVoice)) }
    return VoiceRenderer(routes: routes, budget: VoiceBudget(dailyCapMicrodollars: capMicrodollars), cache: InMemoryAudioCache())
}

func djTracks(_ n: Int) -> [DJTrack] {
    (0..<n).map { DJTrack(id: "t\($0)", title: "Song \($0)", artist: "Artist \($0)") }
}

final class DJNarrationTests: XCTestCase {
    private func lines(_ plan: DJSessionPlan) -> [String] { plan.breaks.flatMap { $0.cues.map(\.text) } }

    func testSeededSessionsAreReproducible() {
        var a = DJScriptWriter(seed: 42), b = DJScriptWriter(seed: 42), c = DJScriptWriter(seed: 7)
        let tracks = djTracks(30)
        let pa = a.plan(tracks: tracks, briefing: nil, hour: 8)
        XCTAssertEqual(lines(pa), lines(b.plan(tracks: tracks, briefing: nil, hour: 8)))
        XCTAssertNotEqual(pa.breaks.map(\.afterTrack), c.plan(tracks: tracks, briefing: nil, hour: 8).breaks.map(\.afterTrack))
    }

    func testNeverEveryTrackAndNeverBackToBack() {
        let tracks = djTracks(200)
        for seed in UInt64(1)...20 {
            var w = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed)
            let at = w.plan(tracks: tracks, briefing: nil, hour: 14).breaks.map(\.afterTrack)
            XCTAssertTrue(zip(at, at.dropFirst()).allSatisfy { $1 - $0 >= 2 }, "at least one whole song between breaks")
        }
        var standard = DJScriptWriter(seed: 3)
        let count = standard.plan(tracks: tracks, briefing: nil, hour: 9).breaks.count
        XCTAssertGreaterThan(count, 5)
        XCTAssertLessThan(Double(count) / 199, 0.25, "default cadence talks at a minority of boundaries")
        var silent = DJScriptWriter(cadence: .init(talkFraction: 0), seed: 3)
        XCTAssertTrue(silent.plan(tracks: tracks, briefing: nil, hour: 9).breaks.isEmpty)
    }

    func testPhrasingDoesNotRepeatUntilPoolIsUsedUp() {
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 9)
        let breaks = writer.plan(tracks: djTracks(41), briefing: nil, hour: 9).breaks
        // Last line of each break is the intro; normalise the song-specific parts away.
        let intros = breaks.map { $0.cues.last!.text.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression) }
        for window in stride(from: 0, to: intros.count - 4, by: 5) {
            XCTAssertEqual(Set(intros[window..<window + 5]).count, 5, "5 intro templates, none repeated within a cycle")
        }
        XCTAssertTrue(zip(intros, intros.dropFirst()).allSatisfy { $0 != $1 })
        XCTAssertEqual(breaks.first?.cues.first?.text.hasPrefix("Morning") == true
                       || breaks.first?.cues.first?.text.hasPrefix("Good morning") == true, true, "time-of-day greeting")
    }

    func testOnlyRealMetadataIsSpoken() {
        let tracks = [DJTrack(id: "a", title: "Blue", artist: " "), DJTrack(id: "b", title: "Red", artist: "Ana"),
                      DJTrack(id: "c", title: "", artist: "Bo"), DJTrack(id: "d", title: "Green", artist: "Cy")]
        for seed in UInt64(1)...30 {
            var w = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed)
            for djBreak in w.plan(tracks: tracks, briefing: nil, hour: 20).breaks {
                let prev = tracks[djBreak.afterTrack], next = tracks[djBreak.afterTrack + 1]
                for cue in djBreak.cues {
                    XCTAssertEqual(cue.kind, .transition)
                    XCTAssertNil(cue.sourceItemID)
                    XCTAssertFalse(cue.text.contains("{") || cue.text.contains("by .") || cue.text.contains(" , "), cue.text)
                    let names = ["Blue", "Red", "Green", "Ana", "Bo", "Cy"].filter { cue.text.contains($0) }
                    let allowed = [prev.title, prev.artist, next.title, next.artist].filter { !$0.isEmpty }
                    XCTAssertTrue(names.allSatisfy { allowed.contains($0) }, "\(cue.text) mentions only adjacent tracks")
                }
            }
        }
    }

    func testBriefingIsWovenIntoBreaksAndEveryCueHasOneOutcome() {
        func cue(_ order: Int, _ kind: BriefingScriptSegment.Kind, _ text: String, content: Bool = true) -> NarrationCue {
            NarrationCue(id: UUID(), order: order, group: 0, kind: kind, text: text, estimatedSeconds: 8, maxSeconds: 20,
                         sourceItemID: content ? UUID() : nil, source: content ? .calendar : nil, provenance: content ? "p" : nil)
        }
        let cues = [cue(0, .opener, "Good morning. Here's your briefing.", content: false)]
            + (1...6).map { cue($0, .upcomingEvent, "Item \($0).") }
            + [cue(7, .closer, "That's your briefing.", content: false)]
        let handoff = NarrationHandoff(cues: cues, maxSpokenSeconds: 150, experienceSeconds: 300)
        var w = DJScriptWriter(cadence: .init(talkFraction: 0, minSongsBetweenBreaks: 2, maxBriefingBreakSeconds: 30), seed: 1)
        let plan = w.plan(tracks: djTracks(6), briefing: handoff, hour: 7)
        XCTAssertEqual(plan.breaks.map(\.afterTrack), [0, 3], "briefing breaks still respect the gap")
        XCTAssertTrue(plan.breaks.allSatisfy { $0.estimatedSeconds <= 30 })
        XCTAssertEqual(plan.briefingReport.entries.count, cues.count)
        let outcomes = plan.briefingReport.entries.map(\.outcome)
        XCTAssertEqual(outcomes.first, .dropped(.notPlacedByScheduler))
        XCTAssertTrue(outcomes.contains(.deferred(.noTrackBoundary)), "music wins; the rest waits for later breaks")
        XCTAssertTrue(outcomes.contains(.scheduled(.afterTrack(3))))
    }

    func testPresentationStateFollowsRealEventsOnly() {
        var m = DJPresentationModel()
        XCTAssertEqual(m.apply(.breakPreparing(afterTrack: 2)), .preparing(afterTrack: 2))
        XCTAssertEqual(m.apply(.breakPrepared(afterTrack: 2, hasBriefing: true)), .upcomingBriefing(afterTrack: 2))
        XCTAssertEqual(m.apply(.consentReviewPending(count: 1)), .consentReviewRequired(pendingCount: 1))
        XCTAssertEqual(m.apply(.consentReviewPending(count: 0)), .upcomingBriefing(afterTrack: 2))
        XCTAssertEqual(m.apply(.speechAudioStarted(afterTrack: 2)), .speaking(afterTrack: 2))
        XCTAssertEqual(m.apply(.speechAudioEnded(afterTrack: 5)), .speaking(afterTrack: 2), "a stale end does not stop speaking")
        XCTAssertEqual(m.apply(.speechAudioEnded(afterTrack: 2)), .idle)
        m.apply(.breakPreparing(afterTrack: 4))
        XCTAssertEqual(m.apply(.breakSkipped(afterTrack: 4)), .idle, "a skipped break never shows as speaking")
    }

    func testBoundaryNeverWaitsForSlowRender() async throws {
        let preparer = DJBreakPreparer(renderer: djRenderer(free: DJFakeVoice(delay: .seconds(5))), userID: "u", stationID: "s")
        var w = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        let djBreak = try XCTUnwrap(w.plan(tracks: djTracks(3), briefing: nil, hour: 9).breaks.first)
        await preparer.prepare(djBreak, deadline: .seconds(10))
        let start = ContinuousClock.now
        let outcome = await preparer.takeBreak(afterTrack: djBreak.afterTrack)
        XCTAssertEqual(outcome, .skipped(.notReadyAtBoundary))
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(200))
        let unplanned = await preparer.takeBreak(afterTrack: 99)
        XCTAssertEqual(unplanned, .skipped(.notPlanned))
    }

    func testDeadlineAndCostCapSkipExplicitly() async throws {
        var w = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        let djBreak = try XCTUnwrap(w.plan(tracks: djTracks(3), briefing: nil, hour: 9).breaks.first)
        let k = djBreak.afterTrack

        let slow = DJBreakPreparer(renderer: djRenderer(free: DJFakeVoice(delay: .seconds(5))), userID: "u", stationID: "s")
        await slow.prepare(djBreak, deadline: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(400))
        let late = await slow.takeBreak(afterTrack: k)
        XCTAssertEqual(late, .skipped(.timedOut))

        let capped = DJBreakPreparer(renderer: djRenderer(paid: DJFakeVoice(id: "cloud"), free: nil, capMicrodollars: 0),
                                     userID: "u", stationID: "s")
        await capped.prepare(djBreak, deadline: .seconds(2))
        try await Task.sleep(for: .milliseconds(200))
        let cap = await capped.takeBreak(afterTrack: k)
        XCTAssertEqual(cap, .skipped(.costCap))
    }
}
