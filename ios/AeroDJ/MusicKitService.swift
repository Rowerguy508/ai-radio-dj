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
    private var boundaryDetector = PlaybackBoundaryDetector()
    private var intent = PlaybackIntent()
    /// Stops any DJ line that is speaking. Set by the app to the break adapter.
    var onBreakMustStop: (@MainActor () -> Void)?
    /// Called with the index of the song the user skipped, so its prepared break is discarded.
    var onSongSkipped: (@MainActor (Int) -> Void)?
    private var queueIndex = 0
    /// A song loaded but not started (the user paused during the break before it).
    private var pendingStartIndex: Int?
    /// Called when a song really starts, with its catalog duration if MusicKit reports one.
    var onSongStarted: (@MainActor (Int, TimeInterval?) -> Void)?
    /// Called once per boundary. For a natural end, the index is the song that just finished.
    /// The handler must resolve the transition: play a DJ line, or call `skipInterlude()`.
    var onBoundary: (@MainActor (PlaybackBoundary, Int) -> Void)?
    private var pollTimer: Timer?
    /// Playback timing for device validation. Indices and durations only: no titles or identifiers.
    private let log = Logger(subsystem: "com.aerodj.app", category: "playback")
    /// Session notification tokens, owned here and removed in `deinit`. Written once on the
    /// main actor in `registerSessionObservers`; read only from `deinit`.
    private nonisolated(unsafe) var sessionObservers: [NSObjectProtocol] = []
    /// The main-actor loop that handles session events in order. Cancelled in `deinit`.
    private nonisolated(unsafe) var sessionEventsTask: Task<Void, Never>?

    var audioState: AudioState { stateMachine.state }

    /// Request MusicKit authorization. Explicit degraded state on denial.
    func authorize() async {
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
        intent.userPlay()
        guard authState == .authorized else {
            lastError = MusicKitError.notAuthorized.errorDescription ?? "Apple Music authorization required."
            send(.errorRaised(PlaybackError(kind: .notAuthorized, message: lastError ?? "", isRecoverable: false)))
            throw MusicKitError.notAuthorized
        }
        guard !tracks.isEmpty else { return }
        queue = tracks
        currentTrack = tracks.first
        boundaryDetector.userRequestedChange()
        queueIndex = 0
        send(.queueStarted(tracks: tracks.map(\.info), startIndex: 0, station: station))
        stateMachine.apply(.startMusic)
        do {
            try await startTrack(at: 0, autoplay: true)
            lastError = nil
            send(.errorCleared)
        } catch {
            lastError = "Playback failed: \(error.localizedDescription)"
            send(.errorRaised(PlaybackError(kind: .playbackFailed, message: lastError ?? "", isRecoverable: true)))
            throw error
        }
    }

    /// The user pressed pause. A DJ line that is speaking stops too.
    func pause() {
        intent.userPause()
        boundaryDetector.pausedByApp()
        player.pause()
        isPlaying = false
        send(.userPaused)
        stateMachine.apply(.pause)
        onBreakMustStop?()
    }

    /// The user pressed play.
    func resume() async throws {
        intent.userPlay()
        activateAudioSessionForPlayback()
        try await player.play()
        isPlaying = true
        stateMachine.apply(.resume)
        send(.userResumed)
        reportPendingStart()
    }

    /// Pauses the player for a DJ break. Not a user action: the user's intent is unchanged.
    func pausePlayerForBreak() {
        boundaryDetector.pausedByApp()
        player.pause()
        isPlaying = false
    }

    /// Starts music again after a DJ break or an interruption, only if the user still
    /// wants playback and the system is not holding it paused.
    func resumeIfAllowed() async {
        guard intent.mayAutoResume, player.queue.currentEntry != nil else { return }
        do {
            activateAudioSessionForPlayback()
            try await player.play()
            isPlaying = true
            send(.userResumed)
            // A song loaded during the break (paused) starts now; its break is planned here.
            reportPendingStart()
        } catch {
            reportError("Could not resume music: \(error.localizedDescription)")
        }
    }

    /// A user skip is not a natural boundary: no DJ break is triggered by it.
    func skip() async throws {
        boundaryDetector.userRequestedChange()
        intent.userPlay()
        // The skipped song's break, speaking or prepared, belongs to that song and must not play.
        onBreakMustStop?()
        onSongSkipped?(queueIndex)
        let next = queueIndex + 1
        guard queue.indices.contains(next) else {
            player.stop()
            send(.queueFinished)
            stateMachine.apply(.stop)
            return
        }
        send(.userSkipped(nextIndex: next))
        try await startTrack(at: next, autoplay: true)
    }

    /// Loads one song into the player. Only the current song is ever queued, so it ends on
    /// its own and the next one starts only through `startNextTrack` or a user action.
    /// With `autoplay` false (the user paused during a break) the song waits, loaded and paused.
    func startTrack(at index: Int, autoplay: Bool) async throws {
        guard queue.indices.contains(index), let song = queue[index].song else { return }
        queueIndex = index
        currentTrack = queue[index]
        player.queue = ApplicationMusicPlayer.Queue(for: [song])
        guard autoplay, intent.mayAutoResume else {
            isPlaying = false
            pendingStartIndex = index
            return
        }
        activateAudioSessionForPlayback()
        try await player.play()
        isPlaying = true
        pendingStartIndex = nil
        log.notice("song started index=\(index, privacy: .public) durationSeconds=\(song.duration ?? -1, privacy: .public)")
        onSongStarted?(index, song.duration)
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

    private func pollPlaybackPosition() {
        // Position and duration let the detector see a finish even if the queue keeps its last entry.
        let currentDuration = queue.indices.contains(queueIndex) ? queue[queueIndex].song?.duration : nil
        let observation = PlaybackObservation(
            entryID: player.queue.currentEntry?.id,
            isPlaying: player.state.playbackStatus == .playing,
            position: player.playbackTime,
            duration: currentDuration
        )
        guard let boundary = boundaryDetector.consume(observation) else { return }
        isPlaying = observation.isPlaying
        switch boundary {
        case .naturalEnd:
            let finishedIndex = queueIndex
            log.notice("boundary naturalEnd finished=\(finishedIndex, privacy: .public)")
            send(.naturalBoundary(nextIndex: finishedIndex + 1))
            queueIndex += 1
            currentTrack = queue.indices.contains(queueIndex) ? queue[queueIndex] : nil
            stateMachine.apply(.trackEnded)
            onBoundary?(boundary, finishedIndex)
        case .queueFinished(let lastEntryID):
            switch QueueHandoff.afterSongEnds(finishedIndex: queueIndex, count: queue.count) {
            case .advance(let next):
                // One song is loaded at a time, so this end is the end of song `queueIndex`.
                // The break runs now; the next song is loaded after it (startNextTrack).
                let finished = queueIndex
                log.notice("boundary queueEnd finished=\(finished, privacy: .public)")
                send(.naturalBoundary(nextIndex: next))
                stateMachine.apply(.trackEnded)
                onBoundary?(.naturalEnd(finishedEntryID: lastEntryID), finished)
            case .stop:
                currentTrack = nil
                stateMachine.apply(.stop)
                send(.queueFinished)
                onBoundary?(boundary, queueIndex)
            }
        }
    }

    // MARK: - Interruptions & route changes

    /// Handle a phone call / system interruption. No stuck-paused state:
    /// pause on begin; resume on end only if the system says to.
    func handleInterruption(_ reason: AVAudioSession.InterruptionType,
                            options: AVAudioSession.InterruptionOptions = []) {
        switch reason {
        case .began:
            intent.systemInterruptionBegan()
            pausePlayerForBreak()
            send(.userPaused)
            onBreakMustStop?()
        case .ended:
            intent.systemInterruptionEnded(shouldResume: options.contains(.shouldResume))
            // While a DJ line is speaking, the break resumes music when it ends.
            if !isBreakActive {
                Task { await resumeIfAllowed() }
            }
        @unknown default:
            break
        }
    }

    /// Handle headphones unplugging: hold playback until the user presses play.
    func handleRouteChange(_ wasDeviceRemoved: Bool) {
        if wasDeviceRemoved {
            intent.routeRemoved()
            pausePlayerForBreak()
            send(.userPaused)
            onBreakMustStop?()
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
            }
        }
        // Observers are registered once, whether or not the category was set.
        guard sessionEventsTask == nil else { return }
        registerSessionObservers()
    }

    /// Activates the session right before playback starts, so launching the app does not stop
    /// the user's other audio. Runs on every play, because the system can deactivate the session.
    private func activateAudioSessionForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Non-fatal: the play call below reports any real failure.
        }
    }

    /// Reports a song that was loaded paused as started, once playback really begins.
    private func reportPendingStart() {
        guard let index = pendingStartIndex, queue.indices.contains(index),
              let song = queue[index].song else { return }
        pendingStartIndex = nil
        onSongStarted?(index, song.duration)
    }

    /// Notifications are yielded in arrival order into one stream, and a single main-actor loop
    /// handles them, so a rapid began/ended or route-removal sequence runs in the order it happened.
    private func registerSessionObservers() {
        let (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        sessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began || type == .ended else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            continuation.yield(.interruption(began: type == .began, shouldResume: shouldResume))
        })
        sessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            continuation.yield(.routeChange(wasDeviceRemoved: reason == .oldDeviceUnavailable))
        })
        sessionEventsTask = Task { @MainActor [weak self] in
            for await event in events {
                switch event {
                case let .interruption(began, shouldResume):
                    self?.handleInterruption(began ? .began : .ended, options: shouldResume ? .shouldResume : [])
                case let .routeChange(wasDeviceRemoved):
                    self?.handleRouteChange(wasDeviceRemoved)
                }
            }
        }
    }

    deinit {
        for token in sessionObservers {
            NotificationCenter.default.removeObserver(token)
        }
        sessionEventsTask?.cancel()
    }
}

/// A session notification, reduced to Sendable values before it leaves the notification thread.
private enum SessionEvent: Sendable {
    case interruption(began: Bool, shouldResume: Bool)
    case routeChange(wasDeviceRemoved: Bool)
}

enum MusicKitError: LocalizedError {
    case notAuthorized
    var errorDescription: String? {
        "Apple Music authorization required."
    }
}

/// App-facing track model. Domain types live in AeroDJCore; this bridges MusicKit.
struct Track: Identifiable, Hashable {
    let id: String
    let title: String
    let artistName: String
    let artworkURL: URL?
    let song: Song?

    init(song: Song) {
        self.id = song.id.rawValue
        self.title = song.title
        self.artistName = song.artistName
        self.artworkURL = song.artwork?.url(width: 300, height: 300)
        self.song = song
    }
}

extension Track {
    /// The UI-facing view of a track. The UI never sees `Song`.
    var info: TrackInfo {
        TrackInfo(id: id, title: title, artistName: artistName, artworkURL: artworkURL)
    }
}
