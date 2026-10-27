import Foundation

/// The one glue between the player and prepared narration: it plans the queue, starts
/// rendering each break while its song plays, applies station changes at song boundaries,
/// and hands the player a ready break (or nothing) without ever waiting.
///
/// The player reports three facts and plays what it is given:
/// - `songStarted(index:remaining:)` when a song starts (queue start, natural advance or skip),
/// - `naturalBoundary(afterTrack:)` when a song ends on its own: returns audio or nil (play music),
/// - `songCut(afterTrack:)` when the user skips or the queue changes.
/// Audio truth (`playbackStarted/Finished/Failed`) comes only from real audio callbacks.
///
/// Rules this enforces (see `docs/studio-presentation-contract.md`):
/// - speech renders during the song, before its boundary (`DJBreakPreparer.deadline`),
/// - routine breaks are capped at `maxTransitionSeconds` (12 s), briefing breaks at 45 s,
/// - late, failed, over-cap or revoked breaks are skipped: music never waits,
/// - tuner changes apply at the next boundary to *future* breaks; the playing song and the
///   break already preparing for it are untouched unless the change requires dropping them.
@MainActor
public final class DJBreakSession {
    private let preparer: DJBreakPreparer
    private let station: StationConfigurationModel
    private let dj: DJPresentationStore
    private let base: DJCadence
    private let hour: () -> Int
    private var writer: DJScriptWriter
    private var tracks: [DJTrack] = []
    private var briefing: NarrationHandoff?
    private var breaks: [Int: DJBreak] = [:]
    private var plannedWith: DJCadence?
    /// Briefing cues already handed to the player: never planned again.
    private var deliveredBriefing: Set<UUID> = []
    /// Index of the song playing now; breaks after it may be replanned, its own may not.
    private var playing: Int?
    private var changeTask: Task<Void, Never>?
    private var observing = false
    /// The break handed to the player at the last natural boundary, until its audio ends.
    private var onAir: (afterTrack: Int, sources: Set<UUID>)?
    /// Stops the DJ line on air. Same declaration as #67: PlayerView (82664c8) routes it to
    /// `InterludePlaybackAdapter.stopCurrentInterlude(reason:)`. `purge` calls it exactly once,
    /// and only when it removes a source the break on air depends on.
    /// If a purge hits the on-air break while this is nil, the stop is held and delivered once
    /// when a hook is set (unless that break has ended by then).
    public var onBreakMustStop: (@MainActor (InterludeStopReason, Int?) -> Void)? {
        didSet { deliverPendingStop() }
    }
    /// A stop for the break after `afterTrack` that found no hook installed.
    private var pendingStop: (afterTrack: Int, reason: InterludeStopReason)?
    /// Background `queueStarted` from a song tap. Cancelled on stop, a newer tap,
    /// skip-driven queue replacement, or commentary/briefing off that invalidates prep.
    private var queueSetupTask: Task<Void, Never>?
    /// `songStarted` arrived before background queue setup finished planning breaks.
    private var pendingSongStart: (index: Int, remaining: Duration)?
    /// True while `beginQueueInBackground`'s task has not finished `queueStarted`.
    private var queueSetupPending = false
    /// Bumped on every begin/cancel so a cancelled setup cannot clear a newer one.
    private var queueSetupGeneration = 0

    private func requestStop(afterTrack k: Int, _ reason: InterludeStopReason) {
        if let hook = onBreakMustStop { hook(reason, nil) } else { pendingStop = (k, reason) }
    }

    private func deliverPendingStop() {
        guard let pending = pendingStop, let hook = onBreakMustStop else { return }
        pendingStop = nil
        hook(pending.reason, nil)
    }
    /// Purges prepared and cached narration for sources that stop being narratable at a
    /// boundary (expiry). The app sets the same `NarrationPurger` the connections use.
    public var purger: (any NarrationPurging)?
    /// True once both the purger and the stop hook are set. Both app compositions check it
    /// before playback can start.
    public var isWiredForPurge: Bool { purger != nil && onBreakMustStop != nil }
    /// The personal items the briefing was built from, with their state when it was planned.
    /// Each boundary re-checks them against `now` (expiry), independent of `refresh()`.
    private var sources: [UUID: ConnectionItem] = [:]
    private let now: () -> Date

    public init(preparer: DJBreakPreparer, station: StationConfigurationModel, dj: DJPresentationStore,
                base: DJCadence = .init(), seed: UInt64 = .random(in: .min ... .max),
                hour: @escaping () -> Int = { Calendar.current.component(.hour, from: Date()) },
                now: @escaping () -> Date = { Date() }) {
        self.preparer = preparer
        self.now = now
        self.station = station
        self.dj = dj
        self.base = base
        self.hour = hour
        self.writer = DJScriptWriter(cadence: station.active.cadence(base: base), seed: seed)
    }

    /// Forwards preparer events to the DJ status and follows station changes. Call once.
    public func start() async {
        if !observing {
            observing = true
            let dj = dj
            await preparer.observe { event in Task { @MainActor in dj.send(event.presentationEvent) } }
        }
        guard changeTask == nil else { return }
        let changes = station.changes()
        changeTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                await self.stationChanged(change)
            }
        }
    }

    /// Schedules `queueStarted` in the background so a song tap can call `music.play` first.
    /// Cancels any in-flight setup from a prior tap. The returned task is also retained
    /// internally and cancelled on `stop`, commentary/briefing off, or a newer begin.
    /// Consent filtering in `queueStarted` is unchanged: personal cues still pass
    /// `mayBeNarrated` before they are planned.
    @discardableResult
    public func beginQueueInBackground(_ tracks: [DJTrack], briefing: NarrationHandoff? = nil,
                                       sources: [ConnectionItem] = []) -> Task<Void, Never> {
        queueSetupTask?.cancel()
        pendingSongStart = nil
        queueSetupGeneration += 1
        let generation = queueSetupGeneration
        queueSetupPending = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, generation == self.queueSetupGeneration else { return }
            await self.queueStarted(tracks, briefing: briefing, sources: sources)
            guard !Task.isCancelled, generation == self.queueSetupGeneration else { return }
            self.queueSetupPending = false
            if let pending = self.pendingSongStart {
                self.pendingSongStart = nil
                await self.songStarted(index: pending.index, remaining: pending.remaining)
            }
        }
        queueSetupTask = task
        return task
    }

    /// Cancels in-flight background queue setup (and any pending songStarted replay).
    /// Call from skip/stop paths that must not leave voice rendering after the user leaves.
    public func cancelBackgroundQueueSetup() {
        queueSetupTask?.cancel()
        queueSetupTask = nil
        pendingSongStart = nil
        queueSetupGeneration += 1
        queueSetupPending = false
    }

    /// A new queue: everything prepared for the old one is dropped, then the queue is planned
    /// with the active station's cadence. `briefing` is approved narration (may be nil);
    /// `sources` are the items its personal cues come from. A personal cue whose source is
    /// missing from `sources` or not narratable now is left out (fails closed).
    public func queueStarted(_ tracks: [DJTrack], briefing: NarrationHandoff? = nil,
                             sources: [ConnectionItem] = []) async {
        if let hook = testBeforeQueueStarted {
            await hook()
            guard !Task.isCancelled else { return }
        }
        // A new queue never talks over its first song: the old queue's handed-out or speaking
        // line stops now, personal or not. Untagged, as in `purge`. Not `.sourceRevoked` (it
        // isn't one); there is no queue-change case, so the nearest non-revoke reason is used.
        if let live = onAir { requestStop(afterTrack: live.afterTrack, .interruption) }
        await preparer.cancelAll()
        guard !Task.isCancelled else { return }
        if briefing != nil { await station.handle(.briefingWillPlan) }
        guard !Task.isCancelled else { return }
        self.tracks = tracks
        // A stop held for the old queue's break (no hook yet) has nothing left to stop; it must
        // not cancel a break of this queue later. Likewise the old queue's on-air break: a purge
        // of its sources must not stop this queue's break.
        pendingStop = nil
        onAir = nil
        self.sources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let at = now()
        self.briefing = station.active.briefing.enabled ? briefing.map { b in
            NarrationHandoff(cues: b.cues.filter { mayBeNarrated($0, at: at) },
                             maxSpokenSeconds: b.maxSpokenSeconds, experienceSeconds: b.experienceSeconds)
        } : nil
        deliveredBriefing = []
        playing = nil
        breaks = [:]
        replan(from: 0, keepingThrough: -1)
    }

    /// Song `index` started with `remaining` time left. Starts rendering its break, if one is
    /// planned and there is time to render before the boundary.
    /// When background queue setup has not finished planning yet, the start is held and
    /// replayed once `beginQueueInBackground` completes — the song itself is already playing.
    public func songStarted(index: Int, remaining: Duration) async {
        playing = index
        // Queue identity not applied yet (tap played first; break prep still in flight).
        if queueSetupPending {
            pendingSongStart = (index, remaining)
            return
        }
        guard breaks[index] != nil, let deadline = DJBreakPreparer.deadline(remainingInSong: remaining) else { return }
        // Personality edits apply when a break starts preparing; re-plan this break if they did.
        await station.handle(.djBreakWillPrepare(afterTrack: index))
        replanIfCadenceChanged(after: index - 1)
        guard let djBreak = breaks[index] else { return }
        await preparer.prepare(djBreak, deadline: deadline)
    }

    /// Song `k` ended on its own. Applies pending station edits at this safe boundary, then
    /// returns the prepared break, or nil when there is none (the player plays music at once).
    public func naturalBoundary(afterTrack k: Int) async -> PreparedDJBreak? {
        await station.handle(.songBoundary(afterTrack: k))
        // The change stream is async; apply a cadence change here so the next song's break
        // is planned with it before `songStarted(index: k + 1)` arrives.
        replanIfCadenceChanged(after: k)
        guard case .ready(let ready) = await preparer.takeBreak(afterTrack: k) else { return nil }
        // Consent or expiry may have changed since the break was rendered, with no refresh():
        // re-check every source at `now`, purge what may no longer be narrated, drop its cues.
        let at = now()
        let lapsed = Set(sources.values.filter { !$0.mayBeNarrated(at: at) }.map(\.id))
            .union(ready.cues.filter { !mayBeNarrated($0, at: at) }.compactMap(\.sourceItemID))
        if !lapsed.isEmpty {
            if let purger { await purger.purge(sourceItemIDs: lapsed) } else {
                purge(sourceItemIDs: lapsed)
                await preparer.purge(sourceItemIDs: lapsed)
            }
        }
        // Re-check after the awaits: a source revoked, expired, demoted or blocked while this
        // call was suspended (before the on-air marker exists) is not handed out either.
        let handOut = now()
        let cues = ready.cues.filter { cue in
            (cue.sourceItemID.map { !lapsed.contains($0) } ?? true) && mayBeNarrated(cue, at: handOut)
        }
        if ready.includesBriefing, !cues.contains(where: \.isContent) {
            // Nothing personal left to say: music plays at once.
            dj.send(.breakSkipped(afterTrack: k, .sourceRevoked))
            return nil
        }
        let kept = Set(cues.map(\.id))
        let prepared = cues.count == ready.cues.count ? ready : PreparedDJBreak(
            afterTrack: k, cues: cues, clips: ready.clips.filter { kept.contains($0.cueID) },
            attributions: ready.attributions.filter { kept.contains($0.key) })
        deliveredBriefing.formUnion(prepared.cues.filter(\.isContent).map(\.id))
        onAir = (k, Set(prepared.cues.compactMap(\.sourceItemID)))
        return prepared
    }

    /// Song `k` was cut (skip, queue change): its break is dropped, never played after a cut song.
    public func songCut(afterTrack k: Int) async {
        _ = await preparer.takeBreak(afterTrack: k, natural: false)
    }

    /// Player audio callbacks. `playbackStarted` only once DJ audio is actually audible.
    public func playbackStarted(afterTrack k: Int) { dj.send(.playbackStarted(afterTrack: k)) }
    public func playbackFinished(afterTrack k: Int) { endOnAir(k); dj.send(.playbackFinished(afterTrack: k)) }
    public func playbackFailed(afterTrack k: Int) { endOnAir(k); dj.send(.playbackFailed(afterTrack: k)) }

    private func endOnAir(_ k: Int) {
        if onAir?.afterTrack == k { onAir = nil }
        if pendingStop?.afterTrack == k { pendingStop = nil }   // nothing left to stop
    }

    /// Playback stopped or the session ended: nothing prepared may play later.
    public func stop() async {
        cancelBackgroundQueueSetup()
        await preparer.cancelAll()
        breaks = [:]
        playing = nil
        onAir = nil
        pendingStop = nil
        dj.send(.sessionStopped)
    }

    /// Personal items deleted or revoked: they leave the briefing and every break planned from
    /// them is re-planned without them, so they can never start rendering later. Called by
    /// `NarrationPurger` before the preparer and cache are purged.
    public func purge(sourceItemIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { sources[id] = nil }
        // A break already playing that speaks about these items stops now, in this call.
        // The handed-out (pending) or playing break counts: `onAir` is set when it is handed out.
        // The stop is untagged (nil afterTrack), which fails closed for whatever is pending or
        // playing in the adapter.
        // TODO(atlas/interlude-stop-hardening): tag with `live.afterTrack` once the
        // mismatched-tag fix lands, so a stale stop can't cancel an unrelated break.
        if let live = onAir, !live.sources.isDisjoint(with: ids) {
            onAir = nil
            requestStop(afterTrack: live.afterTrack, .sourceRevoked)
        }
        func mentions(_ cue: NarrationCue) -> Bool { cue.sourceItemID.map(ids.contains) ?? false }
        if let b = briefing {
            briefing = NarrationHandoff(cues: b.cues.filter { !mentions($0) },
                                        maxSpokenSeconds: b.maxSpokenSeconds, experienceSeconds: b.experienceSeconds)
        }
        guard let first = breaks.filter({ $0.value.cues.contains(where: mentions) }).keys.min() else { return }
        replan(from: first, keepingThrough: first - 1)
    }

    /// Every personal item: stops a personal break on air, drops personal briefing cues and
    /// re-plans breaks that mention any. Returns the item ids it knew of, for the preparer.
    public func purgeAllPersonal() -> Set<UUID> {
        var ids = Set((briefing?.cues ?? []).compactMap(\.sourceItemID))
        for b in breaks.values { ids.formUnion(b.cues.compactMap(\.sourceItemID)) }
        if let live = onAir, !live.sources.isEmpty {
            ids.formUnion(live.sources)
        }
        purge(sourceItemIDs: ids)
        return ids
    }

    /// A personal cue may be narrated only if its source is known and narratable at `at`.
    private func mayBeNarrated(_ cue: NarrationCue, at: Date) -> Bool {
        guard let id = cue.sourceItemID else { return true }
        return sources[id]?.mayBeNarrated(at: at) ?? false
    }

    public func detach() {
        cancelBackgroundQueueSetup()
        changeTask?.cancel()
        changeTask = nil
    }

    // MARK: Station changes

    func stationChanged(_ change: StationConfigurationChange) async {
        if change.invalidatesPreparedBreaks {
            // Commentary or briefing off, or an integration withdrawn: drop everything prepared,
            // including the break for the playing song, then plan the rest with the new settings.
            // Also cancel in-flight tap background setup so voice does not keep rendering.
            cancelBackgroundQueueSetup()
            await preparer.cancelAll()
            if !change.withdrawnIntegrations.isEmpty || !change.active.briefing.enabled { briefing = nil }
            replan(from: (playing ?? -1) + 1, keepingThrough: -1)
            return
        }
        replanIfCadenceChanged(after: playing ?? -1)
    }

    private func replanIfCadenceChanged(after k: Int) {
        guard station.active.cadence(base: base) != plannedWith else { return }
        replan(from: k + 1, keepingThrough: k)
    }

    /// Re-plans breaks after boundary `from - 1`. Breaks at or before `keepingThrough` stay
    /// (they may already be rendering); spacing and briefing placement continue from them.
    private func replan(from first: Int, keepingThrough kept: Int) {
        let cadence = station.active.cadence(base: base)
        plannedWith = cadence
        writer.cadence = cadence
        breaks = breaks.filter { $0.key <= kept }
        guard first < tracks.count - 1 else { return }
        let lastBreak = breaks.keys.max()
        let spokenBriefing = deliveredBriefing.union(breaks.values.flatMap(\.briefingCueIDs))
        let remainingBriefing = briefing.map {
            NarrationHandoff(cues: $0.cues.filter { !spokenBriefing.contains($0.id) },
                             maxSpokenSeconds: $0.maxSpokenSeconds, experienceSeconds: $0.experienceSeconds)
        }
        // Plan the suffix starting at the song before `first`, then shift indices back.
        let offset = first
        let plan = writer.plan(tracks: Array(tracks[offset...]), briefing: remainingBriefing, hour: hour())
        for b in plan.breaks {
            let k = b.afterTrack + offset
            if let lastBreak, k - lastBreak <= cadence.minSongsBetweenBreaks { continue }
            breaks[k] = DJBreak(afterTrack: k, cues: b.cues, attributions: b.attributions)
        }
    }

    /// Test hook: the planned boundaries.
    var plannedBoundaries: [Int] { breaks.keys.sorted() }
    /// Test hook: background tap setup has not finished planning.
    var testQueueSetupPending: Bool { queueSetupPending }
    /// Test hook: runs at the start of `queueStarted` so cancel races can be asserted.
    var testBeforeQueueStarted: (@MainActor () async -> Void)?
}
