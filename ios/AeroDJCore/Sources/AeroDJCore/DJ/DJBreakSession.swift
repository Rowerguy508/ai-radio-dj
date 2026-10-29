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
    /// Why the last `naturalBoundary` handed out no break, and whether the cadence had planned
    /// one there. Read-only; nothing decides on it (the P0 trace's boundary row reads it).
    public private(set) var lastNoBreak: (reason: DJBreakSkipReason, cadencePlanned: Bool)?
    /// Briefing cues already handed to the player: never planned again.
    private var deliveredBriefing: Set<UUID> = []
    /// Index of the song playing now; breaks after it may be replanned, its own may not.
    private var playing: Int?
    private var changeTask: Task<Void, Never>?
    private var observing = false
    /// The break handed to the player at the last natural boundary, until its audio ends.
    private var onAir: (afterTrack: Int, sources: Set<UUID>, includesBriefing: Bool)?
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
    /// Background `queueStarted` from a song tap. Cancelled on stop, detach, or a newer
    /// tap — not on commentary/briefing off (that lets setup finish with the new settings).
    private var queueSetupTask: Task<Void, Never>?
    /// `songStarted` arrived before background queue setup finished planning breaks.
    /// `heldAt` is when it arrived: the song keeps playing while setup runs, so the replay
    /// must subtract that time or the render deadline lands past the real boundary
    /// (build 22 P0: the afterTrack 0 break ran into `notReadyAtBoundary`, -Fry).
    private var pendingSongStart: (index: Int, remaining: Duration, heldAt: Date)?
    /// True while `beginQueueInBackground`'s task has not finished `queueStarted`.
    private var queueSetupPending = false
    /// Bumped on every begin/cancel so a cancelled setup cannot clear a newer one.
    private var queueSetupGeneration = 0
    /// Integrations withdrawn while background tap setup was still applying the new queue.
    /// `queueStarted` strips tap-time sources/briefing for these so snapshots cannot re-introduce them.
    private var pendingWithdrawnIntegrations: Set<StationIntegration> = []

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
    /// internally and cancelled on `stop`, `detach`, or a newer begin — not when commentary
    /// or the briefing turns off (setup finishes with the new station settings).
    /// Consent filtering in `queueStarted` is unchanged: personal cues still pass
    /// `mayBeNarrated` before they are planned.
    @discardableResult
    public func beginQueueInBackground(_ tracks: [DJTrack], briefing: NarrationHandoff? = nil,
                                       sources: [ConnectionItem] = []) -> Task<Void, Never> {
        beginQueueInBackground(reserveQueueSetup(), tracks, briefing: briefing, sources: sources)
    }

    /// #116 (-Atlas): marks a new queue as pending *before* `music.play` is called, so a
    /// `songStarted` that MusicKit reports during `play` is held for the new queue instead of
    /// consulting the old queue's breaks. Cancels a prior tap's setup. Synchronous: no await
    /// separates the tap from this, so nothing can slip in between. Music never waits on it.
    public func reserveQueueSetup() -> QueueSetupReservation {
        queueSetupTask?.cancel()
        queueSetupTask = nil
        pendingSongStart = nil
        // A newer tap captures fresh sources; prior mid-setup withdrawals do not apply to it.
        // Withdrawals from here on (including during `play`) do apply.
        pendingWithdrawnIntegrations = []
        queueSetupGeneration += 1
        queueSetupPending = true
        return QueueSetupReservation(generation: queueSetupGeneration)
    }

    /// Schedules `queueStarted` for a reservation. A reservation that a newer tap, `stop`,
    /// `detach` or `cancelBackgroundQueueSetup` replaced schedules nothing. A `songStarted`
    /// held since the reservation is replayed once the new queue is planned.
    @discardableResult
    public func beginQueueInBackground(_ reservation: QueueSetupReservation, _ tracks: [DJTrack],
                                       briefing: NarrationHandoff? = nil,
                                       sources: [ConnectionItem] = []) -> Task<Void, Never> {
        let generation = reservation.generation
        guard generation == queueSetupGeneration, queueSetupPending else { return Task {} }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, generation == self.queueSetupGeneration else { return }
            await self.queueStarted(tracks, briefing: briefing, sources: sources)
            guard !Task.isCancelled, generation == self.queueSetupGeneration else { return }
            self.queueSetupPending = false
            if let pending = self.pendingSongStart {
                self.pendingSongStart = nil
                let held = max(0, self.now().timeIntervalSince(pending.heldAt))
                await self.songStarted(index: pending.index, remaining: pending.remaining - .seconds(held))
            }
        }
        queueSetupTask = task
        return task
    }

    /// `play` threw for this reservation: no new queue. Releases the hold so the old queue's
    /// song starts are handled again. A held start (from the failed play) is dropped.
    /// A replaced reservation does nothing.
    public func releaseQueueSetup(_ reservation: QueueSetupReservation) {
        guard reservation.generation == queueSetupGeneration, queueSetupTask == nil else { return }
        queueSetupGeneration += 1
        queueSetupPending = false
        pendingSongStart = nil
        pendingWithdrawnIntegrations = []
    }

    /// Cancels in-flight background queue setup (and any pending songStarted replay).
    /// Call from skip/stop paths that must not leave voice rendering after the user leaves.
    public func cancelBackgroundQueueSetup() {
        queueSetupTask?.cancel()
        queueSetupTask = nil
        pendingSongStart = nil
        queueSetupGeneration += 1
        queueSetupPending = false
        // Cancelled setup never applies tap-time sources; do not poison a later tap.
        pendingWithdrawnIntegrations = []
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
        // Integrations withdrawn while this setup was in flight: drop their tap-time
        // ConnectionItem snapshots so mayBeNarrated fails closed (sources are snapshots,
        // not live consent — see ConnectionsPresentation.ConnectionItem.mayBeNarrated).
        let withdrawn = pendingWithdrawnIntegrations
        if !withdrawn.isEmpty {
            for (id, item) in self.sources where withdrawn.contains(item.integration) {
                self.sources[id] = nil
            }
            pendingWithdrawnIntegrations = []
        }
        let at = now()
        // Withdrawal during pending setup cleared briefing and recorded integrations;
        // never re-introduce the tap-time briefing after a withdrawal.
        if !withdrawn.isEmpty || !station.active.briefing.enabled {
            self.briefing = nil
        } else {
            self.briefing = briefing.map { b in
                NarrationHandoff(cues: b.cues.filter { mayBeNarrated($0, at: at) },
                                 maxSpokenSeconds: b.maxSpokenSeconds, experienceSeconds: b.experienceSeconds)
            }
        }
        deliveredBriefing = []
        playing = nil
        breaks = [:]
        replan(from: 0, keepingThrough: -1)
    }

    /// True when any seed of the station is from the listener's library.
    nonisolated static func speaksOnDeviceOnly(_ configuration: StationConfiguration) -> Bool {
        configuration.seeds.contains { $0.source == .library }
    }

    /// Song `index` started with `remaining` time left. Starts rendering its break, if one is
    /// planned and there is time to render before the boundary.
    /// When background queue setup has not finished planning yet, the start is held and
    /// replayed once `beginQueueInBackground` completes — the song itself is already playing.
    public func songStarted(index: Int, remaining: Duration) async {
        playing = index
        // Queue identity not applied yet (tap played first; break prep still in flight).
        if queueSetupPending {
            pendingSongStart = (index, remaining, now())
            return
        }
        testLastSongStartRemaining = remaining
        guard breaks[index] != nil, let deadline = DJBreakPreparer.deadline(remainingInSong: remaining) else { return }
        // Personality edits apply when a break starts preparing; re-plan this break if they did.
        await station.handle(.djBreakWillPrepare(afterTrack: index))
        replanIfCadenceChanged(after: index - 1)
        guard let djBreak = breaks[index] else { return }
        // Library-seed gate (#154): a station built from the listener's own library is spoken
        // on-device only, so no seed, song or artist from it reaches a cloud or paid voice.
        await preparer.prepare(djBreak, deadline: deadline, onDeviceOnly: Self.speaksOnDeviceOnly(station.active))
    }

    /// Song `k` ended on its own. Applies pending station edits at this safe boundary, then
    /// returns the prepared break, or nil when there is none (the player plays music at once).
    public func naturalBoundary(afterTrack k: Int) async -> PreparedDJBreak? {
        await station.handle(.songBoundary(afterTrack: k))
        // The change stream is async; apply a cadence change here so the next song's break
        // is planned with it before `songStarted(index: k + 1)` arrives.
        replanIfCadenceChanged(after: k)
        let cadencePlanned = breaks[k] != nil
        lastNoBreak = nil
        let taken = await preparer.takeBreak(afterTrack: k)
        if case .skipped(let reason) = taken { lastNoBreak = (reason, cadencePlanned) }
        guard case .ready(let ready) = taken else { return nil }
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
        // Commentary or the briefing turned off while this call was suspended (before the
        // on-air marker exists, so `stationChanged` had nothing to stop): not handed out.
        if station.active.commentary == .off
            || (ready.includesBriefing && !station.active.briefing.enabled) {
            dj.send(.breakSkipped(afterTrack: k, .cancelled))
            lastNoBreak = (.cancelled, cadencePlanned)
            return nil
        }
        if ready.includesBriefing, !cues.contains(where: \.isContent) {
            // Nothing personal left to say: music plays at once.
            dj.send(.breakSkipped(afterTrack: k, .sourceRevoked))
            lastNoBreak = (.sourceRevoked, cadencePlanned)
            return nil
        }
        let kept = Set(cues.map(\.id))
        let prepared = cues.count == ready.cues.count ? ready : PreparedDJBreak(
            afterTrack: k, cues: cues, clips: ready.clips.filter { kept.contains($0.cueID) },
            attributions: ready.attributions.filter { kept.contains($0.key) })
        deliveredBriefing.formUnion(prepared.cues.filter(\.isContent).map(\.id))
        onAir = (k, Set(prepared.cues.compactMap(\.sourceItemID)), ready.includesBriefing)
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
            // Commentary off (or the briefing off while a briefing break is out): the break
            // handed out or speaking stops now, before any await, through the same hook a
            // purge uses. The adapter ends it as `.revoked` and the boundary hands back to
            // music (`startNextTrack` -> `playIfStillAllowed`), exactly as for a purge.
            stopOnAirIfSilenced(by: change)
            // Always cancel in-flight VOICE renders (no spend after commentary/briefing off).
            await preparer.cancelAll()
            // Withdrawal / briefing-off handling must run even while tap setup is pending
            // (Sentinel P1). The early return below only skips replan on the previous queue.
            if !change.withdrawnIntegrations.isEmpty {
                pendingWithdrawnIntegrations.formUnion(change.withdrawnIntegrations)
                briefing = nil
                // Same immediate purge ConnectionsModel does via NarrationPurger: drop known
                // sources for the withdrawn integrations (stops an on-air break that mentions them).
                let ids = Set(sources.values
                    .filter { change.withdrawnIntegrations.contains($0.integration) }
                    .map(\.id))
                if !ids.isEmpty {
                    if let purger { await purger.purge(sourceItemIDs: ids) }
                    else {
                        purge(sourceItemIDs: ids)
                        await preparer.purge(sourceItemIDs: ids)
                    }
                }
            } else if !change.active.briefing.enabled {
                briefing = nil
            }
            if queueSetupPending {
                // Let setup finish with the new tracks + current settings (P2). Withdrawal
                // was recorded above; queueStarted strips tap-time snapshots before planning.
                return
            }
            // Commentary or briefing off, or an integration withdrawn: drop everything prepared,
            // including the break for the playing song, then plan the rest with the new settings.
            if !change.withdrawnIntegrations.isEmpty || !change.active.briefing.enabled { briefing = nil }
            replan(from: (playing ?? -1) + 1, keepingThrough: -1)
            return
        }
        replanIfCadenceChanged(after: playing ?? -1)
    }

    /// Stops the handed-out or speaking break when `change` silences it: commentary went to
    /// `.off`, or the briefing went off and that break carries briefing content. Untagged and
    /// `.sourceRevoked`, as in `purge`, so the adapter takes its revoke stop path (halt now,
    /// end `.revoked`, music resumes or the next track loads once). Turning anything on never
    /// reaches here (`invalidatesPreparedBreaks` is only true for reductions).
    private func stopOnAirIfSilenced(by change: StationConfigurationChange) {
        guard let live = onAir else { return }
        let commentaryOff = change.previous.commentary != .off && change.active.commentary == .off
        let briefingOff = change.previous.briefing.enabled && !change.active.briefing.enabled
        guard commentaryOff || (briefingOff && live.includesBriefing) else { return }
        onAir = nil
        requestStop(afterTrack: live.afterTrack, .sourceRevoked)
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

    /// Test hook: the `remaining` the last non-held `songStarted` prepared with.
    var testLastSongStartRemaining: Duration?
    /// Test hook: the planned boundaries.
    var plannedBoundaries: [Int] { breaks.keys.sorted() }
    /// Test hook: background tap setup has not finished planning.
    var testQueueSetupPending: Bool { queueSetupPending }
    /// Test hook (#116): the song start held until the new queue is planned.
    var testHeldSongStartIndex: Int? { pendingSongStart?.index }
    /// Test hook: ids of the queue `queueStarted` last applied.
    var testQueueTrackIDs: [String] { tracks.map(\.id) }
    /// Test hook: briefing is absent after withdrawal / briefing-off.
    var testBriefingIsNil: Bool { briefing == nil }
    /// Test hook: personal source item ids still present in the briefing or planned breaks.
    var testPlannedSourceItemIDs: Set<UUID> {
        var ids = Set((briefing?.cues ?? []).compactMap(\.sourceItemID))
        for b in breaks.values { ids.formUnion(b.cues.compactMap(\.sourceItemID)) }
        return ids
    }
    /// Test hook: runs at the start of `queueStarted` so cancel races can be asserted.
    var testBeforeQueueStarted: (@MainActor () async -> Void)?
}

/// #116: a queue setup reserved before `play`. Only the newest one can schedule setup.
public struct QueueSetupReservation: Equatable, Sendable {
    public let generation: Int
}
