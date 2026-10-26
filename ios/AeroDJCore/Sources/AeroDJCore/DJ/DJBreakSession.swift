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

    public init(preparer: DJBreakPreparer, station: StationConfigurationModel, dj: DJPresentationStore,
                base: DJCadence = .init(), seed: UInt64 = .random(in: .min ... .max),
                hour: @escaping () -> Int = { Calendar.current.component(.hour, from: Date()) }) {
        self.preparer = preparer
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

    /// A new queue: everything prepared for the old one is dropped, then the queue is planned
    /// with the active station's cadence. `briefing` is approved narration (may be nil).
    public func queueStarted(_ tracks: [DJTrack], briefing: NarrationHandoff? = nil) async {
        await preparer.cancelAll()
        if briefing != nil { await station.handle(.briefingWillPlan) }
        self.tracks = tracks
        self.briefing = station.active.briefing.enabled ? briefing : nil
        deliveredBriefing = []
        playing = nil
        breaks = [:]
        replan(from: 0, keepingThrough: -1)
    }

    /// Song `index` started with `remaining` time left. Starts rendering its break, if one is
    /// planned and there is time to render before the boundary.
    public func songStarted(index: Int, remaining: Duration) async {
        playing = index
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
        guard case .ready(let prepared) = await preparer.takeBreak(afterTrack: k) else { return nil }
        deliveredBriefing.formUnion(prepared.cues.filter(\.isContent).map(\.id))
        return prepared
    }

    /// Song `k` was cut (skip, queue change): its break is dropped, never played after a cut song.
    public func songCut(afterTrack k: Int) async {
        _ = await preparer.takeBreak(afterTrack: k, natural: false)
    }

    /// Player audio callbacks. `playbackStarted` only once DJ audio is actually audible.
    public func playbackStarted(afterTrack k: Int) { dj.send(.playbackStarted(afterTrack: k)) }
    public func playbackFinished(afterTrack k: Int) { dj.send(.playbackFinished(afterTrack: k)) }
    public func playbackFailed(afterTrack k: Int) { dj.send(.playbackFailed(afterTrack: k)) }

    /// Playback stopped or the session ended: nothing prepared may play later.
    public func stop() async {
        await preparer.cancelAll()
        breaks = [:]
        playing = nil
        dj.send(.sessionStopped)
    }

    /// Personal items deleted or revoked: they leave the briefing and every break planned from
    /// them is re-planned without them, so they can never start rendering later. Called by
    /// `NarrationPurger` before the preparer and cache are purged.
    public func purge(sourceItemIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        func mentions(_ cue: NarrationCue) -> Bool { cue.sourceItemID.map(ids.contains) ?? false }
        if let b = briefing {
            briefing = NarrationHandoff(cues: b.cues.filter { !mentions($0) },
                                        maxSpokenSeconds: b.maxSpokenSeconds, experienceSeconds: b.experienceSeconds)
        }
        guard let first = breaks.filter({ $0.value.cues.contains(where: mentions) }).keys.min() else { return }
        replan(from: first, keepingThrough: first - 1)
    }

    public func detach() { changeTask?.cancel(); changeTask = nil }

    // MARK: Station changes

    func stationChanged(_ change: StationConfigurationChange) async {
        if change.invalidatesPreparedBreaks {
            // Commentary or briefing off, or an integration withdrawn: drop everything prepared,
            // including the break for the playing song, then plan the rest with the new settings.
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
}
