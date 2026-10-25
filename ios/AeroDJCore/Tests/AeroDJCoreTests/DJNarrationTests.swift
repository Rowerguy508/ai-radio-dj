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

    func testPresentationHappyPathSpeaksOnlyAfterPlayerConfirms() {
        var m = DJPresentationModel()
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.apply(.breakPreparing(afterTrack: 2, includesBriefing: true)), .preparing(afterTrack: 2, includesBriefing: true))
        XCTAssertEqual(m.apply(.breakReady(afterTrack: 2, includesBriefing: true, seconds: 9)), .ready(afterTrack: 2, includesBriefing: true, seconds: 9))
        XCTAssertFalse(m.state.isLive, "ready is not live: nothing is audible")
        XCTAssertEqual(m.apply(.playbackStarted(afterTrack: 2)), .speaking(afterTrack: 2, includesBriefing: true))
        XCTAssertTrue(m.state.isLive)
        XCTAssertEqual(m.apply(.playbackFinished(afterTrack: 5)), .speaking(afterTrack: 2, includesBriefing: true), "a stale finish is ignored")
        XCTAssertEqual(m.apply(.playbackFinished(afterTrack: 2)), .idle)
    }

    func testPresentationFailurePaths() {
        var m = DJPresentationModel()
        m.apply(.breakPreparing(afterTrack: 1, includesBriefing: false))
        XCTAssertEqual(m.apply(.breakSkipped(afterTrack: 1, .costCap)), .unavailable(.budgetReached))
        m.apply(.breakPreparing(afterTrack: 3, includesBriefing: false))
        XCTAssertEqual(m.state, .preparing(afterTrack: 3, includesBriefing: false), "a new attempt shows preparing")
        XCTAssertEqual(m.apply(.breakReady(afterTrack: 3, includesBriefing: false, seconds: 4)), .ready(afterTrack: 3, includesBriefing: false, seconds: 4))
        XCTAssertEqual(m.apply(.playbackStarted(afterTrack: 3)), .speaking(afterTrack: 3, includesBriefing: false))
        XCTAssertEqual(m.apply(.playbackFailed(afterTrack: 3)), .unavailable(.voiceFailed), "playback failure ends speaking at once")
        for reason in [DJBreakSkipReason.renderFailed, .overDuration, .timedOut, .overBreakBudget] {
            var f = DJPresentationModel()
            f.apply(.breakPreparing(afterTrack: 0, includesBriefing: true))
            XCTAssertEqual(f.apply(.breakSkipped(afterTrack: 0, reason)), .unavailable(.voiceFailed), "\(reason)")
        }
        for reason in [DJBreakSkipReason.notReadyAtBoundary, .notPlanned, .notNaturalBoundary] {
            var f = DJPresentationModel()
            f.apply(.breakPreparing(afterTrack: 0, includesBriefing: true))
            XCTAssertEqual(f.apply(.breakSkipped(afterTrack: 0, reason)), .idle, "\(reason): music just continues")
        }
        var f = DJPresentationModel()
        f.apply(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 3))
        XCTAssertEqual(f.apply(.playbackFailed(afterTrack: 0)), .unavailable(.voiceFailed), "clip failed to start or decode")
        XCTAssertEqual(f.apply(.breakReady(afterTrack: 2, includesBriefing: false, seconds: 3)), .ready(afterTrack: 2, includesBriefing: false, seconds: 3))
        XCTAssertEqual(f.apply(.playbackFinished(afterTrack: 2)), .idle, "a finish with no start clears the pending break")
    }

    func testPresentationConsentAndStop() {
        var m = DJPresentationModel()
        XCTAssertEqual(m.apply(.consentReviewPending(count: 2)), .unavailable(.consentReviewRequired(pendingCount: 2)))
        m.apply(.breakPreparing(afterTrack: 0, includesBriefing: false))
        m.apply(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 3))
        XCTAssertEqual(m.apply(.playbackStarted(afterTrack: 0)), .speaking(afterTrack: 0, includesBriefing: false), "real audio wins")
        XCTAssertEqual(m.apply(.playbackFinished(afterTrack: 0)), .unavailable(.consentReviewRequired(pendingCount: 2)))
        XCTAssertEqual(m.apply(.consentReviewPending(count: 0)), .idle)
        m.apply(.breakPreparing(afterTrack: 4, includesBriefing: true))
        m.apply(.playbackStarted(afterTrack: 4))
        XCTAssertEqual(m.apply(.sessionStopped), .idle, "stop ends speaking and pending breaks")
    }

    @MainActor
    func testStoreIsObservableAndStreamsChangesOnly() async {
        let store = DJPresentationStore()
        let stream = store.updates()
        store.send(.breakPreparing(afterTrack: 0, includesBriefing: false))
        store.send(.breakPreparing(afterTrack: 0, includesBriefing: false))   // no change, no emission
        store.send(.breakReady(afterTrack: 0, includesBriefing: false, seconds: 2))
        store.send(.playbackStarted(afterTrack: 0))
        store.send(.playbackFinished(afterTrack: 0))
        var seen: [DJPresentationState] = []
        for await state in stream { seen.append(state); if seen.count == 5 { break } }
        XCTAssertEqual(seen, [.idle, .preparing(afterTrack: 0, includesBriefing: false),
                              .ready(afterTrack: 0, includesBriefing: false, seconds: 2),
                              .speaking(afterTrack: 0, includesBriefing: false), .idle])
        XCTAssertEqual(store.state, .idle)
    }

    func testEverySpokenCueIsAttributedAndUnattributedContentIsNeverSpoken() {
        let good = NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: "Coming up: Standup. From your calendar.",
                                estimatedSeconds: 4, maxSeconds: 20, sourceItemID: UUID(), source: .calendar, provenance: "calendar:1")
        let bare = NarrationCue(id: UUID(), order: 2, group: 0, kind: .note, text: "Something with no provenance.",
                                estimatedSeconds: 4, maxSeconds: 20, sourceItemID: UUID(), source: .obsidian, provenance: nil)
        let handoff = NarrationHandoff(cues: [good, bare], maxSpokenSeconds: 60, experienceSeconds: 300)
        for seed in UInt64(1)...20 {
            var w = DJScriptWriter(cadence: .init(talkFraction: 0.5, minSongsBetweenBreaks: 1), seed: seed)
            let plan = w.plan(tracks: djTracks(12), briefing: handoff, hour: 8)
            XCTAssertEqual(plan.briefingReport.outcome(for: bare.id), .dropped(.unattributed))
            for djBreak in plan.breaks {
                XCTAssertEqual(Set(djBreak.attributions.keys), Set(djBreak.cues.map(\.id)), "every spoken cue is attributed")
                for cue in djBreak.cues {
                    XCTAssertNotEqual(cue.id, bare.id)
                    switch djBreak.attributions[cue.id]! {
                    case .personalContext(let item, let source, let provenance):
                        XCTAssertEqual(item, good.sourceItemID); XCTAssertEqual(source, .calendar); XCTAssertEqual(provenance, "calendar:1")
                        XCTAssertTrue(cue.text.contains("From your calendar."), "attribution is also spoken")
                    case .trackMetadata(let ids):
                        XCTAssertTrue(ids.allSatisfy { [djTracks(12)[djBreak.afterTrack].id, djTracks(12)[djBreak.afterTrack + 1].id].contains($0) })
                    case .presenter:
                        XCTAssertFalse(cue.text.contains("Song") || cue.text.contains("Artist"), "presenter lines carry no facts")
                    }
                }
            }
        }
    }

    func testBreaksOnlyBetweenCompleteSongs() async throws {
        for seed in UInt64(1)...20 {
            var w = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed)
            let breaks = w.plan(tracks: djTracks(4), briefing: nil, hour: 9).breaks
            XCTAssertTrue(breaks.allSatisfy { (0..<3).contains($0.afterTrack) }, "never before the first or after the last song")
        }
        XCTAssertNil(DJBreakPreparer.deadline(remainingInSong: .seconds(2)), "too late to prepare: no break")
        XCTAssertEqual(DJBreakPreparer.deadline(remainingInSong: .seconds(30)), .seconds(27))

        var w = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        let djBreak = try XCTUnwrap(w.plan(tracks: djTracks(3), briefing: nil, hour: 9).breaks.first)
        let preparer = DJBreakPreparer(renderer: djRenderer(), userID: "u", stationID: "s")
        let log = DJEventLog()
        await preparer.observe { log.add($0) }
        await preparer.prepare(djBreak, deadline: .seconds(2))
        try await Task.sleep(for: .milliseconds(200))
        let cut = await preparer.takeBreak(afterTrack: djBreak.afterTrack, natural: false)
        XCTAssertEqual(cut, .skipped(.notNaturalBoundary), "a skipped song never gets a break, even if audio is ready")
        let again = await preparer.takeBreak(afterTrack: djBreak.afterTrack)
        XCTAssertEqual(again, .skipped(.notNaturalBoundary), "and it cannot be replayed later")
        XCTAssertEqual(log.all.last, .skipped(afterTrack: djBreak.afterTrack, .notNaturalBoundary))
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

    func testCancelAllReleasesReservationsAndStaleAudioNeverPlays() async throws {
        var w = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        let plan = w.plan(tracks: djTracks(8), briefing: nil, hour: 9)
        let (first, second) = (plan.breaks[0], plan.breaks[1])
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000)
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: DJFakeVoice(id: "cloud", delay: .milliseconds(300)),
                                                         voice: djVoice, microdollarsPerThousandCharacters: 30_000)],
                                     budget: budget, cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s")
        let log = DJEventLog()
        await preparer.observe { log.add($0) }
        let fast = DJBreakPreparer(renderer: djRenderer(), userID: "u", stationID: "s")
        await fast.observe { log.add($0) }

        await fast.prepare(second, deadline: .seconds(2))           // ready before the station change
        await preparer.prepare(first, deadline: .seconds(2))        // still rendering (paid, reserved)
        try await Task.sleep(for: .milliseconds(100))
        await fast.cancelAll()
        await preparer.cancelAll()                                   // e.g. station switched at a boundary
        try await Task.sleep(for: .milliseconds(500))                // the paid render would have finished by now

        var model = DJPresentationModel()
        for event in log.all { model.apply(event.presentationEvent) }
        XCTAssertEqual(model.state, .idle, "no 'DJ up next' for breaks that will not play")
        XCTAssertFalse(log.all.contains { if case .prepared(first.afterTrack, _, _) = $0 { true } else { false } }, "late finish is ignored")
        XCTAssertTrue(log.all.contains(.skipped(afterTrack: first.afterTrack, .cancelled)))
        XCTAssertTrue(log.all.contains(.skipped(afterTrack: second.afterTrack, .cancelled)))
        let stale = await preparer.takeBreak(afterTrack: first.afterTrack)
        let staleReady = await fast.takeBreak(afterTrack: second.afterTrack)
        XCTAssertEqual(stale, .skipped(.notPlanned), "no stale audio at the next boundary")
        XCTAssertEqual(staleReady, .skipped(.notPlanned))
        let spent = await budget.committed(userID: "u")
        XCTAssertEqual(spent, 0, "a cancelled render is not charged")
        let full = await budget.reserve(userID: "u", microdollars: 1_000_000)
        XCTAssertNotNil(full, "and its reservation was released")
    }

    func testRevokingASourceDropsBreaksBuiltFromIt() async throws {
        let revoked = UUID()
        let cues = [NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: "Lease signing at 3.", estimatedSeconds: 3,
                                 maxSeconds: 10, sourceItemID: revoked, source: .userShared, provenance: "share")]
        let handoff = NarrationHandoff(cues: cues, maxSpokenSeconds: 30, experienceSeconds: 300)
        var w = DJScriptWriter(cadence: .init(talkFraction: 1), seed: 1)
        let plan = w.plan(tracks: djTracks(6), briefing: handoff, hour: 9)
        let withSource = try XCTUnwrap(plan.breaks.first { $0.cues.contains { $0.sourceItemID == revoked } })
        let other = try XCTUnwrap(plan.breaks.first { b in !b.cues.contains { $0.sourceItemID == revoked } })
        let cache = InMemoryAudioCache()
        let preparer = DJBreakPreparer(renderer: VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: DJFakeVoice(), voice: djVoice)],
                                                               budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache),
                                       userID: "u", stationID: "s")
        let log = DJEventLog()
        await preparer.observe { log.add($0) }
        await preparer.prepare(withSource, deadline: .seconds(2))
        await preparer.prepare(other, deadline: .seconds(2))
        try await Task.sleep(for: .milliseconds(200))

        await preparer.purge(sourceItemIDs: [revoked])
        await cache.purge(sourceItemIDs: [revoked])
        XCTAssertEqual(log.all.last, .skipped(afterTrack: withSource.afterTrack, .sourceRevoked))
        let dropped = await preparer.takeBreak(afterTrack: withSource.afterTrack)
        XCTAssertEqual(dropped, .skipped(.sourceRevoked), "prepared audio from a revoked source is never played")
        guard case .ready = await preparer.takeBreak(afterTrack: other.afterTrack) else { return XCTFail("unrelated break still plays") }
        let leftover = await cache.count
        XCTAssertEqual(leftover, withSource.cues.count + other.cues.count - 1, "only the clip spoken from the revoked item is purged")
    }
}
