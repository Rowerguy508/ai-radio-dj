import Foundation
@preconcurrency import MusicKit
import AVFoundation
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

    enum AuthState: Equatable {
        case unknown
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

    var audioState: AudioState { stateMachine.state }
    var mayAutoResume: Bool { sessionPolicy.mayAutoResume }
    /// Route removal or a system interruption is holding playback. A user pause is not this flag.
    var pausedBySystem: Bool { sessionPolicy.pausedBySystem }

    /// Read-only playhead for Nova's scrubber. Not published; the view polls.
    var playbackTime: TimeInterval { player.playbackTime }
    /// Catalog duration of the current track, if MusicKit reported one.
    var currentDuration: TimeInterval? { currentTrack?.duration }

    /// Request MusicKit authorization. Explicit degraded state on denial.
    func authorize() async {
        // Category and observers only. setActive(true) runs in playIfStillAllowed, immediately before play().
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            authState = .authorized
            configureAudioSession()
            startObserving()
            await refreshSubscription()
        case .denied, .restricted:
            authState = .denied
        case .notDetermined:
            authState = .unknown
        @unknown default:
            authState = .unknown
        }
    }

    /// Search the Apple Music catalog.
    func search(_ query: String) async throws -> [Track] {
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
        request.limit = 20
        let response = try await request.response()
        return response.songs.map { Track(song: $0) }
    }

    /// Start playing a queue of tracks.
    func play(_ tracks: [Track], station: StationRef? = nil) async throws {
        sessionPolicy.userPlay()
        logPlayGate("play.begin", index: 0)
        guard authState == .authorized else {
            logPlayGate("play.blocked.auth", index: 0)
            lastError = MusicKitError.notAuthorized.errorDescription ?? "Apple Music authorization required."
            send(.errorRaised(PlaybackError(kind: .notAuthorized, message: lastError ?? "", isRecoverable: false)))
            throw MusicKitError.notAuthorized
        }
        guard !tracks.isEmpty else { return }
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
        armPlaybackConfirmTimeout()
        do {
            try await startTrack(at: 0, autoplay: true, userInitiated: true)
            lastError = nil
            send(.errorCleared)
            await confirmPlaybackAfterStart()
        } catch {
            cancelPlaybackConfirmTimeout()
            let message = Self.playbackFailureMessage(error)
            lastError = message
            send(.errorRaised(PlaybackError(kind: .playbackFailed, message: message, isRecoverable: true)))
            // Leave the track visible but stop claiming playback.
            send(.userPaused)
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
        sessionPolicy.userPlay()
        armPlaybackConfirmTimeout()
        do {
            guard try await playIfStillAllowed() else {
                cancelPlaybackConfirmTimeout()
                // Never left a preparing state without a hold: we only send userResumed after
                // the gate passes. If a prior prepare left us preparing, restore the hold.
                send(.playbackStartRefused)
                return
            }
            send(.userResumed)
            stateMachine.apply(.resume)
            reportDeferredSongStart()
            await confirmPlaybackAfterStart()
        } catch {
            cancelPlaybackConfirmTimeout()
            send(.playbackStartRefused)
            let message = Self.playbackFailureMessage(error)
            lastError = message
            send(.errorRaised(PlaybackError(kind: .resumeFailed, message: message, isRecoverable: true)))
            throw error
        }
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
        guard action == .resumeCurrentEntry else { return }
        do {
            armPlaybackConfirmTimeout()
            guard try await playIfStillAllowed() else {
                cancelPlaybackConfirmTimeout()
                send(.playbackStartRefused)
                return
            }
            send(.userResumed)
            // A song loaded during the break (paused) starts now; its break is planned here.
            reportDeferredSongStart()
            await confirmPlaybackAfterStart()
        } catch {
            cancelPlaybackConfirmTimeout()
            send(.playbackStartRefused)
            reportError(Self.playbackFailureMessage(error))
        }
    }

    /// A user skip is not a natural boundary: no DJ break is triggered by it.
    func skip() async throws {
        boundaries.userRequestedChange()
        sessionPolicy.userPlay()
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
        try await startTrack(at: next, autoplay: true, userInitiated: true)
    }

    /// Loads one song into the player. Only the current song is ever queued, so it ends on
    /// its own and the next one starts only through `startNextTrack` or a user action.
    /// With `autoplay` false (the user paused during a break) the song waits, loaded and paused.
    func startTrack(at index: Int, autoplay: Bool, userInitiated: Bool = false) async throws {
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
            guard started else {
                armDeferredStart(index)
                logPlayGate("startTrack.deferred.afterPlayHeld", index: index)
                // Honest UI: not playing.
                if sessionPolicy.pausedBySystem {
                    send(.interruptionPaused)
                } else {
                    send(.userPaused)
                }
                return
            }
        } catch {
            logPlayGate("startTrack.playError", index: index)
            throw error
        }
        deferredStart.clear()
        noteSongStarted(index: index, duration: song.duration)
    }

    /// Starts the song after `index` when the break for `index` is over.
    func startNextTrack(after index: Int) async {
        let next = index + 1
        guard queue.indices.contains(next) else { return }
        do {
            try await startTrack(at: next, autoplay: true)
        } catch {
            reportError("Could not start the next song: \(error.localizedDescription)")
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
        if observation.isPlaying, snapshot.transport == .preparing {
            send(.playbackConfirmed)
            cancelPlaybackConfirmTimeout()
        }
        guard let step = boundaries.interpret(observation, queueIndex: queueIndex, queueCount: queue.count) else {
            isPlaying = observation.isPlaying
            return
        }
        isPlaying = observation.isPlaying
        noteFinishedEntry(step)
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
                // Non-fatal: retried on the next call. TEMPORARY diagnostic only.
                logPlaybackError("setCategory", error)
            }
        }
        // Observers are registered once, whether or not the category was set.
        guard sessionRegistration.registerIfNeeded() else { return }
        installSessionMonitor()
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
        log.notice("TEMPORARY gate=\(gate, privacy: .public) auth=\(auth, privacy: .public) audio=\(audio, privacy: .public) queueCount=\(count, privacy: .public) index=\(index, privacy: .public) autoplay=\(auto, privacy: .public) mayAutoResume=\(may, privacy: .private) userWants=\(wants, privacy: .private) pausedBySystem=\(held, privacy: .private)")
    }

    /// TEMPORARY: type, code, localizedDescription only. Never debugDescription or underlying chain.
    private func logPlaybackError(_ gate: String, _ error: Error) {
        let typeName = String(describing: type(of: error))
        let code = (error as NSError).code
        let text = error.localizedDescription
        log.error("TEMPORARY \(gate, privacy: .public) failed: \(typeName, privacy: .public) code \(code, privacy: .public): \(text, privacy: .public)")
    }

    /// TEMPORARY diagnostic message for the UI and banner (same rule as searchFailureMessage).
    static func playbackFailureMessage(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        let code = (error as NSError).code
        let text = error.localizedDescription
        return "TEMPORARY: playback failed: \(typeName) code \(code). \(text)"
    }

    private func armPlaybackConfirmTimeout() {
        cancelPlaybackConfirmTimeout()
        playbackConfirmTask = Task { @MainActor [weak self] in
            // ~8s: 16 × 0.5s polls for MusicKit `.playing`.
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.player.state.playbackStatus == .playing {
                    self.send(.playbackConfirmed)
                    self.isPlaying = true
                    self.cancelPlaybackConfirmTimeout()
                    return
                }
                if self.snapshot.transport != .preparing { return }
                switch self.player.state.playbackStatus {
                case .paused, .stopped, .interrupted:
                    self.failPlaybackConfirm(status: self.player.state.playbackStatus)
                    return
                default:
                    continue
                }
            }
            guard let self, !Task.isCancelled else { return }
            if self.snapshot.transport == .preparing {
                self.failPlaybackConfirm(status: self.player.state.playbackStatus)
            }
        }
    }

    private func cancelPlaybackConfirmTimeout() {
        playbackConfirmTask?.cancel()
        playbackConfirmTask = nil
    }

    private func confirmPlaybackAfterStart() async {
        if player.state.playbackStatus == .playing {
            send(.playbackConfirmed)
            cancelPlaybackConfirmTimeout()
            return
        }
        // Timeout task already armed by the caller; nothing more to do here.
        logPlayGate("confirm.wait", index: queueIndex)
    }

    private func failPlaybackConfirm(status: MusicKit.MusicPlayer.PlaybackStatus) {
        cancelPlaybackConfirmTimeout()
        let statusName = String(describing: status)
        log.notice("TEMPORARY confirm.fail status=\(statusName, privacy: .public) index=\(self.queueIndex, privacy: .public)")
        let message = "TEMPORARY: MusicKit status \(statusName) after start; never reached playing."
        lastError = message
        isPlaying = false
        player.pause()
        send(.errorRaised(PlaybackError(kind: .playbackFailed, message: message, isRecoverable: true)))
        send(.userPaused)
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

enum MusicKitError: LocalizedError {
    case notAuthorized
    case playbackFailed(message: String)
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Apple Music authorization required."
        case let .playbackFailed(message):
            message
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
