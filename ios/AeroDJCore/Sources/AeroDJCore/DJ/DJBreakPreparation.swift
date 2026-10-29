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
    private let maxBreakSeconds: @Sendable (DJBreak) -> Double
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

    public enum DJBreakEvent: Equatable, Sendable {
        case preparing(afterTrack: Int, includesBriefing: Bool)
        case prepared(afterTrack: Int, includesBriefing: Bool, seconds: Double)
        case skipped(afterTrack: Int, DJBreakSkipReason)
    }

    public init(renderer: VoiceRenderer, userID: String, stationID: String, cadence: DJCadence = .init()) {
        self.renderer = renderer
        self.userID = userID
        self.stationID = stationID
        self.maxBreakSeconds = { Double($0.hasBriefing ? cadence.maxBriefingBreakSeconds : cadence.maxTransitionSeconds) }
    }

    public func observe(_ observer: @escaping @Sendable (DJBreakEvent) -> Void) { observers.append(observer) }

    /// Render deadline for a song with `remaining` time left: `remaining - margin`, or nil if too late to prepare.
    public static func deadline(remainingInSong remaining: Duration, margin: Duration = .seconds(3)) -> Duration? {
        remaining > margin ? remaining - margin : nil
    }

    /// Starts rendering now. `deadline` must end before the boundary (see `deadline(remainingInSong:)`).
    /// `onDeviceOnly` (a station with a library seed) renders on the on-device, free routes only;
    /// with none configured the break is skipped as `.renderFailed`, never sent off the device.
    public func prepare(_ djBreak: DJBreak, deadline: Duration, onDeviceOnly: Bool = false) {
        let k = djBreak.afterTrack
        guard tasks[k] == nil, results[k] == nil else { return }
        planned[k] = djBreak
        emit(.preparing(afterTrack: k, includesBriefing: djBreak.hasBriefing))
        let renderer = onDeviceOnly ? self.renderer.onDeviceOnly : self.renderer
        let userID = userID, stationID = stationID, cap = maxBreakSeconds(djBreak)
        tasks[k] = Task {
            let outcome: DJBreakOutcome
            guard let renderer else { self.finish(k, .skipped(.renderFailed)); return }
            do {
                outcome = try await VoiceRenderer.withTimeout(deadline) {
                    await Self.render(djBreak, renderer: renderer, userID: userID, stationID: stationID, cap: cap)
                }
            } catch {
                outcome = .skipped(.timedOut)
            }
            self.finish(k, outcome)
        }
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
    @discardableResult
    public func rearm(_ djBreak: DJBreak, deadline: Duration) -> Bool {
        let k = djBreak.afterTrack
        guard mayRearm(afterTrack: k) else { return false }
        rearmed.insert(k)
        results[k] = nil
        prepare(djBreak, deadline: deadline)
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
        guard openForRearm.contains(k), tasks[k] == nil, !rearmed.contains(k) else { return false }
        switch results[k] {
        case nil, .skipped(.timedOut)?: return true
        default: return false
        }
    }

    /// Test hook: boundaries with a render in flight.
    var testInFlight: Set<Int> { Set(tasks.keys) }
    /// Test hook: the recorded outcome for boundary `k`.
    func testResult(afterTrack k: Int) -> DJBreakOutcome? { results[k] }
    /// Test hook: records an outcome as if a render for `k` had finished with it.
    func testRecord(_ outcome: DJBreakOutcome, afterTrack k: Int) {
        tasks.removeValue(forKey: k)?.cancel()
        results[k] = outcome
    }

    /// Called at the boundary. Never waits: returns what is ready or an explicit skip.
    /// `natural` is false when the song was cut (skip, queue change); the break is then dropped.
    public func takeBreak(afterTrack k: Int, natural: Bool = true) -> DJBreakOutcome {
        defer { tasks[k] = nil; planned[k] = nil; openForRearm.remove(k); rearmed.remove(k) }
        guard natural else {
            tasks[k]?.cancel()
            let wasPlanned = tasks[k] != nil || results.removeValue(forKey: k) != nil
            results[k] = .skipped(.notNaturalBoundary)
            if wasPlanned { emit(.skipped(afterTrack: k, .notNaturalBoundary)) }
            return .skipped(.notNaturalBoundary)
        }
        if let result = results.removeValue(forKey: k) { return result }
        guard let task = tasks[k] else { return .skipped(.notPlanned) }
        task.cancel()
        results[k] = .skipped(.notReadyAtBoundary)   // a late finish must not replace this
        emit(.skipped(afterTrack: k, .notReadyAtBoundary))
        return .skipped(.notReadyAtBoundary)
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
        openForRearm.removeAll()
        rearmed.removeAll()
        for k in dropped.sorted() { emit(.skipped(afterTrack: k, .cancelled)) }
    }

    /// Drops any pending or prepared break built from these personal items (deleted or consent
    /// revoked), so their audio is never played. Pair with `AudioCache.purge(sourceItemIDs:)`.
    public func purge(sourceItemIDs: Set<UUID>) {
        for (k, djBreak) in planned where djBreak.cues.contains(where: { $0.sourceItemID.map(sourceItemIDs.contains) ?? false }) {
            tasks.removeValue(forKey: k)?.cancel()
            planned[k] = nil
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

    static func render(_ djBreak: DJBreak, renderer: VoiceRenderer, userID: String, stationID: String,
                       cap: Double) async -> DJBreakOutcome {
        let first: (cues: [NarrationCue], clips: [RenderedClip])
        switch await renderCues(djBreak, renderer: renderer, userID: userID, stationID: stationID) {
        case .success(let pass): first = pass
        case .failure(let skip): return .skipped(skip.reason)
        }
        if measured(first.clips) <= cap { return ready(djBreak, first) }
        // Build 20: each cue can fit its own cap in a slower Enhanced or Premium voice while the
        // whole break runs past the cadence cap. Re-render the whole break once on the last route
        // (the standard on-device voice, $0), so every cue is in one voice, before skipping it.
        guard let fallback = renderer.lastRouteOnly, let last = fallback.routes.first,
              !first.clips.allSatisfy({ $0.audio.providerID == last.providerID && $0.audio.voiceID == last.voice.id }) else {
            return .skipped(.overBreakBudget)
        }
        switch await renderCues(djBreak, renderer: fallback, userID: userID, stationID: stationID) {
        case .success(let retry) where measured(retry.clips) <= cap: return ready(djBreak, retry)
        case .success: return .skipped(.overBreakBudget)
        case .failure(let skip): return .skipped(skip.reason)  // the retry's own reason (Fry, #158)
        }
    }

    private struct Skip: Error { let reason: DJBreakSkipReason }

    private static func measured(_ clips: [RenderedClip]) -> Double { clips.reduce(0) { $0 + $1.audio.seconds } }

    private static func ready(_ djBreak: DJBreak, _ pass: (cues: [NarrationCue], clips: [RenderedClip])) -> DJBreakOutcome {
        .ready(PreparedDJBreak(afterTrack: djBreak.afterTrack, cues: pass.cues, clips: pass.clips, attributions: djBreak.attributions))
    }

    private static func renderCues(_ djBreak: DJBreak, renderer: VoiceRenderer, userID: String, stationID: String) async
        -> Result<(cues: [NarrationCue], clips: [RenderedClip]), Skip> {
        var cues: [NarrationCue] = []
        var clips: [RenderedClip] = []
        for var cue in djBreak.cues {
            // The only cancellation whose result is kept is the preparation deadline: takeBreak,
            // cancelAll and purge record their own outcome first and ignore this one.
            if Task.isCancelled { return .failure(Skip(reason: .timedOut)) }
            switch await renderer.render(cue, userID: userID, stationID: stationID) {
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
