import Foundation
@preconcurrency import MusicKit
import AVFoundation
import AeroDJCore

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

    private let player = ApplicationMusicPlayer.shared
    private var stateMachine = AudioStateMachine()
    private var audioSessionConfigured = false
    private var advanceDetector = TrackAdvanceDetector()
    private var pollTimer: Timer?

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
    func play(_ tracks: [Track]) async throws {
        guard authState == .authorized else {
            lastError = MusicKitError.notAuthorized.errorDescription ?? "Apple Music authorization required."
            throw MusicKitError.notAuthorized
        }
        guard !tracks.isEmpty else { return }
        queue = tracks
        currentTrack = tracks.first
        player.queue = ApplicationMusicPlayer.Queue(for: tracks.compactMap { $0.song })
        stateMachine.apply(.startMusic)
        resetAdvanceDetection()
        do {
            try await player.play()
            isPlaying = true
            lastError = nil
        } catch {
            lastError = "Playback failed: \(error.localizedDescription)"
            throw error
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        stateMachine.apply(.pause)
        resetAdvanceDetection()
    }

    func resume() async throws {
        try await player.play()
        isPlaying = true
        stateMachine.apply(.resume)
        resetAdvanceDetection()
    }

    func skip() async throws {
        try await player.skipToNextEntry()
        // Advance the displayed track to the next in the queue.
        if let idx = queue.firstIndex(where: { $0.id == currentTrack?.id }) {
            let next = queue.index(after: idx)
            if next < queue.count {
                currentTrack = queue[next]
            }
        }
        stateMachine.apply(.trackEnded)
        resetAdvanceDetection()
    }

    /// Called when a spoken interlude is ready: transition -> voice.
    func beginInterlude() {
        stateMachine.apply(.interludeReady)
    }

    /// Called when the spoken interlude ends: voice -> music.
    func endInterlude() {
        stateMachine.apply(.interludeEnded)
    }

    // MARK: - Track-advance observation

    /// Poll the player once a second and feed the advance detector so a
    /// *natural* song ending (MusicKit auto-advance) fires `.trackEnded`
    /// and moves music -> transition for the next interlude.
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
        let state = player.state
        // MusicKit sets .interrupted when the current entry finishes naturally.
        let reachedEnd = (state.playbackStatus == .interrupted)
        let sample = PlaybackSample(
            isPlaying: (state.playbackStatus == .playing),
            reachedEnd: reachedEnd,
            itemChanged: false // item identity isn't exposed on this SDK; we reset on explicit actions
        )
        if advanceDetector.consume(sample) {
            stateMachine.apply(.trackEnded)
        }
    }

    /// Reset the advance detector after an explicit user action so a natural
    /// end isn't confused with a manual skip/pause.
    private func resetAdvanceDetection() {
        advanceDetector = TrackAdvanceDetector()
    }

    // MARK: - Interruptions & route changes

    /// Handle a phone call / system interruption. No stuck-paused state:
    /// pause on begin; resume on end only if the system says to.
    func handleInterruption(_ reason: AVAudioSession.InterruptionType,
                            options: AVAudioSession.InterruptionOptions = []) {
        switch reason {
        case .began:
            pause()
        case .ended:
            if options.contains(.shouldResume) {
                Task { try? await resume() }
            }
        @unknown default:
            break
        }
    }

    /// Handle headphones unplugging: pause so music doesn't blast the speaker.
    func handleRouteChange(_ wasDeviceRemoved: Bool) {
        if wasDeviceRemoved {
            pause()
        }
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
        guard !audioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            // Non-fatal: playback still works in foreground.
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            self?.handleInterruption(type, options: options)
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            self?.handleRouteChange(reason == .oldDeviceUnavailable)
        }
    }
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