import Foundation

// Prepare-ahead for DJ breaks. Speech is rendered *before* its song boundary,
// within a deadline. At the boundary the audio engine asks for the break without
// waiting: if it is not ready, or rendering failed, timed out or hit the cost
// cap with no fallback, the break is skipped and the next song starts on time.

public enum DJBreakSkipReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// Every route failed.
    case renderFailed
    /// A clip was longer than its cue allows.
    case overDuration
    /// Paid routes were over the user's daily cap and no free route succeeded.
    case costCap
    /// Rendering did not finish within the preparation deadline.
    case timedOut
    /// The boundary arrived while rendering was still in progress.
    case notReadyAtBoundary
    /// Measured audio for the whole break exceeded the cadence cap.
    case overBreakBudget
    /// Nothing was prepared for this boundary.
    case notPlanned
    /// The song did not end naturally (user skip, queue change): never talk over or after a cut song.
    case notNaturalBoundary
    /// Preparation was cancelled because the boundary will not come (station change, queue replaced, stop).
    case cancelled
    /// A personal item the break was built from was deleted or its consent revoked.
    case sourceRevoked
    /// Build 18 P0: the system was still holding playback (a call, another app's audio) when
    /// the break would have started, so it was skipped.
    case interrupted
}

/// Why a planned time-check line did not air (#347). Only that line is dropped; the rest of
/// the break airs as prepared.
public enum DJTimeCheckDropReason: String, Equatable, Sendable, CaseIterable {
    /// Its render could not start or finish before the render deadline.
    case late
    /// Its render failed (provider error, revoked, over duration, no template).
    case renderFailed
    /// Over a cap: its own line length, a break cap (measured main, closing or 12 s whole-break)
    /// or the paid-voice cap.
    case overCap
    /// The voice the break was rendered in is not available for it (never re-voiced).
    case noVoice
    /// The break was taken while the line was still waiting or rendering.
    case taken
    /// At the take the clock no longer reads the rendered time (pause, seek back).
    case stale
}

/// A dropped time-check line: its cue ID and the reason code. No text.
public struct DJTimeCheckDrop: Equatable, Sendable {
    public let cueID: UUID
    public let reason: DJTimeCheckDropReason
    public init(cueID: UUID, reason: DJTimeCheckDropReason) {
        self.cueID = cueID
        self.reason = reason
    }
}

/// Audio ready to play at a boundary, in order, with measured durations.
public struct PreparedDJBreak: Equatable, Sendable {
    public let afterTrack: Int
    /// Cues with `renderedSeconds`, `voiceID`, `providerID` and `audioCacheKey` filled in.
    public let cues: [NarrationCue]
    public let clips: [RenderedClip]
    /// Where every spoken cue's words came from (same keys as `cues`).
    public let attributions: [UUID: SpokenAttribution]
    public var includesBriefing: Bool { cues.contains { $0.isContent } }
    public var measuredSeconds: Double { clips.reduce(0) { $0 + $1.audio.seconds } }
    /// The planned talk-over closing cue (`DJBreak.talkOverCueID`). The hooks below are derived
    /// from `cues`/`clips`, so a rebuild that drops cues recomputes or clears them on its own.
    public var talkOverCueID: UUID? = nil
    /// Optional lines (`DJBreak.optionalCueIDs`) dropped because the measured audio ran over
    /// `DJCadence.maxOrdinaryBreakSeconds`. See `DJSessionPlan.capReport(afterBreaks:)`.
    public var trimmedCueIDs: [UUID] = []
    /// The planned time-check line, when it does not air in this break, and why (#347).
    /// Set by `takeBreak`; reason code and cue ID only.
    public var droppedTimeCheck: DJTimeCheckDrop? = nil
    /// The clock reading the time-check line was written for (its expected air time), while
    /// that line is in the break. `takeBreak` checks it against the clock at the take.
    public var timeCheckAirTime: Date? = nil

    /// Speech gap before the closing line, in seconds. A pause between two lines of speech,
    /// not compensation for player latency.
    public static let talkOverGapSeconds = 0.3

    /// The closing cue's clip, when it is still the last clip and something plays before it.
    private var talkOverClip: (index: Int, clip: RenderedClip)? {
        guard let id = talkOverCueID, cues.count == clips.count, cues.count > 1,
              cues.last?.id == id, let last = clips.last, last.cueID == id else { return nil }
        return (clips.count - 1, last)
    }

    /// Hook for the player (Fry): when the closing line's audio starts within the break, in
    /// seconds from the first clip's start: the rendered durations of every clip before it plus
    /// `talkOverGapSeconds`. Nil when there is no closing cue (or it was dropped). Clips still
    /// play one at a time, back to back; this never overlaps two lines of speech.
    public var talkOverStartSeconds: Double? {
        guard let (index, _) = talkOverClip else { return nil }
        return clips[..<index].reduce(0) { $0 + $1.audio.seconds } + Self.talkOverGapSeconds
    }

    /// Hook for the player (Fry): the closing cue's rendered clip duration, so the next song
    /// can swell back in under it. Nil exactly when `talkOverStartSeconds` is nil.
    public var talkOverSeconds: Double? { talkOverClip?.clip.audio.seconds }
}

public enum DJBreakOutcome: Equatable, Sendable {
    case ready(PreparedDJBreak)
    case skipped(DJBreakSkipReason)
}

/// Renders planned breaks ahead of time and hands them out at boundaries without blocking.
public actor DJBreakPreparer {
    private let renderer: VoiceRenderer
    private let userID: String
    private let stationID: String
    private let breakCap: @Sendable (DJBreak) -> BreakCap
    /// Bundled pre-rendered presenter lines, tried per whole cue before the renderer. Nil or an
    /// empty manifest (build 27) changes nothing.
    private let bundledClips: BundledClipResolver?
    /// Whether DJ talk-over is on, read when a render starts (`prepare`, `rearm`). P0 build 26
    /// (-Fry): the 4 s closing cap is a talk-over cap, so it only applies while this is true.
    private let talkOverEnabled: @Sendable () -> Bool
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var results: [Int: DJBreakOutcome] = [:]
    private var planned: [Int: DJBreak] = [:]
    /// Song scrubbing (-Atlas): boundaries a seek may still re-arm. Opened when song `k`
    /// starts (`openBoundary`); closed when boundary `k` is taken (`takeBreak`) or everything is
    /// dropped (`cancelAll`), so a seek that resumes after the song already ended (or the queue
    /// was replaced) cannot start an orphan render for a boundary that went by.
    private var openForRearm: Set<Int> = []
    /// Song scrubbing (-Atlas): open boundaries whose one seek re-arm is spent.
    private var rearmed: Set<Int> = []
    private var observers: [@Sendable (DJBreakEvent) -> Void] = []
    /// Boundaries already taken (`takeBreak`) in this queue. A taken boundary never prepares or
    /// re-arms again: a duplicate `songStarted(k)` after the talk-over's early take (song k is
    /// still playing) must not render, and spend on, a second break (-Fry, Sentinel #210).
    /// Cleared with everything else by `cancelAll()` (new queue: indices restart).
    private var taken: Set<Int> = []
    /// #347: the planned time check of each boundary being prepared, and why its line was
    /// dropped before the take (late, failed, over cap, no voice). Read and cleared by `takeBreak`.
    private var timeChecks: [Int: DJPlannedTimeCheck] = [:]
    private var timeCheckDrops: [Int: DJTimeCheckDropReason] = [:]
    /// The render deadline of each boundary's time-check line. At the take, a line that is not
    /// there and has no recorded reason is `.late` once this has passed, whether or not the
    /// prepare task got to record it first, so the reason never depends on task scheduling.
    private var timeCheckDeadlines: [Int: ContinuousClock.Instant] = [:]
    private var timeCheckDropObservers: [@Sendable (Int, DJTimeCheckDrop) -> Void] = []
    /// Lane 2 time checks (Orion option (a), #347): the clock the time-check line is read from
    /// when it renders, and the wait until its render starts. Injected; Core never calls `Date()`.
    private let now: @Sendable () -> Date
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    /// How long before the render deadline the time-check line renders: 72 s, so about 75 s
    /// before the boundary at the default 3 s margin (Orion: 60-90 s). A song that starts with
    /// less left renders it straight after the rest of the break.
    public static let timeCheckLead: Duration = .seconds(72)
    /// The default gap between the render deadline and the boundary (`deadline(remainingInSong:)`).
    public static let boundaryMargin: Duration = .seconds(3)

    /// The production clock and wait, as plain nonisolated functions, so nothing the prepare task
    /// calls carries the caller's isolation. The init takes `sleepUntil` as an optional and falls
    /// back to `sleep(until:)` in its body, never as a default argument: an async function value in
    /// a public default argument is emitted into every client object, and with Xcode 26.5/26.6
    /// (Swift 6.3.x) those copies can record a smaller async context than the library's body uses.
    /// If the macOS linker pairs them, the wait writes past its task allocation and the next
    /// `swift_task_dealloc` aborts with "freed pointer was not the last allocation"
    /// (swiftlang/swift#92017; macOS CI on #347). `systemNow` is synchronous, so it has no async
    /// context and may stay a default. -Fry
    @Sendable public nonisolated static func systemNow() -> Date { Date() }
    @Sendable public nonisolated static func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await Task.sleep(until: deadline, clock: .continuous)
    }

    public enum DJBreakEvent: Equatable, Sendable {
        case preparing(afterTrack: Int, includesBriefing: Bool)
        case prepared(afterTrack: Int, includesBriefing: Bool, seconds: Double)
        case skipped(afterTrack: Int, DJBreakSkipReason)
    }

    /// `talkOverEnabled` defaults to `DJTalkoverFlag.isEnabled()` (the saved Settings toggle, else
    /// ON as on a live station), the same flag `TalkoverCoordinator` reads.
    public init(renderer: VoiceRenderer, userID: String, stationID: String, cadence: DJCadence = .init(),
                talkOverEnabled: @escaping @Sendable () -> Bool = { DJTalkoverFlag.isEnabled() },
                bundledClips: BundledClipResolver? = nil,
                now: @escaping @Sendable () -> Date = DJBreakPreparer.systemNow,
                sleepUntil: (@Sendable (ContinuousClock.Instant) async throws -> Void)? = nil) {
        self.renderer = renderer
        self.bundledClips = bundledClips
        self.now = now
        // Nil default, filled in here: an async function value in a default argument is emitted
        // into every client object, and Swift 6.3.3 gives those copies a smaller async context
        // than the library's own (32 vs 48 bytes). When the linker pairs the library body with a
        // client's size record, the wait writes past its allocation and the task allocator aborts
        // with "freed pointer was not the last allocation" (macOS CI at ffe040c and 45044e7;
        // swiftlang/swift#92017). Here the wait is emitted once, in this module. -Fry
        self.sleepUntil = sleepUntil ?? DJBreakPreparer.sleep(until:)
        self.userID = userID
        self.stationID = stationID
        self.talkOverEnabled = talkOverEnabled
        // Measured audio. Briefing: 45 s in total, closing line included. Ordinary: the main
        // segment is capped at 15 s and a talk-over closing line at 4 s, separately. A closing
        // line over 4 s (or any closing line with talk-over off) loses its talk-over marker and,
        // when over 4 s, counts toward the 15 s main budget instead of skipping the break
        // (P0 build 26, -Fry). See `BreakCap`. An ordinary break's whole measured audio, closing
        // line included, is also capped at `maxOrdinaryBreakSeconds` (12 s): optional lines are
        // dropped in the planner's order to fit, and the break is skipped if opener plus closing
        // alone run over it.
        // Build 34: the show opener (`DJBreakShape.showOpener`, never with briefing content) has
        // its own cap, `maxOpenerBreakSeconds` (22 s), for the main segment and the whole break.
        self.breakCap = { djBreak in
            if djBreak.hasBriefing {
                return BreakCap(main: Double(cadence.maxBriefingBreakSeconds), closingCueID: nil, closing: 0)
            }
            let opener = djBreak.shape == .showOpener
            return BreakCap(main: Double(opener ? cadence.maxOpenerBreakSeconds : cadence.maxTransitionSeconds),
                            closingCueID: djBreak.talkOverCueID, closing: Double(cadence.maxClosingSeconds),
                            whole: Double(opener ? cadence.maxOpenerBreakSeconds : cadence.maxOrdinaryBreakSeconds),
                            optional: djBreak.optionalCueIDs)
        }
    }

    public func observe(_ observer: @escaping @Sendable (DJBreakEvent) -> Void) { observers.append(observer) }

    /// #347: told when a break is taken without its planned time-check line (boundary, cue ID
    /// and reason code only). Line-level, so separate from the break events the Studio shows.
    public func observeTimeCheckDrops(_ observer: @escaping @Sendable (Int, DJTimeCheckDrop) -> Void) {
        timeCheckDropObservers.append(observer)
    }

    /// Render deadline for a song with `remaining` time left: `remaining - margin`, or nil if too late to prepare.
    public static func deadline(remainingInSong remaining: Duration, margin: Duration = boundaryMargin) -> Duration? {
        remaining > margin ? remaining - margin : nil
    }

    /// Starts rendering now. `deadline` must end before the boundary (see `deadline(remainingInSong:)`).
    /// `onDeviceOnly` (a station with a library seed) renders on the on-device, free routes only;
    /// with none configured the break is skipped as `.renderFailed`, never sent off the device.
    /// No default: every caller must decide, so a new call site cannot silently skip the gate.
    ///
    /// Lane 2 time checks (Orion option (a), #347): a break with a time check renders in the same
    /// task, in two steps. First every other cue, as before; the break is then ready and airs as
    /// it is if nothing more happens. Then, `timeCheckLead` before the deadline, the time-check
    /// line alone: written from `now()` at that moment (never from the plan), rendered by this
    /// renderer narrowed to the voice the break's clips used (paid routes are charged by the
    /// renderer as for every cue), and added only if it finishes before the deadline, before the
    /// break is taken, and within the break's cap. Otherwise the line is dropped and the rest of
    /// the prepared break airs unchanged.
    public func prepare(_ djBreak: DJBreak, deadline: Duration, onDeviceOnly: Bool) {
        let k = djBreak.afterTrack
        guard tasks[k] == nil, results[k] == nil, !taken.contains(k) else { return }
        planned[k] = djBreak
        emit(.preparing(afterTrack: k, includesBriefing: djBreak.hasBriefing))
        let renderer = onDeviceOnly ? self.renderer.onDeviceOnly : self.renderer
        let userID = userID, stationID = stationID, cap = breakCap(djBreak).talkOver(talkOverEnabled())
        // The time check is held back from the first step (its plan-time words never render).
        // Looked up here, outside the async task: no non-escaping closure is formed inside it
        // (a suspected trigger of the Xcode 26.6 task-allocator abort, see 10468a2). -Fry
        let plannedLine = djBreak.timeCheck.flatMap { tc in djBreak.cues.first { $0.id == tc.cueID } }
        let timeCheck = plannedLine == nil ? nil : djBreak.timeCheck
        let rest: DJBreak
        if let timeCheck { rest = Self.removing(timeCheck.cueID, from: djBreak) } else { rest = djBreak }
        let end = ContinuousClock.now + deadline
        let now = now, sleepUntil = sleepUntil
        let bundled = bundledClips
        timeChecks[k] = timeCheck
        timeCheckDrops[k] = nil
        timeCheckDeadlines[k] = timeCheck == nil ? nil : end
        // The task holds the preparer weakly and touches it only in short actor hops, so a
        // preparer nobody holds any more is freed and its `deinit` cancels the task. A long
        // time-check wait never outlives its preparer (a leaked wait woke up during a later,
        // unrelated test when the macOS abort hit, #347 at ffe040c). The render steps are
        // static functions that return values: no closure, `let` or result is held across
        // an await except the escaping `@Sendable` work given to `withTimeout`. -Fry
        tasks[k] = Task { [weak self] in
            let outcome = await Self.renderRest(rest, renderer: renderer, userID: userID, stationID: stationID,
                                                cap: cap, deadline: deadline, bundled: bundled)
            await self?.finish(k, outcome)
            guard let timeCheck, let plannedLine, let renderer, case .ready(let main) = outcome else { return }
            // Same task, same deadline: wait for the time-check window (cancelled by takeBreak,
            // cancelAll, purge or deinit like any render), then read the clock and render the line.
            // Cancelled here or below: taken first (`takeBreak` reports it) or cancelled.
            let late = await Self.renderTimeCheck(timeCheck, plannedLine, after: main, in: djBreak, renderer: renderer,
                                                  userID: userID, stationID: stationID, end: end,
                                                  now: now, sleepUntil: sleepUntil)
            guard !Task.isCancelled else { return }
            switch late {
            case .cancelled: return
            case .dropped(let reason): await self?.dropTimeCheck(k, reason)
            case .rendered(let line, let clip, let airTime):
                await self?.addTimeCheck(k, line, clip, airTime: airTime, to: main, in: djBreak, cap: cap)
            }
        }
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    /// Step 1 of a prepare task: every cue but the held-back time check, under the deadline.
    nonisolated static func renderRest(_ rest: DJBreak, renderer: VoiceRenderer?, userID: String, stationID: String,
                                       cap: BreakCap, deadline: Duration,
                                       bundled: BundledClipResolver? = nil) async -> DJBreakOutcome {
        guard let renderer else { return .skipped(.renderFailed) }
        guard !rest.cues.isEmpty else { return .skipped(.notPlanned) }
        let work: @Sendable () async -> DJBreakOutcome = {
            await render(rest, renderer: renderer, userID: userID, stationID: stationID, cap: cap, bundled: bundled)
        }
        guard let outcome = try? await VoiceRenderer.withTimeout(deadline, work) else { return .skipped(.timedOut) }
        return outcome
    }

    enum LateTimeCheck: Sendable {
        case cancelled
        case dropped(DJTimeCheckDropReason)
        case rendered(NarrationCue, RenderedClip, airTime: Date)
    }

    /// Step 2: wait for the time-check window, write the line for its expected air time and
    /// render it alone in the break's voice, inside what is left of the deadline.
    nonisolated static func renderTimeCheck(_ timeCheck: DJPlannedTimeCheck, _ plannedLine: NarrationCue,
                                            after main: PreparedDJBreak, in djBreak: DJBreak, renderer: VoiceRenderer,
                                            userID: String, stationID: String, end: ContinuousClock.Instant,
                                            now: @escaping @Sendable () -> Date,
                                            sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void)
        async -> LateTimeCheck {
        guard (try? await sleepUntil(end - timeCheckLead)) != nil, !Task.isCancelled else { return .cancelled }
        guard let voice = sameVoice(as: main, in: renderer) else { return .dropped(.noVoice) }
        // The time it will be on air (Echo, #347): now plus what is left before the boundary.
        let toAir = end - ContinuousClock.now + boundaryMargin
        let airTime = now().addingTimeInterval(seconds(toAir))
        guard let text = timeCheck.text(at: airTime) else { return .dropped(.renderFailed) }
        let line = cue(plannedLine, saying: text)
        let attribution = djBreak.attributions[line.id]
        let left = end - ContinuousClock.now
        guard left > .zero else { return .dropped(.late) }
        let work: @Sendable () async -> Result<RenderedClip, VoiceRenderer.Failure> = {
            await voice.render(line, userID: userID, stationID: stationID, attribution: attribution)
        }
        guard let rendered = try? await VoiceRenderer.withTimeout(left, work) else {
            return Task.isCancelled ? .cancelled : .dropped(.late)
        }
        switch rendered {
        case .success(let clip): return .rendered(line, clip, airTime: airTime)
        case .failure(let failure): return .dropped(timeCheckDropReason(failure))
        }
    }

    /// Records why boundary `k`'s time-check line was dropped before the take, while `k` is
    /// still being prepared by this task (a cancelled or replaced render records nothing).
    private func dropTimeCheck(_ k: Int, _ reason: DJTimeCheckDropReason) {
        guard tasks[k] != nil, timeChecks[k] != nil else { return }
        timeCheckDrops[k] = reason
    }

    static func timeCheckDropReason(_ failure: VoiceRenderer.Failure) -> DJTimeCheckDropReason {
        switch skipReason(failure) {
        case .costCap, .overDuration: .overCap
        case .timedOut: .late
        default: .renderFailed
        }
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// `djBreak` without cue `id` (and its attribution); talk-over and shape kept.
    static func removing(_ id: UUID, from djBreak: DJBreak) -> DJBreak {
        var rest = DJBreak(afterTrack: djBreak.afterTrack, cues: djBreak.cues.filter { $0.id != id },
                           attributions: djBreak.attributions.filter { $0.key != id })
        rest.talkOverCueID = djBreak.talkOverCueID
        rest.shape = djBreak.shape
        rest.optionalCueIDs = djBreak.optionalCueIDs.filter { $0 != id }
        return rest
    }

    /// The renderer narrowed to the one route (provider and voice) the break's closing clip used,
    /// sharing its budget, cache and revocations, so the time check is in the break's voice.
    /// Nil when that route is not in `renderer` (the line is dropped, never re-voiced).
    static func sameVoice(as main: PreparedDJBreak, in renderer: VoiceRenderer) -> VoiceRenderer? {
        guard let last = main.clips.last,
              let route = renderer.routes.first(where: { $0.providerID == last.audio.providerID && $0.voice.id == last.audio.voiceID })
        else { return nil }
        return VoiceRenderer(routes: [route], budget: renderer.budget, cache: renderer.cache, revocations: renderer.revocations)
    }

    /// The planned time-check cue with its render-time words.
    static func cue(_ planned: NarrationCue, saying text: String) -> NarrationCue {
        let seconds = DefaultBriefingPlanner.estimatedSpokenSeconds(for: text)
        return NarrationCue(id: planned.id, order: planned.order, group: planned.group, kind: planned.kind, text: text,
                            estimatedSeconds: seconds, maxSeconds: max(planned.maxSeconds, 8, seconds * 2),
                            sourceItemID: planned.sourceItemID, source: planned.source, provenance: planned.provenance)
    }

    /// Adds the late time-check clip to boundary `k`'s ready break, in its planned place, when
    /// that break is still the one this render made (not taken, cancelled, purged or replaced)
    /// and the whole break still fits its caps, the 12 s whole-break cap included (#320). The
    /// late line is never a reason to trim another line: over a cap, it alone is dropped and the
    /// break airs as prepared. Its slot counts only the planned cues before it that were kept.
    private func addTimeCheck(_ k: Int, _ line: NarrationCue, _ clip: RenderedClip, airTime: Date,
                              to main: PreparedDJBreak, in djBreak: DJBreak, cap: BreakCap) {
        guard tasks[k] != nil, case .ready(let current)? = results[k], current == main else { return }
        let before = Set(djBreak.cues.prefix { $0.id != line.id }.map(\.id))
        let slot = main.cues.filter { before.contains($0.id) }.count
        var spoken = line
        spoken.renderedSeconds = clip.audio.seconds
        spoken.voiceID = clip.audio.voiceID
        spoken.providerID = clip.audio.providerID
        spoken.audioCacheKey = clip.cacheKey
        var cues = main.cues, clips = main.clips
        cues.insert(spoken, at: slot)
        clips.insert(clip, at: slot)
        let fit = cap.fit(clips)
        guard fit != .skip else { return dropTimeCheck(k, .overCap) }
        if let whole = cap.whole, BreakCap.spokenSeconds(clips, closingCueID: cap.closingCueID) > whole {
            return dropTimeCheck(k, .overCap)
        }
        let kept = Set(cues.map(\.id))
        var ready = PreparedDJBreak(afterTrack: k, cues: cues, clips: clips,
                                    attributions: djBreak.attributions.filter { kept.contains($0.key) },
                                    talkOverCueID: fit == .keepMarker ? djBreak.talkOverCueID : nil,
                                    trimmedCueIDs: main.trimmedCueIDs)
        ready.timeCheckAirTime = airTime
        results[k] = .ready(ready)
    }

    /// Song scrubbing (-Atlas): a user seek changed the time left before boundary `k`.
    /// A render in flight or a ready break is kept (no second render, no extra spend; a render
    /// that cannot finish before the new boundary is skipped there as `.notReadyAtBoundary`, so
    /// music never waits). A render starts when nothing was started for `k`, or when the last
    /// one only ran out of time (`.timedOut`) and the seek gave it time again. Every other skip
    /// (revoked, cost cap, failure, cut, cancelled) is final.
    /// At most ONE re-arm per boundary: scrubbing back and forth must not restart a render (and
    /// spend voice characters) again and again. Starting a break that never started rendering
    /// counts as that one re-arm; after it, a second timeout stays a final skip until the
    /// boundary is taken. Returns whether a render started.
    /// `onDeviceOnly` is the library-seed gate, exactly as in `prepare`.
    @discardableResult
    public func rearm(_ djBreak: DJBreak, deadline: Duration, onDeviceOnly: Bool) -> Bool {
        let k = djBreak.afterTrack
        guard mayRearm(afterTrack: k) else { return false }
        rearmed.insert(k)
        results[k] = nil
        prepare(djBreak, deadline: deadline, onDeviceOnly: onDeviceOnly)
        return true
    }

    /// Song `k` started: seeks may re-arm boundary `k` (once) until it is taken or cancelled.
    /// A repeated start report for a song whose boundary is already open keeps the spent re-arm,
    /// so a duplicate start never buys a second one.
    public func openBoundary(afterTrack k: Int) {
        if openForRearm.insert(k).inserted { rearmed.remove(k) }
    }

    /// True when `rearm` would start a render for boundary `k`.
    public func mayRearm(afterTrack k: Int) -> Bool {
        guard openForRearm.contains(k), tasks[k] == nil, !rearmed.contains(k), !taken.contains(k) else { return false }
        switch results[k] {
        case nil, .skipped(.timedOut)?: return true
        default: return false
        }
    }

    /// Test hook: true when boundary `k` was taken in this queue (never prepared again).
    func testTaken(afterTrack k: Int) -> Bool { taken.contains(k) }
    /// Test hook: boundaries with a render in flight.
    var testInFlight: Set<Int> { Set(tasks.keys) }
    /// Test hook: why boundary `k`'s time-check line was dropped before the take, if it was.
    func testTimeCheckDrop(afterTrack k: Int) -> DJTimeCheckDropReason? { timeCheckDrops[k] }
    /// Test hook: the recorded outcome for boundary `k`.
    func testResult(afterTrack k: Int) -> DJBreakOutcome? { results[k] }
    /// Test hook: records an outcome as if a render for `k` had finished with it.
    func testRecord(_ outcome: DJBreakOutcome, afterTrack k: Int) {
        tasks.removeValue(forKey: k)?.cancel()
        results[k] = outcome
    }

    /// Called at the boundary. Never waits: returns what is ready or an explicit skip.
    /// `natural` is false when the song was cut (skip, queue change); the break is then dropped.
    /// DJ talk-over (-Fry): true when boundary `k` has a rendered break waiting. Does not take
    /// it, cancel a render or close the boundary, so the normal hand-out is unchanged when
    /// the talk-over does not run.
    public func isReady(afterTrack k: Int) -> Bool {
        if case .ready? = results[k] { return true }
        return false
    }

    public func takeBreak(afterTrack k: Int, natural: Bool = true) -> DJBreakOutcome {
        let timeCheck = timeChecks.removeValue(forKey: k), earlyDrop = timeCheckDrops.removeValue(forKey: k)
        let timeCheckDeadline = timeCheckDeadlines.removeValue(forKey: k)
        defer { tasks[k] = nil; planned[k] = nil; openForRearm.remove(k); rearmed.remove(k); taken.insert(k) }
        guard natural else {
            tasks[k]?.cancel()
            let wasPlanned = tasks[k] != nil || results.removeValue(forKey: k) != nil
            results[k] = .skipped(.notNaturalBoundary)
            if wasPlanned { emit(.skipped(afterTrack: k, .notNaturalBoundary)) }
            return .skipped(.notNaturalBoundary)
        }
        if let result = results.removeValue(forKey: k) {
            tasks[k]?.cancel()   // a time-check line still rendering is dropped (#347)
            guard let timeCheck, case .ready(let prepared) = result else { return result }
            // Past the line's render deadline it can no longer air: `.late`, even if the prepare
            // task has not yet woken to record that (it would race this take). Before it: `.taken`.
            let missing = earlyDrop ?? (timeCheckDeadline.map { ContinuousClock.now >= $0 } == true ? .late : nil)
            return .ready(checkTimeCheck(timeCheck, in: prepared, droppedEarlier: missing))
        }
        guard let task = tasks[k] else { return .skipped(.notPlanned) }
        task.cancel()
        results[k] = .skipped(.notReadyAtBoundary)   // a late finish must not replace this
        emit(.skipped(afterTrack: k, .notReadyAtBoundary))
        return .skipped(.notReadyAtBoundary)
    }

    /// #347, at the take: a time-check line that aired would say the time it was rendered for.
    /// It is kept while it is still true within `timeCheckTolerance` (Echo, #347 follow-up), so a
    /// take just past a minute or a rounding edge keeps a correct line. Further off (a pause, a
    /// seek back), only that clip is dropped (`.stale`). A line that is not there was dropped earlier (its reason), had
    /// passed its render deadline (`.late`, set by `takeBreak`), or was still waiting or rendering (`.taken`). Every drop is set on the break and emitted.
    private func checkTimeCheck(_ timeCheck: DJPlannedTimeCheck, in prepared: PreparedDJBreak,
                                droppedEarlier: DJTimeCheckDropReason?) -> PreparedDJBreak {
        let id = timeCheck.cueID, k = prepared.afterTrack
        var result = prepared
        if let index = prepared.cues.firstIndex(where: { $0.id == id }) {
            guard !Self.timeCheckStillTrue(timeCheck, saying: prepared.cues[index].text,
                                           airTime: prepared.timeCheckAirTime, now: now()) else { return prepared }
            var cues = prepared.cues, clips = prepared.clips
            cues.remove(at: index)
            clips.removeAll { $0.cueID == id }
            // Shorter only: every cap still holds; the closing line and its marker are unchanged.
            result = PreparedDJBreak(afterTrack: k, cues: cues, clips: clips,
                                     attributions: prepared.attributions.filter { $0.key != id },
                                     talkOverCueID: prepared.talkOverCueID, trimmedCueIDs: prepared.trimmedCueIDs)
            result.droppedTimeCheck = DJTimeCheckDrop(cueID: id, reason: .stale)
        } else {
            result.droppedTimeCheck = DJTimeCheckDrop(cueID: id, reason: droppedEarlier ?? .taken)
        }
        if let drop = result.droppedTimeCheck { for observer in timeCheckDropObservers { observer(k, drop) } }
        return result
    }

    /// How far the clock at the take may be from the time-check line's expected air time (Echo).
    public static let timeCheckTolerance: TimeInterval = 90

    /// How far from its rounded time T each kind of line may air (Echo, #357): the rounding gap
    /// at the air time (up to 2 min) plus `timeCheckTolerance`.
    public static let timeCheckComingUpLead: TimeInterval = 210
    public static let timeCheckJustAfterLag: TimeInterval = 210
    public static let timeCheckOnSpread: TimeInterval = 120

    /// Whether a time-check line written for `airTime` may still air at `now`. Both must hold:
    /// - `now` is within `timeCheckTolerance` of `airTime` (either side);
    /// - what the line claims about its rounded time T (read at `airTime` in the planned check's
    ///   calendar) is still true at `now`, by direction (Echo, #357):
    ///   - "Almost / Coming up on T": −210 s ≤ now − T < 0 (never at or after T);
    ///   - "Just after T": 0 ≤ now − T ≤ 210 s (never before T);
    ///   - "It's T": |now − T| < 120 s.
    /// T is an instant, so midnight and the 12 h/24 h wrap need no special case. The words must be
    /// the line rendered for `airTime`; anything else, or no air time, fails closed.
    nonisolated static func timeCheckStillTrue(_ timeCheck: DJPlannedTimeCheck, saying text: String,
                                               airTime: Date?, now: Date) -> Bool {
        guard let airTime, abs(now.timeIntervalSince(airTime)) <= timeCheckTolerance,
              timeCheck.text(at: airTime) == text,
              let claim = roundedTime(at: airTime, calendar: timeCheck.calendar) else { return false }
        let fromT = now.timeIntervalSince(claim.time)
        switch claim.relation {
        case .comingUp: return fromT >= -timeCheckComingUpLead && fromT < 0
        case .justAfter: return fromT >= 0 && fromT <= timeCheckJustAfterLag
        case .on: return abs(fromT) < timeCheckOnSpread
        }
    }

    /// The rounded time T a line read at `date` names, as an instant (the start of T's minute),
    /// and which way it rounded. `DJTimeCheck.roundedInstant`, the value the line was written from.
    nonisolated static func roundedTime(at date: Date, calendar: Calendar) -> (time: Date, relation: DJTimeCheckRelation)? {
        DJTimeCheck.roundedInstant(at: date, calendar: calendar).map { ($0.time, $0.relation) }
    }

    /// Cancels preparation for boundaries that will not happen (station change, queue replaced, stop).
    /// In-flight renders are cancelled (their cost reservations are released), prepared audio is
    /// discarded, and each dropped break is reported as `.skipped(.cancelled)` so no UI keeps
    /// showing a break that will not play. A late render finish is ignored.
    public func cancelAll() {
        let dropped = Set(tasks.keys).union(results.compactMap { if case .ready = $0.value { $0.key } else { nil } })
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        results.removeAll()
        planned.removeAll()
        timeChecks.removeAll()
        timeCheckDrops.removeAll()
        timeCheckDeadlines.removeAll()
        openForRearm.removeAll()
        rearmed.removeAll()
        taken.removeAll()
        for k in dropped.sorted() { emit(.skipped(afterTrack: k, .cancelled)) }
    }

    /// `cancelAll`, except the boundaries in `kept`: those keep rendering, or stay prepared.
    /// Only `DJBreakSession.stationChanged` passes a non-empty set, for a plain music break
    /// with no personal content (it can carry nothing a withdrawal or briefing-off removes).
    public func cancelAll(except kept: Set<Int>) {
        guard !kept.isEmpty else { return cancelAll() }
        let ready = results.compactMap { if case .ready = $0.value { $0.key } else { nil } }
        let dropped = Set(tasks.keys).union(ready).subtracting(kept)
        for k in Set(tasks.keys).union(results.keys).union(planned.keys) where !kept.contains(k) {
            tasks.removeValue(forKey: k)?.cancel()
            results[k] = nil
            planned[k] = nil
            timeChecks[k] = nil
            timeCheckDrops[k] = nil
            timeCheckDeadlines[k] = nil
        }
        // Stale marks are cleared as for a new queue (Sentinel #210), except a kept boundary:
        // that is the playing song's, and if the talk-over already took it early, a duplicate
        // `onSongStarted(k)` must still never render it a second time.
        taken.formIntersection(kept)
        openForRearm.formIntersection(kept)   // a dropped boundary can't be re-armed by a seek
        rearmed.formIntersection(kept)
        for k in dropped.sorted() { emit(.skipped(afterTrack: k, .cancelled)) }
    }

    /// Drops any pending or prepared break built from these personal items (deleted or consent
    /// revoked), so their audio is never played. Pair with `AudioCache.purge(sourceItemIDs:)`.
    public func purge(sourceItemIDs: Set<UUID>) {
        for (k, djBreak) in planned where djBreak.cues.contains(where: { $0.sourceItemID.map(sourceItemIDs.contains) ?? false }) {
            tasks.removeValue(forKey: k)?.cancel()
            planned[k] = nil
            timeChecks[k] = nil
            timeCheckDrops[k] = nil
            timeCheckDeadlines[k] = nil
            results[k] = .skipped(.sourceRevoked)
            emit(.skipped(afterTrack: k, .sourceRevoked))
        }
    }

    private func finish(_ k: Int, _ outcome: DJBreakOutcome) {
        guard results[k] == nil, tasks[k] != nil else { return }  // already taken, cancelled or purged
        results[k] = outcome
        switch outcome {
        case .ready(let b): emit(.prepared(afterTrack: k, includesBriefing: b.includesBriefing, seconds: b.measuredSeconds))
        case .skipped(let reason): emit(.skipped(afterTrack: k, reason))
        }
    }

    private func emit(_ event: DJBreakEvent) { for observer in observers { observer(event) } }

    /// One pooled cap for the whole break (no separate closing cap).
    static func render(_ djBreak: DJBreak, renderer: VoiceRenderer, userID: String, stationID: String,
                       cap: Double, bundled: BundledClipResolver? = nil) async -> DJBreakOutcome {
        await render(djBreak, renderer: renderer, userID: userID, stationID: stationID,
                     cap: BreakCap(main: cap, closingCueID: nil, closing: 0), bundled: bundled)
    }

    static func render(_ djBreak: DJBreak, renderer: VoiceRenderer, userID: String, stationID: String,
                       cap: BreakCap, bundled: BundledClipResolver? = nil) async -> DJBreakOutcome {
        let first: Pass
        switch await renderCues(djBreak, renderer: renderer, userID: userID, stationID: stationID, bundled: bundled) {
        case .success(let pass): first = pass
        case .failure(let skip): return .skipped(skip.reason)
        }
        if let fitted = cap.fitting(first) { return ready(djBreak, fitted) }
        // Build 20: each cue can fit its own cap in a slower Enhanced or Premium voice while the
        // whole break runs past the cadence cap. Re-render the whole break once on the last route
        // (the standard on-device voice, $0), so every cue is in one voice, before skipping it.
        guard let fallback = renderer.lastRouteOnly, let last = fallback.routes.first,
              !first.clips.allSatisfy({ $0.audio.providerID == last.providerID && $0.audio.voiceID == last.voice.id }) else {
            return .skipped(.overBreakBudget)
        }
        // The fallback's first route is on-device, so the bundle never resolves on this retry.
        switch await renderCues(djBreak, renderer: fallback, userID: userID, stationID: stationID, bundled: bundled) {
        case .success(let retry):
            return cap.fitting(retry).map { ready(djBreak, $0) } ?? .skipped(.overBreakBudget)
        case .failure(let skip): return .skipped(skip.reason)  // the retry's own reason (Fry, #158)
        }
    }

    private struct Skip: Error { let reason: DJBreakSkipReason }
    typealias Pass = (cues: [NarrationCue], clips: [RenderedClip])

    /// Measured-audio cap. `main` covers every clip except the closing clip, which has its own
    /// `closing` allowance while it is within it. Without a closing cue, `main` is the whole
    /// break's cap.
    ///
    /// P0 build 26 (-Fry): the closing line used to be capped at `closing` (4 s) even with
    /// talk-over off, so a 5 s closing line skipped the whole break as `.overBreakBudget` and
    /// the Studio showed "DJ voice unavailable". Now a closing clip over `closing` is never a
    /// skip on its own: it loses the talk-over marker and counts toward `main` with every other
    /// clip. Only a break whose clips still exceed `main` that way is skipped.
    struct BreakCap: Equatable, Sendable {
        let main: Double
        let closingCueID: UUID?
        let closing: Double
        /// Ordinary breaks: cap on every measured clip, closing line included. Nil: none.
        var whole: Double? = nil
        /// Clips that may be dropped to fit, in drop order (`DJBreak.optionalCueIDs`).
        var optional: [UUID] = []
        /// False: talk-over is off, so the closing line is never marked for talk-over.
        var talkOverEnabled = true

        func talkOver(_ enabled: Bool) -> BreakCap {
            var c = self
            c.talkOverEnabled = enabled
            return c
        }

        enum Fit: Equatable { case skip, keepMarker, dropMarker }

        /// `.skip`: over budget. `.keepMarker`: the planned talk-over marker stays (talk-over on,
        /// closing clip within `closing`). `.dropMarker`: the closing line plays as an ordinary
        /// line (talk-over off, or its clip is over `closing` and was counted in `main`).
        func fit(_ clips: [RenderedClip]) -> Fit {
            let closingClips = clips.filter { $0.cueID == closingCueID }
            let mainClips = clips.filter { $0.cueID != closingCueID }
            let mainSeconds = DJBreakPreparer.measured(mainClips), closingSeconds = DJBreakPreparer.measured(closingClips)
            if closingSeconds <= closing {
                guard mainSeconds <= main else { return .skip }
                return talkOverEnabled ? .keepMarker : .dropMarker
            }
            // Closing line over its allowance: an ordinary line, inside the main budget.
            guard mainSeconds + closingSeconds <= main else { return .skip }
            return .dropMarker
        }

        func fits(_ clips: [RenderedClip]) -> Bool { fit(clips) != .skip }

        /// Wall-clock length of the break for the `whole` cap: every measured clip plus the
        /// `talkOverGapSeconds` pause before the closing line whenever something plays before it.
        /// The gap is counted whether or not talk-over is on, so no break runs past `whole`.
        static func spokenSeconds(_ clips: [RenderedClip], closingCueID: UUID?) -> Double {
            let gap = clips.count > 1 && closingCueID != nil && clips.last?.cueID == closingCueID
                ? PreparedDJBreak.talkOverGapSeconds : 0
            return DJBreakPreparer.measured(clips) + gap
        }

        /// `pass` within every cap, after dropping optional clips (in `optional` order) while it
        /// is over. Never drops a required line (opener, closing). Nil: still over, skip.
        func fitting(_ pass: Pass) -> (pass: Pass, fit: Fit, trimmed: [UUID])? {
            var pass = pass, trimmed: [UUID] = [], queue = optional
            while true {
                let f = fit(pass.clips)
                if f != .skip, whole.map({ Self.spokenSeconds(pass.clips, closingCueID: closingCueID) <= $0 }) ?? true { return (pass, f, trimmed) }
                guard let id = queue.first(where: { id in pass.clips.contains { $0.cueID == id } }) else { return nil }
                queue.removeAll { $0 == id }
                pass.cues.removeAll { $0.id == id }
                pass.clips.removeAll { $0.cueID == id }
                trimmed.append(id)
            }
        }
    }

    fileprivate static func measured(_ clips: [RenderedClip]) -> Double { clips.reduce(0) { $0 + $1.audio.seconds } }

    private static func ready(_ djBreak: DJBreak, _ fitted: (pass: Pass, fit: BreakCap.Fit, trimmed: [UUID])) -> DJBreakOutcome {
        let kept = Set(fitted.pass.cues.map(\.id))
        return .ready(PreparedDJBreak(afterTrack: djBreak.afterTrack, cues: fitted.pass.cues, clips: fitted.pass.clips,
                                      attributions: djBreak.attributions.filter { kept.contains($0.key) },
                                      talkOverCueID: fitted.fit == .keepMarker ? djBreak.talkOverCueID : nil,
                                      trimmedCueIDs: fitted.trimmed))
    }

    private static func renderCues(_ djBreak: DJBreak, renderer: VoiceRenderer, userID: String, stationID: String,
                                   bundled: BundledClipResolver?) async
        -> Result<(cues: [NarrationCue], clips: [RenderedClip]), Skip> {
        var cues: [NarrationCue] = []
        var clips: [RenderedClip] = []
        for var cue in djBreak.cues {
            // The only cancellation whose result is kept is the preparation deadline: takeBreak,
            // cancelAll and purge record their own outcome first and ignore this one.
            if Task.isCancelled { return .failure(Skip(reason: .timedOut)) }
            // A whole presenter line whose text hash is in the bundle plays the bundled clip, with
            // its measured seconds, and makes no proxy call. Anything else: today's path.
            // (One voice per break, if a later live clip falls to on-device, is a follow-up.)
            // Pro + consent are checked per cue inside gatedClip (fail closed).
            let resolved = await bundled?.gatedClip(for: cue, attribution: djBreak.attributions[cue.id], renderer: renderer)
            let result: Result<RenderedClip, VoiceRenderer.Failure>
            if let resolved { result = .success(resolved) }
            else { result = await renderer.render(cue, userID: userID, stationID: stationID,
                                                  attribution: djBreak.attributions[cue.id]) }
            switch result {
            case .success(let clip):
                cue.renderedSeconds = clip.audio.seconds
                cue.voiceID = clip.audio.voiceID
                cue.providerID = clip.audio.providerID
                cue.audioCacheKey = clip.cacheKey
                cues.append(cue)
                clips.append(clip)
            case .failure(let failure):
                // A render cut short by the deadline is a timeout, whichever side of the race
                // (worker or timer) reports first.
                return .failure(Skip(reason: Task.isCancelled ? .timedOut : skipReason(failure)))
            }
        }
        return .success((cues, clips))
    }

    static func skipReason(_ failure: VoiceRenderer.Failure) -> DJBreakSkipReason {
        let results = failure.attempts.map(\.result)
        if results.contains(.overCostCap) { return .costCap }
        if !results.isEmpty, results.allSatisfy({ $0 == .timedOut }) { return .timedOut }
        return failure.reason == .overDuration ? .overDuration : .renderFailed
    }
}

extension DJSessionPlan {
    /// `ordinaryCapReport` plus what the measured-audio cap left out: optional lines trimmed at
    /// render time, and ordinary breaks skipped as `.overBreakBudget` (music-only boundary).
    public func capReport(afterBreaks outcomes: [Int: DJBreakOutcome]) -> OrdinaryBreakCapReport {
        var report = ordinaryCapReport
        for djBreak in breaks where !djBreak.hasBriefing {
            let k = djBreak.afterTrack
            if case .ready(let prepared)? = outcomes[k], let drop = prepared.droppedTimeCheck {
                report.droppedTimeChecks[k] = drop
            }
            switch outcomes[k] {
            case .ready(let prepared)? where !prepared.trimmedCueIDs.isEmpty:
                report.trimmedOptionalLines[k, default: 0] += prepared.trimmedCueIDs.count
            case .skipped(.overBreakBudget)?:
                report.trimmedOptionalLines[k] = nil
                if !report.skippedOverCap.contains(k) { report.skippedOverCap.append(k) }
            default: break
            }
        }
        report.skippedOverCap.sort()
        return report
    }

    /// Merges preparation outcomes: briefing cues in a skipped break become explicit drops,
    /// so every original cue still has exactly one outcome.
    public func report(afterBreaks outcomes: [Int: DJBreakOutcome]) -> NarrationScheduleReport {
        var skipped: [UUID: NarrationDropReason] = [:]
        for djBreak in breaks {
            guard case .skipped(let reason)? = outcomes[djBreak.afterTrack] else { continue }
            for id in djBreak.briefingCueIDs { skipped[id] = reason == .overDuration ? .overDuration : .renderFailed }
        }
        return NarrationScheduleReport(entries: briefingReport.entries.map { entry in
            skipped[entry.cue.id].map { NarrationScheduleEntry(cue: entry.cue, outcome: .dropped($0)) } ?? entry
        })
    }
}
