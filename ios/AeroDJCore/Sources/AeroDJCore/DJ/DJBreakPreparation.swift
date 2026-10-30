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
    /// Pro or paid-voice consent ended (expiry, refund, revocation, withdrawal) after this
    /// break was prepared with the paid voice or a bundled clip: it is not played (-Echo).
    case paidVoiceRevoked
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
    /// The Pro + consent gate for the paid voice (`ProVoiceGate`), asked once per cue while a
    /// break renders and again when a prepared break is taken. Nil: no gate (tests whose
    /// renderer has no paid route). The app passes it through `init(voice:...)` (-Echo).
    private let paidVoice: ProVoiceAccess?
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

    public enum DJBreakEvent: Equatable, Sendable {
        case preparing(afterTrack: Int, includesBriefing: Bool)
        case prepared(afterTrack: Int, includesBriefing: Bool, seconds: Double)
        case skipped(afterTrack: Int, DJBreakSkipReason)
    }

    /// The app's init: the renderer and its Pro + consent gate travel together (`PaidVoice`),
    /// so a renderer with a paid route is never prepared without the per-cue gate (-Echo).
    public init(voice: PaidVoice, userID: String, stationID: String, cadence: DJCadence = .init(),
                talkOverEnabled: @escaping @Sendable () -> Bool = { DJTalkoverFlag.isEnabled() },
                bundledClips: BundledClipResolver? = nil) {
        self.init(renderer: voice.renderer, userID: userID, stationID: stationID, cadence: cadence,
                  bundledClips: bundledClips, paidVoice: voice.access, talkOverEnabled: talkOverEnabled)
    }

    /// `talkOverEnabled` defaults to `DJTalkoverFlag.isEnabled()` (the DIAG override, else the
    /// `AERODJ_OWNER_AB` build default), the same flag `TalkoverCoordinator` reads.
    public init(renderer: VoiceRenderer, userID: String, stationID: String, cadence: DJCadence = .init(),
                bundledClips: BundledClipResolver? = nil, paidVoice: ProVoiceAccess? = nil,
                talkOverEnabled: @escaping @Sendable () -> Bool = { DJTalkoverFlag.isEnabled() }) {
        self.renderer = renderer
        self.bundledClips = bundledClips
        self.paidVoice = paidVoice
        self.userID = userID
        self.stationID = stationID
        self.talkOverEnabled = talkOverEnabled
        // Measured audio. Briefing: 45 s in total, closing line included. Ordinary: the main
        // segment is capped at 15 s and a talk-over closing line at 4 s, separately. A closing
        // line over 4 s (or any closing line with talk-over off) loses its talk-over marker and,
        // when over 4 s, counts toward the 15 s main budget instead of skipping the break
        // (P0 build 26, -Fry). See `BreakCap`.
        self.breakCap = { djBreak in
            djBreak.hasBriefing
                ? BreakCap(main: Double(cadence.maxBriefingBreakSeconds), closingCueID: nil, closing: 0)
                : BreakCap(main: Double(cadence.maxTransitionSeconds), closingCueID: djBreak.talkOverCueID,
                           closing: Double(cadence.maxClosingSeconds))
        }
    }

    public func observe(_ observer: @escaping @Sendable (DJBreakEvent) -> Void) { observers.append(observer) }

    /// Render deadline for a song with `remaining` time left: `remaining - margin`, or nil if too late to prepare.
    public static func deadline(remainingInSong remaining: Duration, margin: Duration = .seconds(3)) -> Duration? {
        remaining > margin ? remaining - margin : nil
    }

    /// Starts rendering now. `deadline` must end before the boundary (see `deadline(remainingInSong:)`).
    /// `onDeviceOnly` (a station with a library seed) renders on the on-device, free routes only;
    /// with none configured the break is skipped as `.renderFailed`, never sent off the device.
    /// No default: every caller must decide, so a new call site cannot silently skip the gate.
    public func prepare(_ djBreak: DJBreak, deadline: Duration, onDeviceOnly: Bool) {
        let k = djBreak.afterTrack
        guard tasks[k] == nil, results[k] == nil, !taken.contains(k) else { return }
        planned[k] = djBreak
        emit(.preparing(afterTrack: k, includesBriefing: djBreak.hasBriefing))
        let renderer = onDeviceOnly ? self.renderer.onDeviceOnly : self.renderer
        let userID = userID, stationID = stationID, cap = breakCap(djBreak).talkOver(talkOverEnabled())
        let bundled = bundledClips, paid = paidVoice
        tasks[k] = Task {
            let outcome: DJBreakOutcome
            guard let renderer else { self.finish(k, .skipped(.renderFailed)); return }
            do {
                outcome = try await VoiceRenderer.withTimeout(deadline) {
                    await Self.render(djBreak, renderer: renderer, userID: userID, stationID: stationID, cap: cap,
                                      bundled: bundled, paidVoice: paid)
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
        defer { tasks[k] = nil; planned[k] = nil; openForRearm.remove(k); rearmed.remove(k); taken.insert(k) }
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

    /// How long the boundary waits for Pro + consent before skipping a paid or bundled break.
    static let paidVoiceTakeCheckTimeout: Duration = .milliseconds(300)

    /// `takeBreak` plus the paid-voice re-check (E1, -Echo): a ready break that carries a
    /// bundled clip or paid-route audio is handed out only if Pro + consent still allow it now.
    /// Otherwise it is skipped as `.paidVoiceRevoked` (reported like any skip), never played.
    /// One gate call, and only for a break that has paid audio. Never touches a break on air.
    ///
    /// The check is bounded by `paidVoiceTakeCheckTimeout` (Sentinel, #255): music never waits
    /// on a provider. No answer in time fails closed, the same `.paidVoiceRevoked` skip.
    public func takeCheckedBreak(afterTrack k: Int) async -> DJBreakOutcome {
        let outcome = takeBreak(afterTrack: k)
        guard case .ready(let ready) = outcome, let paidVoice, ready.clips.contains(where: usesPaidVoice) else {
            return outcome
        }
        let permitted = (try? await VoiceRenderer.withTimeout(Self.paidVoiceTakeCheckTimeout) {
            await paidVoice.decision().permitsPaidVoice
        }) ?? false   // timed out or cancelled: fail closed
        // A cancelAll() during the check (Fry, #255) cleared this queue: write nothing, report
        // nothing, hand nothing out. A stale result would block prepare at `k` in the next queue.
        guard taken.contains(k) else { return .skipped(.cancelled) }
        guard permitted else {
            results[k] = .skipped(.paidVoiceRevoked)
            emit(.skipped(afterTrack: k, .paidVoiceRevoked))
            return .skipped(.paidVoiceRevoked)
        }
        return outcome
    }

    /// Pro or consent may have ended (E1, -Echo). If the gate now denies, drops every break
    /// that is rendering with a paid route available, or is ready with paid or bundled audio,
    /// and reports each as `.paidVoiceRevoked`; returns those boundaries so the session can
    /// prepare them again (the per-cue gate then keeps them on-device). Taken breaks (on air)
    /// are never touched. With access still allowed, nothing changes.
    public func dropPaidVoiceBreaks() async -> [Int] {
        guard let paidVoice, await !paidVoice.decision().permitsPaidVoice else { return [] }
        let mayRenderPaid = renderer.routes.contains { !$0.isLocalAndFree }
        var dropped: [Int] = []
        for k in Set(tasks.keys).union(results.keys).sorted() where !taken.contains(k) {
            let paid: Bool
            if tasks[k] != nil { paid = mayRenderPaid }
            else if case .ready(let ready)? = results[k] { paid = ready.clips.contains(where: usesPaidVoice) }
            else { paid = false }
            guard paid else { continue }
            tasks.removeValue(forKey: k)?.cancel()
            results[k] = nil
            dropped.append(k)
            emit(.skipped(afterTrack: k, .paidVoiceRevoked))
        }
        return dropped
    }

    /// Audio from a bundled clip or from a route that is paid or leaves the device.
    private func usesPaidVoice(_ clip: RenderedClip) -> Bool {
        clip.audio.providerID == BundledClipResolver.providerID
            || renderer.routes.contains { !$0.isLocalAndFree && $0.providerID == clip.audio.providerID }
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
                       cap: Double, bundled: BundledClipResolver? = nil,
                       paidVoice: ProVoiceAccess? = nil) async -> DJBreakOutcome {
        await render(djBreak, renderer: renderer, userID: userID, stationID: stationID,
                     cap: BreakCap(main: cap, closingCueID: nil, closing: 0), bundled: bundled, paidVoice: paidVoice)
    }

    static func render(_ djBreak: DJBreak, renderer: VoiceRenderer, userID: String, stationID: String,
                       cap: BreakCap, bundled: BundledClipResolver? = nil,
                       paidVoice: ProVoiceAccess? = nil) async -> DJBreakOutcome {
        let first: (cues: [NarrationCue], clips: [RenderedClip])
        switch await renderCues(djBreak, renderer: renderer, userID: userID, stationID: stationID, bundled: bundled,
                                paidVoice: paidVoice) {
        case .success(let pass): first = pass
        case .failure(let skip): return .skipped(skip.reason)
        }
        let firstFit = cap.fit(first.clips)
        if firstFit != .skip { return ready(djBreak, first, firstFit) }
        // Build 20: each cue can fit its own cap in a slower Enhanced or Premium voice while the
        // whole break runs past the cadence cap. Re-render the whole break once on the last route
        // (the standard on-device voice, $0), so every cue is in one voice, before skipping it.
        guard let fallback = renderer.lastRouteOnly, let last = fallback.routes.first,
              !first.clips.allSatisfy({ $0.audio.providerID == last.providerID && $0.audio.voiceID == last.voice.id }) else {
            return .skipped(.overBreakBudget)
        }
        // The fallback's first route is on-device, so the bundle never resolves on this retry.
        switch await renderCues(djBreak, renderer: fallback, userID: userID, stationID: stationID, bundled: bundled,
                                paidVoice: paidVoice) {
        case .success(let retry):
            let retryFit = cap.fit(retry.clips)
            return retryFit == .skip ? .skipped(.overBreakBudget) : ready(djBreak, retry, retryFit)
        case .failure(let skip): return .skipped(skip.reason)  // the retry's own reason (Fry, #158)
        }
    }

    private struct Skip: Error { let reason: DJBreakSkipReason }

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
    }

    fileprivate static func measured(_ clips: [RenderedClip]) -> Double { clips.reduce(0) { $0 + $1.audio.seconds } }

    private static func ready(_ djBreak: DJBreak, _ pass: (cues: [NarrationCue], clips: [RenderedClip]),
                              _ fit: BreakCap.Fit) -> DJBreakOutcome {
        .ready(PreparedDJBreak(afterTrack: djBreak.afterTrack, cues: pass.cues, clips: pass.clips, attributions: djBreak.attributions,
                               talkOverCueID: fit == .keepMarker ? djBreak.talkOverCueID : nil))
    }

    private static func renderCues(_ djBreak: DJBreak, renderer full: VoiceRenderer, userID: String, stationID: String,
                                   bundled: BundledClipResolver?, paidVoice: ProVoiceAccess?) async
        -> Result<(cues: [NarrationCue], clips: [RenderedClip]), Skip> {
        let mayRenderPaid = full.routes.contains { !$0.isLocalAndFree }
        var cues: [NarrationCue] = []
        var clips: [RenderedClip] = []
        for var cue in djBreak.cues {
            // The only cancellation whose result is kept is the preparation deadline: takeBreak,
            // cancelAll and purge record their own outcome first and ignore this one.
            if Task.isCancelled { return .failure(Skip(reason: .timedOut)) }
            // Paid-voice gate, per cue (-Echo): Pro + consent are asked now, before the bundle,
            // the cache or any provider. A denial narrows this cue to the on-device routes
            // (the existing `onDeviceOnly` view, same budget and cache), so neither a bundled
            // clip, a cached paid clip nor the proxy is used; no on-device route fails closed.
            var renderer = full
            if mayRenderPaid, let paidVoice, await !paidVoice.decision().permitsPaidVoice {
                guard let local = full.onDeviceOnly else { return .failure(Skip(reason: .renderFailed)) }
                renderer = local
            }
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
