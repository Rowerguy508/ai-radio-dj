import Foundation
import MusicKit
import Combine
import AVFoundation
import AeroDJCore

/// Native MusicKit adapter. No API secrets in the client — MusicKit framework
/// handles auth. Playback stays managed by MusicKit; no protected-stream mixing.
/// Genuinely playable: observes the player's real state and drives the audio
/// state machine from actual playback events.
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
    private var playerObservers: Set<AnyCancellable> = []
    private var audioSessionConfigured = false

    var audioState: AudioState { stateMachine.state }

    /// Request MusicKit authorization. Explicit degraded state on denial.
    func authorize() async {
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            authState = .authorized
            configureAudioSession()
            observePlayerState()
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
            lastError = MusicKitError.notAuthorized.errorDescription
            throw MusicKitError.notAuthorized
        }
        guard !tracks.isEmpty else { return }
        queue = tracks
        player.queue = ApplicationMusicPlayer.Queue(for: tracks.compactMap { $0.song })
        stateMachine.apply(.startMusic)
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
    }

    func resume() async throws {
        try await player.play()
        isPlaying = true
        stateMachine.apply(.resume)
    }

    func skip() async throws {
        try await player.skipToNextEntry()
        stateMachine.apply(.trackEnded)
    }

    /// Called when a spoken interlude is ready: transition -> voice.
    func beginInterlude() {
        stateMachine.apply(.interludeReady)
    }

    /// Called when the spoken interlude ends: voice -> music.
    func endInterlude() {
        stateMachine.apply(.interludeEnded)
    }

    // MARK: - Interruptions & route changes

    /// Handle a phone call / system interruption. No stuck-paused state:
    /// pause on begin; resume on end only if the system says to, respecting
    /// the interruption options.
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

    // MARK: - Playback observation

    /// Observe the player's real state: now-playing track + playback status.
    /// `ApplicationMusicPlayer` itself is not observable; its `state` and
    /// `queue` are.
    private func observePlayerState() {
        player.state.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.syncFromPlayer() } }
            .store(in: &playerObservers)
        player.queue.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.syncFromPlayer() } }
            .store(in: &playerObservers)
    }

    private func syncFromPlayer() {
        if case .song(let song)? = player.queue.currentEntry?.item {
            currentTrack = Track(song: song)
        } else {
            currentTrack = nil
        }
        isPlaying = player.state.playbackStatus == .playing
        // Sync state machine: a real track-end (queue exhausted → stopped)
        // moves music → transition, ready for the next interlude.
        if player.state.playbackStatus == .stopped, stateMachine.state == .music {
            stateMachine.apply(.trackEnded)
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
            MainActor.assumeIsolated { self?.handleInterruption(type, options: options) }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            let removed = reason == .oldDeviceUnavailable
            MainActor.assumeIsolated { self?.handleRouteChange(removed) }
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
