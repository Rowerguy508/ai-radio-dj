import Foundation
import XCTest
@testable import AeroDJCore

// Lane 2 time checks, late render (Orion option (a) on #347, -Fry). The time-check line renders
// alone inside the break's own prepare task, about 75 s before the boundary, from the clock read
// then, in the break's voice, through the same `VoiceRenderer` (paid routes charged as usual).
// Late, failed, over-cap or taken: only that line is dropped; the rest of the break airs.

/// Records what it was asked to say. `fail` and `delay` pick out texts (or calls) to misbehave on.
private final class ScriptedVoice: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    private let fail: @Sendable (String, Int) -> Bool
    private let delay: @Sendable (String) -> Duration?
    private let seconds: @Sendable (String) -> Double

    init(fail: @escaping @Sendable (String, Int) -> Bool = { _, _ in false },
         delay: @escaping @Sendable (String) -> Duration? = { _ in nil },
         seconds: @escaping @Sendable (String) -> Double = { _ in 1 }) {
        self.fail = fail
        self.delay = delay
        self.seconds = seconds
    }

    var texts: [String] { lock.withLock { said } }

    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let call = lock.withLock { said.append(text); return said.count }
        if let wait = delay(text) { try await Task.sleep(for: wait) }
        if fail(text, call) { throw URLError(.cannotDecodeContentData) }
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: seconds(text), billableUnits: text.count,
                             provider: "test", cacheKey: nil)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ now: Date) { value = now }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class DJTimeCheckRenderTests: XCTestCase {
    /// Every preparer a test made; their prepare tasks (and late time-check waits) are cancelled
    /// in tearDown so none outlives its test.
    private var made: [DJBreakPreparer] = []

    override func tearDown() async throws {
        for p in made { await p.cancelAll() }
        made = []
        try await super.tearDown()
    }

    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: hour, minute: minute))!
    }

    private static let closingText = "Up next, Song 1 by Artist 1."

    /// "It's 9:40." (planned at 9:40), then the talk-over closing line.
    private func timeCheckBreak() -> DJBreak {
        let time = NarrationCue(id: UUID(), order: 1, group: -1, kind: .transition, text: "It's 9:40.",
                                estimatedSeconds: 1, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        let closing = NarrationCue(id: UUID(), order: 2, group: -1, kind: .transition, text: Self.closingText,
                                   estimatedSeconds: 2, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        var b = DJBreak(afterTrack: 0, cues: [time, closing],
                        attributions: [time.id: .presenter, closing.id: .trackMetadata(trackIDs: ["t1"], origin: .catalog)])
        b.talkOverCueID = closing.id
        b.shape = .timeCheckIntro
        b.timeCheck = DJPlannedTimeCheck(cueID: time.id, plannedAt: date(9, 40),
                                         templates: [.on: "It's {time}.", .comingUp: "Almost {time}.", .justAfter: "Just after {time}."],
                                         calendar: eastern, style: .twelveHour)
        return b
    }

    private func route(_ id: String, _ voice: ScriptedVoice, microdollarsPerThousand: Int = 0) -> VoiceRoute {
        VoiceRoute(providerID: id, provider: voice, voice: VoiceProfile(id: "\(id)-voice", name: "Host"),
                   microdollarsPerThousandCharacters: microdollarsPerThousand, timeout: .seconds(10),
                   leavesDevice: microdollarsPerThousand > 0)
    }

    private func preparer(_ routes: [VoiceRoute], clock: Clock, budget: VoiceBudget = VoiceBudget(dailyCapMicrodollars: 0),
                          sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = { _ in })
        -> DJBreakPreparer {
        let p = DJBreakPreparer(renderer: VoiceRenderer(routes: routes, budget: budget, cache: InMemoryAudioCache(),
                                                        revocations: NarrationRevocations()),
                                userID: "u", stationID: "s", talkOverEnabled: { true }, now: { clock.now }, sleepUntil: sleepUntil)
        made.append(p)
        return p
    }

    private static func ready(_ p: DJBreakPreparer) async -> PreparedDJBreak? {
        if case .ready(let b)? = await p.testResult(afterTrack: 0) { return b }
        return nil
    }

    /// `check` is escaping and Sendable: a non-escaping closure held across awaits in an async
    /// function is the suspected trigger of the Xcode 26.6 task-allocator abort (10468a2). -Fry
    private func eventually(_ seconds: Double = 5, _ check: @escaping @Sendable () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await check()
    }

    /// The rest of the break, as it must air when the time-check line is dropped.
    private func assertRestOnly(_ b: PreparedDJBreak?, _ planned: DJBreak, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(b?.cues.map(\.id), [planned.cues[1].id], "only the time check dropped", file: file, line: line)
        XCTAssertEqual(b?.clips.count, 1, file: file, line: line)
        XCTAssertEqual(b?.talkOverCueID, planned.talkOverCueID, "closing line and talk-over unchanged", file: file, line: line)
    }

    /// Every time-check drop the preparer reported (#347, Echo blocker 2).
    private final class Drops: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [DJTimeCheckDrop] = []
        var all: [DJTimeCheckDrop] { lock.withLock { value } }
        func add(_ drop: DJTimeCheckDrop) { lock.withLock { value.append(drop) } }
    }

    private func drops(_ p: DJBreakPreparer) async -> Drops {
        let drops = Drops()
        await p.observeTimeCheckDrops { k, drop in if k == 0 { drops.add(drop) } }
        return drops
    }

    /// The taken break carries the drop (cue ID and reason only), it was reported once, and the
    /// plan's cap report lists it.
    private func assertDropped(_ outcome: DJBreakOutcome, _ planned: DJBreak, _ reason: DJTimeCheckDropReason,
                               _ drops: Drops, file: StaticString = #filePath, line: UInt = #line) {
        let drop = DJTimeCheckDrop(cueID: planned.timeCheckCueID!, reason: reason)
        guard case .ready(let b) = outcome else { return XCTFail("the break must still air", file: file, line: line) }
        XCTAssertEqual(b.droppedTimeCheck, drop, file: file, line: line)
        XCTAssertEqual(drops.all, [drop], "reported once", file: file, line: line)
        let plan = DJSessionPlan(breaks: [planned], briefingReport: NarrationScheduleReport(entries: []))
        XCTAssertEqual(plan.capReport(afterBreaks: [0: outcome]).droppedTimeChecks, [0: drop], file: file, line: line)
        XCTAssertFalse(b.trimmedCueIDs.contains(drop.cueID), "a drop, not an optional-line trim", file: file, line: line)
    }

    // MARK: Render-time clock

    func testLineIsWrittenFromTheClockWhenItRendersNotWhenPlanned() async {
        let clock = Clock(date(9, 40))
        let voice = ScriptedVoice()
        // The wait for the time-check window: twelve minutes of songs go by. The line is written
        // for the time it airs, about 63 s on (9:53:03, "Almost 9:55."), not the render
        // reading (9:52, "Just after 9:50.") (Echo nit, #347).
        let later = date(9, 52)
        let p = preparer([route("device", voice)], clock: clock, sleepUntil: { _ in clock.now = later })
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let added = await eventually { await Self.ready(p)?.cues.count == 2 }
        XCTAssertTrue(added)
        let b = await Self.ready(p)
        XCTAssertEqual(b?.cues.map(\.text), ["Almost 9:55.", Self.closingText])
        XCTAssertEqual(b?.cues.first?.id, planned.timeCheckCueID, "in its planned slot")
        XCTAssertFalse(voice.texts.contains { $0.contains("9:40") }, "the plan-time reading never renders: \(voice.texts)")
        XCTAssertEqual(voice.texts.count, 2, "the closing line first, then the time check alone")
        XCTAssertTrue(voice.texts[1].contains("9:55"))
        XCTAssertEqual(b?.talkOverCueID, planned.talkOverCueID)
        XCTAssertEqual(b?.talkOverStartSeconds ?? 0, 1 + PreparedDJBreak.talkOverGapSeconds, accuracy: 0.001)
        clock.now = date(9, 53)   // the boundary, on time
        let taken = await p.takeBreak(afterTrack: 0)
        XCTAssertEqual(taken, b.map { .ready($0) })
        XCTAssertNil(b?.droppedTimeCheck)
        XCTAssertEqual(drops.all, [], "nothing dropped, nothing reported")
    }

    // MARK: Stale at the take (Echo blocker 1)

    /// A ready break with "Almost 9:55." for a 9:53 boundary.
    private func readyAt953(_ clock: Clock, _ voice: ScriptedVoice) async -> (DJBreakPreparer, DJBreak, Drops) {
        let later = date(9, 52)
        let p = preparer([route("device", voice)], clock: clock, sleepUntil: { _ in clock.now = later })
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let added = await eventually { await Self.ready(p)?.cues.map(\.text) == ["Almost 9:55.", Self.closingText] }
        XCTAssertTrue(added)
        return (p, planned, drops)
    }

    func testPausedBreakDropsOnlyTheStaleTimeCheckAtTheTake() async {
        let clock = Clock(date(9, 40))
        let voice = ScriptedVoice()
        let (p, planned, drops) = await readyAt953(clock, voice)
        // Paused for ten minutes with the break ready: "Almost 9:55." would air at 10:03.
        clock.now = date(10, 3)
        let outcome = await p.takeBreak(afterTrack: 0)
        guard case .ready(let b) = outcome else { return XCTFail("the break must still air") }
        assertRestOnly(b, planned)
        XCTAssertEqual(b.clips.map(\.cueID), [planned.cues[1].id])
        XCTAssertNil(b.attributions[planned.timeCheckCueID!])
        XCTAssertNil(b.talkOverStartSeconds, "talk-over hooks from the kept clips, as for an earlier drop")
        assertDropped(outcome, planned, .stale, drops)
        XCTAssertEqual(voice.texts.count, 2, "never re-rendered at the take")
    }

    func testSeekBackDropsTheStaleTimeCheckAtTheTake() async {
        let clock = Clock(date(9, 40))
        let (p, planned, drops) = await readyAt953(clock, ScriptedVoice())
        // Seek back two minutes in the song: the ready break is kept, and airs two minutes later.
        let rearmed = await p.rearm(planned, deadline: .seconds(180), onDeviceOnly: false)
        XCTAssertFalse(rearmed, "a ready break is kept on a seek")
        clock.now = date(9, 55).addingTimeInterval(5)   // "Just after 9:55." now
        let outcome = await p.takeBreak(afterTrack: 0)
        assertDropped(outcome, planned, .stale, drops)
        if case .ready(let b) = outcome { assertRestOnly(b, planned) }
    }

    func testShortPauseThatStillReadsTheSameTimeKeepsTheLine() async {
        let clock = Clock(date(9, 40))
        let (p, _, drops) = await readyAt953(clock, ScriptedVoice())
        clock.now = date(9, 54)   // still "Almost 9:55."
        guard case .ready(let b) = await p.takeBreak(afterTrack: 0) else { return XCTFail("airs") }
        XCTAssertEqual(b.cues.map(\.text), ["Almost 9:55.", Self.closingText])
        XCTAssertNil(b.droppedTimeCheck)
        XCTAssertEqual(drops.all, [])
    }

    func testTimeCheckWaitsForItsWindowBeforeTheDeadline() async {
        let clock = Clock(date(9, 40))
        final class Seen: @unchecked Sendable { var at: ContinuousClock.Instant? }
        let seen = Seen()
        let p = preparer([route("device", ScriptedVoice())], clock: clock, sleepUntil: { seen.at = $0 })
        let before = ContinuousClock.now
        await p.prepare(timeCheckBreak(), deadline: .seconds(200), onDeviceOnly: false)
        let added = await eventually { await Self.ready(p)?.cues.count == 2 }
        XCTAssertTrue(added)
        guard let at = seen.at else { return XCTFail("never waited") }
        // 200 s deadline: the line renders 72 s before it (about 75 s before the boundary).
        let wait = at - before
        XCTAssertGreaterThanOrEqual(wait, .seconds(128))
        XCTAssertLessThan(wait, .seconds(129))
    }

    // MARK: Teardown (macOS abort at ffe040c)

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// A preparer nobody holds is freed, and its time-check wait is cancelled with it: a
    /// long wait never wakes up later inside another test.
    func testFreedPreparerCancelsItsTimeCheckWait() async {
        let clock = Clock(date(9, 40))
        let waiting = Flag(), cancelled = Flag()
        let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void = { _ in
            waiting.set()
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.set(); throw error }
        }
        var p: DJBreakPreparer? = DJBreakPreparer(
            renderer: VoiceRenderer(routes: [route("device", ScriptedVoice())], budget: VoiceBudget(dailyCapMicrodollars: 0),
                                    cache: InMemoryAudioCache(), revocations: NarrationRevocations()),
            userID: "u", stationID: "s", talkOverEnabled: { true }, now: { clock.now }, sleepUntil: sleepUntil)
        await p?.prepare(timeCheckBreak(), deadline: .seconds(200), onDeviceOnly: false)
        let isWaiting = await eventually { waiting.isSet }
        XCTAssertTrue(isWaiting)
        weak let freed = p
        p = nil
        let gone = await eventually { cancelled.isSet }
        XCTAssertTrue(gone, "the wait is cancelled when the preparer is freed")
        XCTAssertNil(freed)
    }

    // MARK: Late

    func testBreakTakenBeforeTheWindowAirsWithoutTheTimeCheck() async {
        let clock = Clock(date(9, 40))
        let voice = ScriptedVoice()
        let p = preparer([route("device", voice)], clock: clock, sleepUntil: { _ in try await Task.sleep(for: .seconds(60)) })
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .seconds(200), onDeviceOnly: false)
        let isReady = await eventually { await p.isReady(afterTrack: 0) }
        XCTAssertTrue(isReady, "the rest of the break is ready on its own")
        let outcome = await p.takeBreak(afterTrack: 0)
        guard case .ready(let b) = outcome else { return XCTFail("the break must still air") }
        assertRestOnly(b, planned)
        assertDropped(outcome, planned, .taken, drops)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(voice.texts, [Self.closingText], "the time check never renders after the take")
        let leftover = await p.testResult(afterTrack: 0)
        XCTAssertNil(leftover)
    }

    func testTimeCheckStillRenderingAtBreakStartIsDropped() async {
        let clock = Clock(date(9, 40))
        let voice = ScriptedVoice(delay: { $0.contains("9:40") ? .milliseconds(300) : nil })
        let p = preparer([route("device", voice)], clock: clock)
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let rendering = await eventually { voice.texts.count == 2 }
        XCTAssertTrue(rendering)
        let outcome = await p.takeBreak(afterTrack: 0)
        guard case .ready(let b) = outcome else { return XCTFail("the break must still air") }
        assertRestOnly(b, planned)
        assertDropped(outcome, planned, .taken, drops)
        try? await Task.sleep(for: .milliseconds(500))   // past the slow render
        let leftover = await p.testResult(afterTrack: 0)
        XCTAssertNil(leftover, "a late finish never lands after the take")
    }

    func testTimeCheckThatMissesTheDeadlineIsDroppedAndTheBreakStaysReady() async {
        let clock = Clock(date(9, 40))
        let voice = ScriptedVoice(delay: { $0.contains("9:40") ? .seconds(2) : nil })
        let p = preparer([route("device", voice)], clock: clock)
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .milliseconds(400), onDeviceOnly: false)
        let rendering = await eventually { voice.texts.count == 2 }
        XCTAssertTrue(rendering)
        try? await Task.sleep(for: .milliseconds(2300))   // past the deadline and the slow render
        assertRestOnly(await Self.ready(p), planned)
        let outcome = await p.takeBreak(afterTrack: 0)
        guard case .ready(let b) = outcome else { return XCTFail("the break must still air") }
        assertRestOnly(b, planned)
        assertDropped(outcome, planned, .late, drops)
    }

    func testTimeCheckWithNoTimeLeftIsDroppedAsLate() async {
        let clock = Clock(date(9, 40))
        let voice = ScriptedVoice()
        // The window wait returns after the deadline has passed: no time left to render.
        let p = preparer([route("device", voice)], clock: clock,
                         sleepUntil: { try await ContinuousClock().sleep(until: $0 + DJBreakPreparer.timeCheckLead + .milliseconds(200)) })
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .milliseconds(100), onDeviceOnly: false)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(voice.texts, [Self.closingText], "never sent")
        assertDropped(await p.takeBreak(afterTrack: 0), planned, .late, drops)
    }

    // MARK: Failed

    func testFailedTimeCheckRenderDropsOnlyThatLine() async {
        let clock = Clock(date(9, 40))
        let voice = ScriptedVoice(fail: { text, _ in text.contains("9:40") })
        let p = preparer([route("device", voice)], clock: clock)
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let tried = await eventually { voice.texts.count == 2 }
        XCTAssertTrue(tried)
        try? await Task.sleep(for: .milliseconds(100))
        assertRestOnly(await Self.ready(p), planned)
        let outcome = await p.takeBreak(afterTrack: 0)
        guard case .ready(let b) = outcome else { return XCTFail("the break must still air") }
        assertRestOnly(b, planned)
        assertDropped(outcome, planned, .renderFailed, drops)
    }

    func testOverCapTimeCheckIsDroppedNotTheBreak() async {
        let clock = Clock(date(9, 40))
        // 1 s closing line; a 20 s time check would push the main segment past its 15 s cap.
        let voice = ScriptedVoice(seconds: { $0.contains("9:40") ? 20 : 1 })
        let p = preparer([route("device", voice)], clock: clock)
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let tried = await eventually { voice.texts.count == 2 }
        XCTAssertTrue(tried)
        try? await Task.sleep(for: .milliseconds(100))
        assertRestOnly(await Self.ready(p), planned)
        assertDropped(await p.takeBreak(afterTrack: 0), planned, .overCap, drops)
    }

    // MARK: Voice and cost

    func testTimeCheckUsesTheVoiceTheBreakWasRenderedIn() async {
        let clock = Clock(date(9, 40))
        // The first route fails its first call (the closing line), so the break is in the second
        // voice. The time check must not come back to the first one.
        let premium = ScriptedVoice(fail: { _, call in call == 1 })
        let standard = ScriptedVoice()
        let p = preparer([route("premium", premium), route("device", standard)], clock: clock)
        await p.prepare(timeCheckBreak(), deadline: .seconds(60), onDeviceOnly: false)
        let added = await eventually { await Self.ready(p)?.cues.count == 2 }
        XCTAssertTrue(added)
        let b = await Self.ready(p)
        XCTAssertEqual(b?.clips.map(\.audio.voiceID), ["device-voice", "device-voice"])
        XCTAssertEqual(b?.cues.map(\.providerID), ["device", "device"])
        XCTAssertEqual(premium.texts.count, 1, "never re-voiced in the first route: \(premium.texts)")
    }

    func testTimeCheckFailingInTheBreaksVoiceIsNotReVoiced() async {
        let clock = Clock(date(9, 40))
        let premium = ScriptedVoice(fail: { text, _ in text.contains("9:40") })
        let standard = ScriptedVoice()
        let p = preparer([route("premium", premium), route("device", standard)], clock: clock)
        let planned = timeCheckBreak()
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let tried = await eventually { premium.texts.count == 2 }
        XCTAssertTrue(tried)
        try? await Task.sleep(for: .milliseconds(100))
        assertRestOnly(await Self.ready(p), planned)
        XCTAssertTrue(standard.texts.isEmpty, "dropped, not spoken in another voice: \(standard.texts)")
        guard case .ready(let b) = await p.takeBreak(afterTrack: 0) else { return XCTFail("airs") }
        XCTAssertEqual(b.droppedTimeCheck, DJTimeCheckDrop(cueID: planned.timeCheckCueID!, reason: .renderFailed))
    }

    func testPaidVoiceTimeCheckIsChargedThroughTheRendererBudget() async {
        let clock = Clock(date(9, 40))
        let paid = ScriptedVoice()
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000, calendar: eastern, now: { clock.now })
        let p = preparer([route("paid", paid, microdollarsPerThousand: 1000)], clock: clock, budget: budget)
        await p.prepare(timeCheckBreak(), deadline: .seconds(60), onDeviceOnly: false)
        let added = await eventually { await Self.ready(p)?.cues.count == 2 }
        XCTAssertTrue(added)
        guard paid.texts.count == 2 else { return XCTFail("both lines in the paid voice: \(paid.texts)") }
        // 1 microdollar per character: every character sent, the late line included, is charged.
        let charged = await budget.committed(userID: "u")
        XCTAssertEqual(charged, paid.texts.reduce(0) { $0 + $1.count })
        XCTAssertGreaterThan(paid.texts[1].count, 0)
    }

    func testTimeCheckOverThePaidCapIsDroppedAndTheBreakAirs() async {
        let clock = Clock(date(9, 40))
        let paid = ScriptedVoice()
        // Room for the closing line only.
        let budget = VoiceBudget(dailyCapMicrodollars: Self.closingText.count + 2, calendar: eastern, now: { clock.now })
        let p = preparer([route("paid", paid, microdollarsPerThousand: 1000)], clock: clock, budget: budget)
        let planned = timeCheckBreak()
        let drops = await drops(p)
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let isReady = await eventually { await p.isReady(afterTrack: 0) }
        XCTAssertTrue(isReady)
        try? await Task.sleep(for: .milliseconds(150))
        assertRestOnly(await Self.ready(p), planned)
        XCTAssertEqual(paid.texts.count, 1, "over the cap: never sent")
        assertDropped(await p.takeBreak(afterTrack: 0), planned, .overCap, drops)
    }

    // MARK: Whole-break cap and trimmed lines (#320 merged)

    private func line(_ order: Int, _ text: String) -> NarrationCue {
        NarrationCue(id: UUID(), order: order, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 1, maxSeconds: 12, sourceItemID: nil, source: nil, provenance: nil)
    }

    /// `first`, the time check, the closing line; `optional` in drop order.
    private func threeLineBreak(_ first: NarrationCue, optional: (_ first: UUID, _ time: UUID) -> [UUID]) -> DJBreak {
        let time = line(2, "It's 9:40."), closing = line(3, Self.closingText)
        var b = DJBreak(afterTrack: 0, cues: [first, time, closing],
                        attributions: [first.id: .presenter, time.id: .presenter,
                                       closing.id: .trackMetadata(trackIDs: ["t1"], origin: .catalog)])
        b.talkOverCueID = closing.id
        b.optionalCueIDs = optional(first.id, time.id)
        b.timeCheck = DJPlannedTimeCheck(cueID: time.id, plannedAt: date(9, 40),
                                         templates: [.on: "It's {time}.", .comingUp: "Almost {time}.", .justAfter: "Just after {time}."],
                                         calendar: eastern, style: .twelveHour)
        return b
    }

    func testTimeCheckOverTheWholeBreakCapIsDroppedNotTrimmingAnotherLine() async {
        let clock = Clock(date(9, 40))
        // Opener 5 s + closing 3 s + 0.3 s pause = 8.3 s; with a 4 s time check 12.3 s, over 12 s.
        let voice = ScriptedVoice(seconds: { $0.contains("9:4") ? 4 : $0.hasPrefix("Up next") ? 3 : 5 })
        let p = preparer([route("device", voice)], clock: clock)
        let planned = threeLineBreak(line(1, "That was a long one."), optional: { _, time in [time] })
        let drops = await drops(p)
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let tried = await eventually { voice.texts.count == 3 }
        XCTAssertTrue(tried, "the time check rendered: \(voice.texts)")
        try? await Task.sleep(for: .milliseconds(150))
        let b = await Self.ready(p)
        XCTAssertEqual(b?.cues.map(\.id), [planned.cues[0].id, planned.cues[2].id], "only the time check dropped")
        XCTAssertEqual(b?.trimmedCueIDs, [], "not an optional-line trim: reported as a time-check drop")
        XCTAssertEqual(b?.talkOverCueID, planned.talkOverCueID)
        let outcome = await p.takeBreak(afterTrack: 0)
        assertDropped(outcome, planned, .overCap, drops)
        let plan = DJSessionPlan(breaks: [planned], briefingReport: NarrationScheduleReport(entries: []))
        XCTAssertEqual(plan.capReport(afterBreaks: [0: outcome]).trimmedOptionalLines, [:])
    }

    func testTimeCheckGoesInItsPlannedPlaceAfterATrimmedLineAndKeepsTheTrimRecord() async {
        let clock = Clock(date(9, 40))
        // Color 9 s + closing 3 s + pause: 12.3 s, so color is trimmed; the 1 s time check fits.
        let voice = ScriptedVoice(seconds: { $0.contains("9:4") ? 1 : $0.hasPrefix("Up next") ? 3 : 9 })
        let p = preparer([route("device", voice)], clock: clock)
        let planned = threeLineBreak(line(1, "Grey morning out there."), optional: { color, time in [time, color] })
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let added = await eventually { await Self.ready(p)?.cues.count == 2 }
        XCTAssertTrue(added)
        let b = await Self.ready(p)
        XCTAssertEqual(b?.cues.map(\.id), [planned.cues[1].id, planned.cues[2].id], "time check, then the closing line last")
        XCTAssertEqual(b?.clips.map(\.cueID), b?.cues.map(\.id))
        XCTAssertEqual(b?.trimmedCueIDs, [planned.cues[0].id], "the trim record survives the late line")
        XCTAssertEqual(b.map { Set($0.attributions.keys) }, Set([planned.cues[1].id, planned.cues[2].id]))
        XCTAssertEqual(b?.talkOverCueID, planned.talkOverCueID)
    }
}
