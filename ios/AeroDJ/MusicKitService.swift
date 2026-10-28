import Foundation
@preconcurrency import MusicKit
import AVFoundation
import MediaPlayer
import AeroDJCore
import OSLog

/// Native MusicKit adapter. No API secrets in the client — MusicKit framework
/// handles auth. Playback stays managed by MusicKit; no protected-stream mixing.
/// Genuinely playable: authorization, catalog search, queue playback, skip,
/// pause/resume, interruption handling, and natural track-end observation.
@MainActor
final class MusicKitService: ObservableObject {
    /// One app-scoped instance; avoid multiple players fighting over state.
    static let shared = MusicKitService()

    /// The type is not constructed anywhere else. Layouts observe `shared`.
    private init() {}

    enum AuthState: Equatable {
        case unknown
        /// `MusicAuthorization.currentStatus` / request was `.notDetermined`. Shows Allow, not Connecting.
        case notDetermined
        case authorized
        case denied
        case notSubscribed
    }

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var queue: [Track] = []
    @Published private(set) var lastError: String?
    /// The UI's single source of truth, built by `PlaybackEngine` from the events below.
    @Published private(set) var snapshot = PlaybackSnapshot()
    private var engine = PlaybackEngine()

    private let player = ApplicationMusicPlayer.shared
    private var stateMachine = AudioStateMachine()
    private var audioSessionConfigured = false
    private var boundaries = BoundaryInterpreter()
    private var sessionPolicy = AudioSessionPolicy()
    private var deferredStart = DeferredSongStart()
    /// True after the first observer install, including a retry that follows a failed `setActive`.
    private var sessionRegistration = SessionRegistrationGate()
    /// Stops any DJ line that is speaking. Nil is a user pause or skip. A reason is logged.
    var onBreakMustStop: (@MainActor (InterludeStopReason?) -> Void)?
    /// Called with the index of the song the user skipped, so its prepared break is discarded.
    var onSongSkipped: (@MainActor (Int) -> Void)?
    private var queueIndex = 0
    /// Queue entry that already reached a natural end. `resumeIfAllowed` must not play it again.
    private var finishedEntryID: String?
    /// True when the current queue entry is the one a natural end already finished.
    var currentEntryAlreadyFinished: Bool {
        let currentID = player.queue.currentEntry?.id
        return currentID != nil && currentID == finishedEntryID
    }
    /// Called when a song really starts, with its catalog duration if MusicKit reports one.
    var onSongStarted: (@MainActor (Int, TimeInterval?) -> Void)?
    /// Called once per boundary. For a natural end, the index is the song that just finished.
    /// The handler must resolve the transition: play a DJ line, or call `skipInterlude()`.
    var onBoundary: (@MainActor (PlaybackBoundary, Int) -> Void)?
    private var pollTimer: Timer?
    /// Playback timing for device validation. Indices and durations only: no titles or identifiers.
    private let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    /// Keeps the nonisolated monitor alive. The monitor removes its own observers in its deinit.
    /// This class has no deinit: a `@MainActor` deinit is nonisolated and must not touch isolated state.
    private var sessionMonitor: AudioSessionMonitor?
    /// TEMPORARY: waits for MusicKit `.playing` after a start; cancelled on confirm or pause.
    private var playbackConfirmTask: Task<Void, Never>?
    /// Build 9 P0 (-Atlas): attempt and queue generations. A late result of an older start
    /// (watchdog, throw, refusal) and a stale boundary's `startNextTrack` do nothing.
    private var attempts = PlaybackAttempts()
    /// The attempt whose confirm reported a timeout or interruption; a late `.playing` clears it.
    private var confirmReportedAttempt: PlaybackAttemptID?
    /// Lock-screen / Control Center commands routed through `resume` / `pause`.
    private var remoteCommandsInstalled = false
    /// App-scoped catalog hits for `MusicSearch.live`. Survives every `PlayerView` body
    /// rebuild so a song-row tap after a re-render still resolves MusicKit `Track`s.
    let searchResults = SearchResultCache()

    var audioState: AudioState { stateMachine.state }
    var mayAutoResume: Bool { sessionPolicy.mayAutoResume }
    /// Route removal or a system interruption is holding playback. A user pause is not this flag.
    var pausedBySystem: Bool { sessionPolicy.pausedBySystem }

    /// Read-only playhead for Nova's scrubber. Not published; the view polls.
    var playbackTime: TimeInterval { player.playbackTime }
    /// Catalog duration of the current track, if MusicKit reported one.
    var currentDuration: TimeInterval? { currentTrack?.duration }

    /// Request MusicKit authorization. Explicit degraded state on denial.
    /// Call only after a tap that names Apple Music (Allow) or an explicit station open — never at launch.
    func authorize() async {
#if DEBUG
        PlaybackCallLog.shared.recordAuthorize()
#endif
        // Category and observers only. setActive(true) runs in playIfStillAllowed, immediately before play().
        let status = await MusicAuthorization.request()
        await apply(status)
    }

    /// Non-prompting status refresh for launch/restore. Never calls `request()`.
    /// Routes through the same `apply` path as `authorize()` so an already-granted
    /// user still gets `configureAudioSession` / `startObserving`.
    func refreshAuthorizationStatus() async {
        await apply(resolvedCurrentStatus())
    }

    /// Shared authorized / denied / notDetermined handling for `authorize()` and
    /// `refreshAuthorizationStatus()`. Does not call `request()`.
    private func apply(_ status: MusicAuthorization.Status) async {
        switch status {
        case .authorized:
            authState = .authorized
            configureAudioSession()
            startObserving()
            await refreshSubscription()
        case .denied, .restricted:
            authState = .denied
        case .notDetermined:
            authState = .notDetermined
        @unknown default:
            authState = .unknown
        }
    }

#if DEBUG
    /// `-AeroDJMusicAuthStatus notDetermined|authorized|denied|restricted`.
    /// Capture with the key unset defaults to `.notDetermined` so restore shows Allow.
    private static let musicAuthStatusKey = "AeroDJMusicAuthStatus"

    private func resolvedCurrentStatus() -> MusicAuthorization.Status {
        if let raw = UserDefaults.standard.string(forKey: Self.musicAuthStatusKey), !raw.isEmpty {
            switch raw {
            case "authorized": return .authorized
            case "denied": return .denied
            case "restricted": return .restricted
            case "notDetermined": return .notDetermined
            default: break
            }
        }
        if UserDefaults.standard.bool(forKey: "AeroDJStudioCapture") {
            return .notDetermined
        }
        return MusicAuthorization.currentStatus
    }
#else
    private func resolvedCurrentStatus() -> MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }
#endif

    /// Search the Apple Music catalog.
    func search(_ query: String) async throws -> [Track] {
        #if DEBUG
        PlaybackCallLog.shared.recordSearch()
        #endif
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
        request.limit = 20
        let response = try await request.response()
        return response.songs.map { Track(song: $0) }
    }

    /// Start playing a queue of tracks.
    func play(_ tracks: [Track], station: StationRef? = nil) async throws {
        #if DEBUG
        PlaybackCallLog.shared.recordPlay()
        #endif
        sessionPolicy.userPlay()
        // Build 9 P0 (-Atlas): every older start, watchdog and boundary is stale from here.
        let attempt = beginAttempt(userChangedQueue: true)
        logPlayGate("play.begin", index: 0)
        guard authState == .authorized else {
            logPlayGate("play.blocked.auth", index: 0)
            lastError = MusicKitError.notAuthorized.errorDescription ?? "Apple Music authorization required."
            send(.errorRaised(PlaybackError(kind: .notAuthorized, message: lastError ?? "", isRecoverable: false)))
            throw MusicKitError.notAuthorized
        }
        guard !tracks.isEmpty else {
            let message = "TEMPORARY: couldn't play this song (empty queue)."
            lastError = message
            send(.errorRaised(PlaybackError(kind: .playbackFailed, message: message, isRecoverable: true)))
            throw MusicKitError.playbackFailed(message: message)
        }
        // A new queue replaces whatever was on air. A DJ line that is speaking, or a break
        // handed out but not yet audible, belongs to the old queue and stops before the queue
        // is replaced, the same as `skip()`. Nil routes to `interlude.stop()`, which cancels
        // a pending play and halts a playing clip.
        onBreakMustStop?(nil)
        queue = tracks
        currentTrack = tracks.first
        boundaries.userRequestedChange()
        queueIndex = 0
        // Snapshot goes to `.preparing` here; `.playing` only after MusicKit confirms.
        send(.queueStarted(tracks: tracks.map(\.info), startIndex: 0, station: station))
        stateMachine.apply(.startMusic)
        armPlaybackConfirmTimeout(for: attempt)
        do {
            try await startTrack(at: 0, autoplay: true, userInitiated: true, attempt: attempt)
            // A newer tap replaced this queue during the await: it owns the screen and the player.
            guard attempts.isCurrent(attempt) else { throw MusicKitError.superseded }
            lastError = nil
            send(.errorCleared)
            await confirmPlaybackAfterStart(attempt)
        } catch MusicKitError.superseded {
            throw MusicKitError.superseded
        } catch {
            // A stale attempt's throw must not cancel, pause or fail the newer one.
            guard attempts.isCurrent(attempt) else { throw MusicKitError.superseded }
            // Leave the track visible but stop claiming playback. The queue does not advance.
            applyStartFailure(.threw(PlaybackErrorCode(error)), attempt: attempt)
            throw error
        }
    }

    /// The user pressed pause. A DJ line that is speaking stops too.
    func pause() {
        cancelPlaybackConfirmTimeout()
        _ = sessionPolicy.userPause()
        boundaries.pausedByApp(.userPause)
        player.pause()
        isPlaying = false
        send(.userPaused)
        stateMachine.apply(.pause)
        let duration = queue.indices.contains(queueIndex) ? queue[queueIndex].song?.duration : nil
        let nearEnd = PlaybackObservation(
            entryID: player.queue.currentEntry?.id,
            isPlaying: false,
            position: player.playbackTime,
            duration: duration
        ).isNearEnd()
        logPlayback(PlaybackLog.userPause(index: queueIndex, nearEnd: nearEnd))
        onBreakMustStop?(nil)
    }

    /// The user pressed play.
    func resume() async throws {
        guard !queue.isEmpty else {
            let message = "TEMPORARY: nothing queued to resume."
            lastError = message
            send(.errorRaised(PlaybackError(kind: .resumeFailed, message: message, isRecoverable: true)))
            throw MusicKitError.playbackFailed(message: message)
        }
        sessionPolicy.userPlay()
        // Re-arms the confirm for a new attempt; the rule is the same as for a tap: the deadline
        // reports and never pauses, and a late `.playing` confirms this attempt.
        let attempt = beginAttempt(userChangedQueue: false)
        armPlaybackConfirmTimeout(for: attempt)
        do {
            guard try await playIfStillAllowed() else {
                guard attempts.isCurrent(attempt) else { return }
                cancelPlaybackConfirmTimeout()
                // Never left a preparing state without a hold: we only send userResumed after
                // the gate passes. If a prior prepare left us preparing, restore the hold.
                send(.playbackStartRefused)
                return
            }
            guard attempts.isCurrent(attempt) else { return }
            send(.userResumed)
            stateMachine.apply(.resume)
            reportDeferredSongStart()
            await confirmPlaybackAfterStart(attempt)
        } catch {
            guard attempts.isCurrent(attempt) else { return }
            cancelPlaybackConfirmTimeout()
            send(.playbackStartRefused)
            let message = Self.playbackFailureMessage(error, attempt: attempt)
            lastError = message
            send(.errorRaised(PlaybackError(kind: .resumeFailed, message: message, isRecoverable: true)))
            throw error
        }
    }

    /// Build 9 P0 (-Atlas; Sentinel): Stop on a start past its 8 s confirm deadline. Re-decided here
    /// with `TransportTapPolicy` on the service's own snapshot. A user pause (`userWantsPlayback`
    /// false, watchdog cancelled) that also ends the attempt: a late `.playing` for it does not
    /// confirm, and the poll / `playIfStillAllowed` gates pause MusicKit if it starts anyway.
    func cancelTimedOutStart() {
        switch TransportTapPolicy.decide(transport: snapshot.transport, startTimedOut: snapshot.startTimedOut) {
        case .ignore:
            return
        case .play:
            return
        case .pause:
            // Confirmed between render and tap: Stop still means stop.
            pause()
            return
        case .cancelStart:
            break
        }
        attempts.userCancelledCurrent()
        confirmReportedAttempt = nil
        pause()
        // The deadline banner described the start the user just stopped.
        lastError = nil
        send(.errorCleared)
    }

    /// Pauses the player for a DJ break. Not a user action: the user's intent is unchanged.
    func pausePlayerForBreak() {
        boundaries.pausedByApp()
        player.pause()
        isPlaying = false
    }

    /// Starts music again after a DJ break or an interruption, only if the user still
    /// wants playback and the system is not holding it paused.
    func resumeIfAllowed() async {
        let currentID = player.queue.currentEntry?.id
        let action = NarrationResumePolicy.musicAfterBreak(
            entryAlreadyFinished: currentID != nil && currentID == finishedEntryID,
            mayAutoResume: sessionPolicy.mayAutoResume,
            queueHasEntry: currentID != nil
        )
        guard action == .resumeCurrentEntry else {
            return
        }
        // Build 9 P0 (-Atlas): a break's follow-up resume while a tap's start is preparing belongs
        // to the old show. The start in flight owns the player; superseding it would re-run play().
        guard PlaybackAttempts.breakResumeMayStart(transport: snapshot.transport) else {
            return
        }
        let attempt = beginAttempt(userChangedQueue: false)
        do {
            armPlaybackConfirmTimeout(for: attempt)
            guard try await playIfStillAllowed() else {
                guard attempts.isCurrent(attempt) else { return }
                cancelPlaybackConfirmTimeout()
                send(.playbackStartRefused)
                return
            }
            guard attempts.isCurrent(attempt) else { return }
            send(.userResumed)
            // A song loaded during the break (paused) starts now; its break is planned here.
            reportDeferredSongStart()
            await confirmPlaybackAfterStart(attempt)
        } catch {
            guard attempts.isCurrent(attempt) else { return }
            cancelPlaybackConfirmTimeout()
            send(.playbackStartRefused)
            reportError(Self.playbackFailureMessage(error, attempt: attempt))
        }
    }

    /// A user skip is not a natural boundary: no DJ break is triggered by it.
    func skip() async throws {
        boundaries.userRequestedChange()
        sessionPolicy.userPlay()
        // A skip replaces what plays: an older start or a pending boundary's next song is stale.
        let attempt = beginAttempt(userChangedQueue: true)
        // The skipped song's break, speaking or prepared, belongs to that song and must not play.
        onBreakMustStop?(nil)
        onSongSkipped?(queueIndex)
        let next = queueIndex + 1
        guard queue.indices.contains(next) else {
            player.stop()
            send(.queueFinished)
            stateMachine.apply(.stop)
            return
        }
        send(.userSkipped(nextIndex: next))
        try await startTrack(at: next, autoplay: true, userInitiated: true, attempt: attempt)
    }

    /// Loads one song into the player. Only the current song is ever queued, so it ends on
    /// its own and the next one starts only through `startNextTrack` or a user action.
    /// With `autoplay` false (the user paused during a break) the song waits, loaded and paused.
    /// `attempt` is the start this load belongs to. After the await, a superseded attempt throws
    /// `MusicKitError.superseded` and changes nothing: no UI event, no song-start report.
    func startTrack(at index: Int, autoplay: Bool, userInitiated: Bool = false,
                    attempt: PlaybackAttemptID) async throws {
        guard queue.indices.contains(index) else {
            logPlayGate("startTrack.outOfRange", index: index)
            return
        }
        guard let song = queue[index].song else {
            logPlayGate("startTrack.missingSong", index: index)
            throw MusicKitError.playbackFailed(message: "TEMPORARY: queue entry has no MusicKit Song at index \(index).")
        }
        queueIndex = index
        currentTrack = queue[index]
        // Build 9 P0: every queue load is the app's own change. Without this, loading the
        // next song (`startNextTrack`) while MusicKit still reported `.playing` could read as
        // a natural end of the entry just replaced, and advance again: the auto-skip chain.
        boundaries.userRequestedChange()
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        finishedEntryID = nil
        logPlayGate("startTrack.queued", index: index, autoplay: autoplay)
        guard autoplay else {
            isPlaying = false
            armDeferredStart(index)
            logPlayGate("startTrack.deferred.noAutoplay", index: index)
            return
        }
        guard sessionPolicy.mayAutoResume else {
            // Keep #88 deferral for natural-boundary / auto starts. Only user-initiated
            // starts (search play, skip, explicit resume path) raise an error.
            isPlaying = false
            armDeferredStart(index)
            logPlayGate("startTrack.deferred.held", index: index)
            switch HeldStartPolicy.action(userInitiated: userInitiated) {
            case .deferSilently:
                return
            case .deferAndReport:
                throw MusicKitError.playbackFailed(message: "TEMPORARY: playback held before play (mayAutoResume=false).")
            }
        }
        do {
            let started = try await playIfStillAllowed()
            guard attempts.isCurrent(attempt) else { throw MusicKitError.superseded }
            guard started else {
                armDeferredStart(index)
                logPlayGate("startTrack.deferred.afterPlayHeld", index: index)
                // Honest UI: not playing. The queue does not advance.
                applyStartFailure(.refused(pausedBySystem: sessionPolicy.pausedBySystem), attempt: attempt)
                return
            }
        } catch MusicKitError.superseded {
            throw MusicKitError.superseded
        } catch {
            logPlayGate("startTrack.playError", index: index)
            throw error
        }
        deferredStart.clear()
        noteSongStarted(index: index, duration: song.duration)
    }

    /// Starts the song after `index` when the break for `index` is over.
    /// Build 9 P0 (-Atlas, race found by Fry's review too): the boundary task in `PlayerView`
    /// calls this after awaiting the break. The poll armed it with the queue generation before
    /// that await; a tap or skip since then makes it stale, and it loads nothing. Without this,
    /// a tap during the break (or during `naturalBoundary`) was replaced by song 2 of the new queue.
    func startNextTrack(after index: Int) async {
        guard attempts.takeNext(after: index) else {
            return
        }
        let next = index + 1
        guard queue.indices.contains(next) else { return }
        let attempt = beginAttempt(userChangedQueue: false)
        do {
            try await startTrack(at: next, autoplay: true, attempt: attempt)
        } catch MusicKitError.superseded {
            return
        } catch {
            guard attempts.isCurrent(attempt) else { return }
            reportError("Could not start the next song: \(PlaybackErrorCode(error)). attempt=\(attempt.number)")
        }
    }

    /// Called when a spoken interlude is ready: transition -> voice.
    func beginInterlude() {
        stateMachine.apply(.interludeReady)
    }

    /// Called when the spoken interlude ends: voice -> music.
    func endInterlude() {
        stateMachine.apply(.interludeEnded)
    }

    /// The UI's dismiss action for a recoverable error. Playback is not affected.
    func dismissError() {
        lastError = nil
        send(.errorCleared)
    }

    /// Surfaces a non-fatal error in the player UI without interrupting playback.
    func reportError(_ message: String) {
        lastError = message
        send(.errorRaised(PlaybackError(kind: .resumeFailed, message: message, isRecoverable: true)))
    }

    /// DJ break lifecycle, reported by the interlude adapter.
    func djStarted(_ line: String) { send(.djStarted(line: line)) }
    func djFinished() { send(.djFinished) }
    func djCancelled() { send(.djCancelled) }

    /// A failed DJ line. The show continues; the UI shows a recoverable error.
    func reportSpeechError(_ message: String) {
        lastError = message
        send(.djFailed(message: message))
    }

    private func send(_ event: PlaybackEvent) {
        snapshot = engine.apply(event)
    }

    /// Called when a boundary has no DJ line: transition -> music, so playback never sticks.
    func skipInterlude() {
        stateMachine.apply(.noInterlude)
    }

    // MARK: - Track-boundary observation

    /// Poll the player once a second. The boundary detector turns queue-entry
    /// changes into natural boundaries, each reported once. Pauses, calls and
    /// resumes never change the entry, so they cannot trigger a DJ break.
    private func startObserving() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollPlaybackPosition()
            }
        }
        // Fire on the run loop common modes so it works during scrolling/drag.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func noteFinishedEntry(_ step: BoundaryStep) {
        let boundary: PlaybackBoundary
        switch step {
        case let .advancedEntry(_, value), let .plannedHandoff(_, _, value), let .stopped(_, value):
            boundary = value
        }
        switch boundary {
        case let .naturalEnd(id), let .queueFinished(id):
            finishedEntryID = id
        }
    }

    private func pollPlaybackPosition() {
        // Position and duration let the detector see a finish even if the queue keeps its last entry.
        let currentDuration = queue.indices.contains(queueIndex) ? queue[queueIndex].song?.duration : nil
        let observation = PlaybackObservation(
            entryID: player.queue.currentEntry?.id,
            isPlaying: player.state.playbackStatus == .playing,
            position: player.playbackTime,
            duration: currentDuration
        )
        if observation.isPlaying {
            // Lock-screen / Control Center can start ApplicationMusicPlayer without our
            // playIfStillAllowed gate (build 8 bypass). Re-apply the same hold rule.
            let remote = RemotePlayGate.admit(
                mayAutoResume: sessionPolicy.mayAutoResume,
                userWantsPlayback: sessionPolicy.userWantsPlayback)
            if remote == .pauseBecauseHeld {
                player.pause()
                isPlaying = false
                logPlayGate("remoteOrPoll.pausedBecauseHeld", index: queueIndex)
                if snapshot.transport == .preparing {
                    send(.playbackStartRefused)
                }
                return
            }
            if snapshot.transport == .preparing, let attempt = attempts.current {
                // `.preparing` belongs to the current attempt; a late `.playing` after a reported
                // timeout confirms it and clears that error.
                confirmStart(attempt)
            }
        }
        guard let step = boundaries.interpret(observation, queueIndex: queueIndex, queueCount: queue.count) else {
            isPlaying = observation.isPlaying
            if boundaries.takeNoProgressEnd() {
                surfaceNoProgressEnd(stillPlaying: observation.isPlaying)
            }
            return
        }
        isPlaying = observation.isPlaying
        noteFinishedEntry(step)
        switch step {
        case let .advancedEntry(finishedIndex, _), let .plannedHandoff(finishedIndex, _, _):
            // Captured before PlayerView's boundary task awaits the break. Re-checked in startNextTrack.
            attempts.armNext(after: finishedIndex)
        case .stopped:
            break
        }
        switch step {
        case let .advancedEntry(finishedIndex, boundary):
            log.notice("boundary naturalEnd finished=\(finishedIndex, privacy: .public)")
            send(.naturalBoundary(nextIndex: finishedIndex + 1))
            queueIndex += 1
            currentTrack = queue.indices.contains(queueIndex) ? queue[queueIndex] : nil
            stateMachine.apply(.trackEnded)
            onBoundary?(boundary, finishedIndex)
        case let .plannedHandoff(finishedIndex, nextIndex, boundary):
            // One song is loaded at a time, so this end is the end of song `queueIndex`.
            // The break runs now; the next song is loaded after it (startNextTrack).
            let signal: QueueEndSignal = observation.entryID == nil ? .entryCleared : .position
            logPlayback(PlaybackLog.queueEnd(finished: finishedIndex, signal: signal))
            send(.naturalBoundary(nextIndex: nextIndex))
            stateMachine.apply(.trackEnded)
            onBoundary?(boundary, finishedIndex)
        case let .stopped(finishedIndex, boundary):
            logPlayback(PlaybackLog.stationFinished(finished: finishedIndex))
            currentTrack = nil
            stateMachine.apply(.stop)
            send(.queueFinished)
            onBoundary?(boundary, finishedIndex)
        }
    }

    /// Build 9 P0: the entry changed or cleared before it played 2 s. That is a failed or
    /// replaced start, never a natural end: no break runs and the queue does not advance.
    /// When MusicKit is still playing (it re-identified the entry), nothing is shown.
    private func surfaceNoProgressEnd(stillPlaying: Bool) {
        guard !stillPlaying, let attempt = attempts.current else { return }
        applyStartFailure(.noProgressEnd, attempt: attempt)
    }

    /// Build 9 P0 (-Atlas): the one place a failed start changes state, via `StartFailurePolicy`.
    /// It never pauses the player, never advances `queueIndex`, never sends a boundary, and does
    /// nothing at all for a superseded attempt.
    private func applyStartFailure(_ failure: StartFailure, attempt: PlaybackAttemptID) {
        let effect = StartFailurePolicy.effect(failure, attempt: attempt, current: attempts.current)
        guard effect != .none else {
            return
        }
        if effect.cancelsConfirm { cancelPlaybackConfirmTimeout() }
        if let message = effect.message { lastError = message }
        isPlaying = false
        for event in effect.events { send(event) }
    }

    /// The current attempt reached `.playing` (watchdog or poll). Clears a reported timeout.
    private func confirmStart(_ attempt: PlaybackAttemptID) {
        guard attempts.isCurrent(attempt) else { return }
        send(.playbackConfirmed)
        isPlaying = true
        cancelPlaybackConfirmTimeout()
        if confirmReportedAttempt == attempt {
            confirmReportedAttempt = nil
            lastError = nil
            send(.errorCleared)
        }
    }

    private func beginAttempt(userChangedQueue: Bool) -> PlaybackAttemptID {
        if userChangedQueue { attempts.userChangedQueue() }
        let attempt = attempts.beginStart()
        confirmReportedAttempt = nil
        return attempt
    }

    // MARK: - Interruptions & route changes

    /// Phone call or route change. The policy decides; this only performs the directive.
    private func applySession(_ notice: AudioSessionNotice) async {
        let breakActive = isBreakActive
        let stopReason: InterludeStopReason?
        switch notice {
        case .interruptionBegan:
            logPlayback(PlaybackLog.interruptionBegan())
            boundaries.pausedByApp(.systemInterruption)
            stopReason = .interruption
        case let .interruptionEnded(shouldResume):
            logPlayback(PlaybackLog.interruptionEnded(shouldResume: shouldResume, breakActive: breakActive))
            stopReason = nil
        case .routeChanged(.oldDeviceUnavailable):
            logPlayback(PlaybackLog.routeRemoved())
            boundaries.pausedByApp(.routeLoss)
            stopReason = .routeRemoved
        case .routeChanged(.other):
            stopReason = nil
        }
        switch sessionPolicy.handle(notice, breakIsActive: breakActive) {
        case .suspendPlayback:
            pausePlayerForBreak()
            switch notice {
            case .interruptionBegan:
                send(.interruptionPaused)
            case .routeChanged(.oldDeviceUnavailable):
                send(.routePaused)
            case .interruptionEnded, .routeChanged(.other):
                send(.userPaused)
            }
            onBreakMustStop?(stopReason)
        case .resumeIfPermitted:
            await resumeIfAllowed()
        case .none:
            break
        }
    }

    /// Applies the state-machine and playback events for a break that just ended.
    /// The caller starts music only when `decision.resumeMusic` is true.
    func completeNarration(_ decision: NarrationResumeDecision) {
        if let event = decision.audioEvent {
            stateMachine.apply(event)
        }
        switch decision.playbackEvent {
        case .finished:
            send(.djFinished)
        case .cancelled:
            send(.djCancelled)
        case .failed:
            send(.djFailed(message: "The DJ line could not play."))
        }
    }

    private var isBreakActive: Bool {
        stateMachine.state == .transition || stateMachine.state == .voice
    }

    /// Detect whether the user has an active Apple Music subscription.
    private func refreshSubscription() async {
        let subscription = try? await MusicSubscription.current
        if let canPlayCatalog = subscription?.canPlayCatalogContent, !canPlayCatalog {
            authState = .notSubscribed
        }
    }

    // MARK: - Audio session

    /// Configure playback category + background audio so music keeps playing
    /// when the app is backgrounded or the screen locks. Also registers
    /// interruption + route-change handlers.
    private func configureAudioSession() {
        if !audioSessionConfigured {
            // Category only. Setting it does not stop other audio; activation waits for playback.
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                audioSessionConfigured = true
            } catch {
                // Non-fatal: retried on the next call.
                logPlaybackError("setCategory", error)
            }
        }
        // Observers are registered once, whether or not the category was set.
        guard sessionRegistration.registerIfNeeded() else { return }
        installSessionMonitor()
        installRemoteCommands()
    }

    /// `setActive(true)`, `prepareToPlay()`, then `play()`. After `play()` returns, a hold that
    /// landed during the await pauses again and does not count as a resume.
    private func playIfStillAllowed() async throws -> Bool {
        logPlayGate("playIfStillAllowed.begin", index: queueIndex)
        try activateAudioSessionForPlayback()
        do {
            try await player.prepareToPlay()
            logPlayGate("playIfStillAllowed.prepared", index: queueIndex)
        } catch {
            logPlaybackError("prepareToPlay", error)
            throw error
        }
        do {
            try await player.play()
            logPlayGate("playIfStillAllowed.playReturned", index: queueIndex)
        } catch {
            logPlaybackError("player.play", error)
            throw error
        }
        let decision = PlaybackStartGuard.afterPlay(
            mayAutoResume: sessionPolicy.mayAutoResume,
            userWantsPlayback: sessionPolicy.userWantsPlayback
        )
        guard decision == .keepPlaying else {
            player.pause()
            isPlaying = false
            logPlayGate("playIfStillAllowed.pausedBecauseHeld", index: queueIndex)
            return false
        }
        isPlaying = true
        return true
    }

    /// Activates the session right before playback starts, so launching the app does not stop
    /// the user's other audio. Runs on every play, because the system can deactivate the session.
    private func activateAudioSessionForPlayback() throws {
        guard AudioSessionActivation.shouldActivate(during: .playback) else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            logPlayGate("audioSession.active", index: queueIndex)
        } catch {
            logPlaybackError("setActive", error)
            throw error
        }
    }

    /// Notifications are yielded in arrival order into one stream, and a single main-actor loop
    /// handles them, so a rapid began/ended or route-removal sequence runs in the order it happened.
    private func installSessionMonitor() {
        let monitor = AudioSessionMonitor()
        sessionMonitor = monitor
        let events = monitor.events
        Task { @MainActor [weak self] in
            for await notice in events {
                if Task.isCancelled { break }
                await self?.applySession(notice)
            }
        }
    }

    /// The song that was loaded paused has now started. Reported once.
    private func reportDeferredSongStart() {
        guard let index = deferredStart.take(), queue.indices.contains(index) else { return }
        noteSongStarted(index: index, duration: queue[index].song?.duration)
    }

    func logBreakSkipped(after track: Int, reason: DJBreakSkipReason) {
        logPlayback(PlaybackLog.breakSkipped(after: track, reason: reason))
    }

    private func armDeferredStart(_ index: Int) {
        deferredStart.arm(index)
        logPlayback(PlaybackLog.songDeferred(index: index))
    }

    /// TEMPORARY play-path gate log. authState as case name, audio state, queue count, index;
    /// booleans at privacy .private. No titles, song ids, storefront or subscription details as public.
    private func logPlayGate(_ gate: String, index: Int, autoplay: Bool? = nil) {
        let auth = String(describing: authState)
        let audio = String(describing: audioState)
        let count = queue.count
        let auto = autoplay.map { $0 ? "true" : "false" } ?? "n/a"
        let may = mayAutoResume
        let wants = sessionPolicy.userWantsPlayback
        let held = sessionPolicy.pausedBySystem
        let attempt = attempts.current?.number ?? 0
        log.notice("TEMPORARY gate=\(gate, privacy: .public) attempt=\(attempt, privacy: .public) auth=\(auth, privacy: .public) audio=\(audio, privacy: .public) queueCount=\(count, privacy: .public) index=\(index, privacy: .public) autoplay=\(auto, privacy: .public) mayAutoResume=\(may, privacy: .private) userWants=\(wants, privacy: .private) pausedBySystem=\(held, privacy: .private)")
    }

    /// TEMPORARY: error type, NSError domain and code only (`PlaybackErrorCode`). No
    /// localizedDescription, debugDescription, userInfo or underlying chain.
    private func logPlaybackError(_ gate: String, _ error: Error) {
        let code = PlaybackErrorCode(error)
        let attempt = attempts.current?.number ?? 0
        log.error("TEMPORARY \(gate, privacy: .public) failed attempt=\(attempt, privacy: .public): \(code.typeName, privacy: .public) \(code.domain, privacy: .public) code \(code.code, privacy: .public)")
    }

    /// TEMPORARY diagnostic message for the UI and banner: type, domain, code and attempt only.
    static func playbackFailureMessage(_ error: Error, attempt: PlaybackAttemptID) -> String {
        "TEMPORARY: playback failed: \(PlaybackErrorCode(error)). attempt=\(attempt.number)"
    }

    /// Route lock-screen / Control Center play through `resume()` (userPlay + playIfStillAllowed)
    /// and pause through `pause()`, so remote commands cannot bypass the hold gate.
    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                // Explicit user intent: clears system holds the same way in-app Play does.
                _ = try? await self.resume()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.pause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.isPlaying || self.snapshot.transport == .playing
                    || self.snapshot.transport == .preparing {
                    self.pause()
                } else {
                    _ = try? await self.resume()
                }
            }
            return .success
        }
    }

    /// #109's confirm for one attempt, fully through `PlaybackConfirmWatchdog` /
    /// `PlaybackConfirmPolicy` (pure, tested in AeroDJCore). It never pauses the player: the 8 s
    /// deadline and `.interrupted` only report, and a late `.playing` confirms the same attempt.
    /// A newer attempt (tap, resume, skip) supersedes it, and it then touches nothing.
    private func armPlaybackConfirmTimeout(for attempt: PlaybackAttemptID) {
        cancelPlaybackConfirmTimeout()
        playbackConfirmTask = Task { @MainActor [weak self] in
            var watchdog = PlaybackConfirmWatchdog(attempt: attempt)
            while !watchdog.isFinished {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                let status = MusicKitService.confirmStatus(self.player.state.playbackStatus)
                switch watchdog.observe(status: status,
                                        transportIsPreparing: self.snapshot.transport == .preparing,
                                        currentAttempt: self.attempts.current) {
                case .confirmed:
                    self.confirmStart(attempt)
                    return
                case .stopWaiting, .superseded:
                    return
                case .reportTimeoutKeepPlayer:
                    self.reportConfirmProblem(.confirmDeadline(last: status), attempt: attempt)
                case .failInterrupted:
                    self.reportConfirmProblem(.confirmInterrupted, attempt: attempt)
                case .keepWaiting:
                    continue
                }
            }
        }
    }

    private static func confirmStatus(_ status: MusicKit.MusicPlayer.PlaybackStatus) -> ConfirmStatus {
        switch status {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        case .interrupted: .interrupted
        case .seekingForward, .seekingBackward: .seeking
        @unknown default: .paused
        }
    }

    private func cancelPlaybackConfirmTimeout() {
        playbackConfirmTask?.cancel()
        playbackConfirmTask = nil
    }

    private func confirmPlaybackAfterStart(_ attempt: PlaybackAttemptID) async {
        if player.state.playbackStatus == .playing {
            confirmStart(attempt)
            return
        }
        // Timeout task already armed by the caller; nothing more to do here.
        logPlayGate("confirm.wait", index: queueIndex)
    }

    /// The confirm deadline passed, or MusicKit said `.interrupted`. Report only: no
    /// `player.pause()` (Fry: a stream buffering past 8 s on cellular must not be killed), no
    /// boundary, no advance. Transport stays `.preparing`, so the UI never claims `.playing`.
    private func reportConfirmProblem(_ failure: StartFailure, attempt: PlaybackAttemptID) {
        guard attempts.isCurrent(attempt) else { return }
        confirmReportedAttempt = attempt
        applyStartFailure(failure, attempt: attempt)
    }

    private func logPlayback(_ line: String) {
        log.notice("\(line, privacy: .public)")
    }

    private func noteSongStarted(index: Int, duration: TimeInterval?) {
        log.notice("song started index=\(index, privacy: .public) durationSeconds=\(duration ?? -1, privacy: .public)")
        onSongStarted?(index, duration)
    }
}

/// Owns the audio-session observers off the main actor.
///
/// `MusicKitService` is `@MainActor`, and its deinit is nonisolated, so it cannot remove
/// main-actor tokens without a data race. This object is not actor-isolated: its own deinit
/// removes the observers and finishes the stream, which ends the consumer loop.
private final class AudioSessionMonitor: NSObject {
    private let eventsStream = FinishingStream<AudioSessionNotice>()
    var events: AsyncStream<AudioSessionNotice> { eventsStream.stream }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // `eventsStream` deinit finishes the stream after this body returns.
    }

    @objc
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .began || type == .ended else { return }
        let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
        eventsStream.yield(.interruption(began: type == .began, shouldResume: shouldResume))
    }

    @objc
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        eventsStream.yield(.routeChange(deviceRemoved: reason == .oldDeviceUnavailable))
    }
}


/// App-scoped bridge from UI `TrackInfo` rows back to MusicKit `Track`s. Owned by
/// `MusicKitService` so `MusicSearch.live` may be rebuilt on every body without wiping hits.
@MainActor
final class SearchResultCache {
    private var byID: [String: Track] = [:]
    private var ordered: [Track] = []

    func store(_ list: [Track]) {
        ordered = list
        byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Prefer the ordered slice captured at search time when the UI still shows that search;
    /// otherwise look up by id. Never returns an empty list — throws a TEMPORARY play error.
    func resolve(results: [TrackInfo], startIndex: Int) throws -> [Track] {
        switch PlayTapResolver.resolveIDs(
            allResultIDs: results.map(\.id),
            startIndex: startIndex,
            orderedIDs: ordered.map(\.id),
            available: Set(byID.keys)
        ) {
        case .failure(.startIndexOutOfRange):
            throw MusicKitError.playbackFailed(
                message: "TEMPORARY: couldn't play this song (start index out of range).")
        case .failure(.tracksUnavailable):
            throw MusicKitError.playbackFailed(
                message: "TEMPORARY: couldn't play this song (search results expired).")
        case .success(let ids):
            if ordered.map(\.id) == results.map(\.id), results.indices.contains(startIndex) {
                return Array(ordered[startIndex...])
            }
            let tracks = ids.compactMap { byID[$0] }
            guard !tracks.isEmpty else {
                throw MusicKitError.playbackFailed(
                    message: "TEMPORARY: couldn't play this song (search results expired).")
            }
            return tracks
        }
    }
}

enum MusicKitError: LocalizedError {
    case notAuthorized
    case playbackFailed(message: String)
    /// A newer tap, resume or skip replaced this start. Not an error to show.
    case superseded
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Apple Music authorization required."
        case let .playbackFailed(message):
            message
        case .superseded:
            "TEMPORARY: replaced by a newer start."
        }
    }
}

/// App-facing track model. Domain types live in AeroDJCore; this bridges MusicKit.
struct Track: Identifiable, Hashable {
    let id: String
    let title: String
    let artistName: String
    let artworkURL: URL?
    let duration: TimeInterval?
    let song: Song?

    init(song: Song) {
        self.id = song.id.rawValue
        self.title = song.title
        self.artistName = song.artistName
        self.artworkURL = song.artwork?.url(width: 300, height: 300)
        self.duration = song.duration
        self.song = song
    }
}

extension Track {
    /// The UI-facing view of a track. The UI never sees `Song`.
    var info: TrackInfo {
        TrackInfo(id: id, title: title, artistName: artistName, artworkURL: artworkURL)
    }
}
