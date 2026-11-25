import Foundation
import XCTest
@testable import AeroDJCore

/// Lane 2 time checks through `DJBreakSession` (-Fry): the session plans the slot with its
/// injected `now()`, and the line that airs is written by the preparer from the same injected
/// clock when it renders (Orion option (a), #347), however long after planning that is. Async
/// methods throughout: Swift 6.2 Linux test discovery needs them in a @MainActor test class.
private struct TimeVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class DJTimeCheckSessionTests: XCTestCase {
    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// Read by the preparer's task off the main actor, so lock-protected.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ now: Date) { value = now }
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private func rig(seed: UInt64, clock: Clock,
                     sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = DJBreakPreparer.sleep(until:))
        async -> DJBreakSession {
        let config = StationConfiguration(commentary: .frequent)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: TimeVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence(),
                                       now: { clock.now }, sleepUntil: sleepUntil)
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed,
                                     hour: { 7 }, now: { clock.now }, calendar: eastern, clockStyle: .twelveHour)
        await session.start()
        return session
    }

    /// A seed whose queue-start plan has a time check, and its boundary.
    /// Sessions that did not plan one are stopped here (their queue setup and prepare tasks
    /// cancelled); the caller stops the one returned.
    private func seededTimeCheck(clock: Clock) async -> (DJBreakSession, Int, DJBreak)? {
        for seed in UInt64(0)..<60 {
            let session = await rig(seed: seed, clock: clock)
            await session.queueStarted(djTracks(90))
            let found = session.testPlannedBreaks.first { $0.value.timeCheckCueID != nil }
            if let found { return (session, found.key, found.value) }
            await session.stop()
        }
        return nil
    }

    func testSessionSpeaksItsInjectedNowAndAtMostOneTimeCheckPerPlan() async {
        let clock = Clock(eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7, minute: 40))!)
        var withOne = 0, withOptional = 0
        for seed in UInt64(0)..<30 {
            let session = await rig(seed: seed, clock: clock)
            await session.queueStarted(djTracks(90))
            // replan keeps the planner's drop order for #320's measured-audio trim.
            withOptional += session.testPlannedBreaks.values.filter { !$0.optionalCueIDs.isEmpty }.count
            let checks = session.testPlannedBreaks.values.filter { $0.timeCheckCueID != nil }
            XCTAssertLessThanOrEqual(checks.count, 1, "seed \(seed): one clock reading per plan")
            for b in checks {
                withOne += 1
                let text = b.cues.first { $0.id == b.timeCheckCueID }.map(\.text) ?? "-"
                XCTAssertTrue(text.contains("7:40"), text)
                XCTAssertEqual(b.attributions[b.timeCheckCueID!], .presenter)
                XCTAssertEqual(b.timeCheckPlannedAt, clock.now)
            }
            await session.stop()   // no queue setup or prepare task outlives this seed
        }
        XCTAssertGreaterThan(withOne, 0, "some seeds plan a time check")
        XCTAssertGreaterThan(withOptional, 0, "planned breaks keep their optional lines through replan")
    }

    func testTimeCheckAirsTheTimeReadWhenItRendersNotWhenPlanned() async {
        let clock = Clock(eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7, minute: 40))!)
        guard let seeded = await seededTimeCheck(clock: clock) else { return XCTFail("no seed planned one") }
        let (session, k, planned) = seeded
        await airsTheTimeReadWhenItRenders(session, k, planned, clock)
        await session.stop()   // cancels its prepare tasks, the late time-check wait included
    }

    private func airsTheTimeReadWhenItRenders(_ session: DJBreakSession, _ k: Int, _ planned: DJBreak, _ clock: Clock) async {
        // Songs played for a while: the break now airs 20 minutes after it was planned.
        clock.now = clock.now.addingTimeInterval(20 * 60)
        // 60 s left: inside the time-check window, so the line renders straight after the rest.
        await session.songStarted(index: k, remaining: .seconds(60))
        XCTAssertEqual(session.testPlannedBreaks[k]?.timeCheckCueID, planned.timeCheckCueID, "the slot stays planned")
        // Polled inline: no non-escaping async closure is held across awaits in this @MainActor
        // test (the suspected trigger of the Xcode 26.6 task-allocator abort, see 10468a2). -Fry
        let preparer = session.testPreparer, count = planned.cues.count
        var added = false
        for _ in 0..<500 {
            if case .ready(let b)? = await preparer.testResult(afterTrack: k), b.cues.count == count { added = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(added)
        guard let aired = await session.naturalBoundary(afterTrack: k) else { return XCTFail("the break airs") }
        let text = aired.cues.first { $0.id == planned.timeCheckCueID }.map(\.text) ?? "-"
        XCTAssertTrue(text.contains("8 o'clock"), text)
        let stale = aired.cues.contains { $0.text.contains("7:40") }
        XCTAssertFalse(stale, "the plan-time reading never airs")
        XCTAssertEqual(aired.cues.last?.id, planned.cues.last?.id, "the closing line stays last")
        XCTAssertNil(aired.droppedTimeCheck)
    }

    // MARK: Teardown (macOS abort at ffe040c)

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// A session dropped without `stop()` frees its preparer, which cancels a pending
    /// time-check wait, so it never wakes inside a later test.
    func testDroppedSessionCancelsItsTimeCheckWait() async {
        let clock = Clock(eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7, minute: 40))!)
        let waiting = Flag(), cancelled = Flag()
        let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void = { _ in
            waiting.set()
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.set(); throw error }
        }
        var found = false
        for seed in UInt64(0)..<60 where !found {
            var session: DJBreakSession? = await rig(seed: seed, clock: clock, sleepUntil: sleepUntil)
            await session?.queueStarted(djTracks(90))
            if let (k, _) = session?.testPlannedBreaks.first(where: { $0.value.timeCheckCueID != nil }) {
                found = true
                await session?.songStarted(index: k, remaining: .seconds(180))
                var isWaiting = false
                for _ in 0..<500 where !isWaiting {
                    isWaiting = waiting.isSet
                    if !isWaiting { try? await Task.sleep(for: .milliseconds(10)) }
                }
                XCTAssertTrue(isWaiting)
            }
            session = nil
        }
        XCTAssertTrue(found, "a seed planned a time check")
        var gone = false
        for _ in 0..<500 where !gone {
            gone = cancelled.isSet
            if !gone { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(gone, "the wait is cancelled once nothing holds the session")
    }

    // MARK: Stale at the take (Echo blocker 1, #347)

    /// Plays song `k` to 60 s left and waits for the full break, time check included.
    private func readyWithTimeCheck(_ session: DJBreakSession, _ k: Int, _ planned: DJBreak) async -> Bool {
        await session.songStarted(index: k, remaining: .seconds(60))
        let preparer = session.testPreparer, count = planned.cues.count
        for _ in 0..<500 {
            if case .ready(let b)? = await preparer.testResult(afterTrack: k), b.cues.count == count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private final class Drops: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Int: DJTimeCheckDrop] = [:]
        var all: [Int: DJTimeCheckDrop] { lock.withLock { value } }
        func add(_ k: Int, _ drop: DJTimeCheckDrop) { lock.withLock { value[k] = drop } }
    }

    private func assertAirsWithoutStaleTimeCheck(_ aired: PreparedDJBreak?, _ k: Int, _ planned: DJBreak, _ drops: Drops) {
        guard let aired else { return XCTFail("the rest of the break airs") }
        let id = planned.timeCheckCueID!
        XCTAssertFalse(aired.cues.contains { $0.id == id }, "the stale time check never airs")
        XCTAssertEqual(aired.cues.map(\.id), planned.cues.map(\.id).filter { $0 != id }, "only the time check dropped")
        XCTAssertEqual(aired.droppedTimeCheck, DJTimeCheckDrop(cueID: id, reason: .stale))
        XCTAssertEqual(drops.all, [k: DJTimeCheckDrop(cueID: id, reason: .stale)])
    }

    func testPausedSessionDropsTheStaleTimeCheck() async {
        let clock = Clock(eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7, minute: 40))!)
        guard let (session, k, planned) = await seededTimeCheck(clock: clock) else { return XCTFail("no seed planned one") }
        let drops = Drops()
        await session.testPreparer.observeTimeCheckDrops { drops.add($0, $1) }
        let ready = await readyWithTimeCheck(session, k, planned)
        XCTAssertTrue(ready)
        clock.now = clock.now.addingTimeInterval(10 * 60)   // paused ten minutes before the boundary
        assertAirsWithoutStaleTimeCheck(await session.naturalBoundary(afterTrack: k), k, planned, drops)
        await session.stop()
    }

    func testSeekBackInSessionDropsTheStaleTimeCheck() async {
        let clock = Clock(eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7, minute: 40))!)
        guard let (session, k, planned) = await seededTimeCheck(clock: clock) else { return XCTFail("no seed planned one") }
        let drops = Drops()
        await session.testPreparer.observeTimeCheckDrops { drops.add($0, $1) }
        let ready = await readyWithTimeCheck(session, k, planned)
        XCTAssertTrue(ready)
        // Seek back four minutes: the ready break is kept and airs four minutes later.
        await session.songSeeked(index: k, remaining: .seconds(300))
        let kept = await session.breakIsReady(afterTrack: k)
        XCTAssertTrue(kept, "a ready break is kept on a seek")
        clock.now = clock.now.addingTimeInterval(5 * 60)
        assertAirsWithoutStaleTimeCheck(await session.naturalBoundary(afterTrack: k), k, planned, drops)
        await session.stop()
    }
}
