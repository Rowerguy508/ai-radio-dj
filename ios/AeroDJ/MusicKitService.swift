import Foundation
import MusicKit
import Combine
import AVFoundation

/// Native MusicKit adapter. No API secrets in the client — MusicKit framework
/// handles auth. Playback stays managed by MusicKit; no protected-stream mixing.
/// Genuinely playable: observes the player's real state and drives the audio
/// state machine from actual playback events.
@MainActor
final class MusicKitService: ObservableObject {
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

    private let player = ApplicationMusicPlayer.shared
    private var stateMachine = AudioStateMachine()
    private var stateObserver: AnyCancellable?
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
        guard authState == .authorized else { throw MusicKitError.notAuthorized }
        queue = tracks
        player.queue = ApplicationMusicPlayer.Queue(for: tracks.compactMap { $0.song })
        stateMachine.apply(.startMusic)
        try await player.play()
        isPlaying = true
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
    /// pause on begin, resume on end.
    func handleInterruption(_ reason: AVAudioSession.InterruptionType) {
        switch reason {
        case .began:
            pause()
        case .ended:
            Task { try? await resume() }
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
    private func observePlayerState() {
        stateObserver = player.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTrack = self.player.currentEntry?.item.flatMap { item in
                    switch item {
                    case .song(let song): return Track(song: song)
                    default: return nil
                    }
                }
                self.isPlaying = (self.player.playbackStatus == .playing)
            }
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
            self?.handleInterruption(type)
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
