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
    private var boundaryDetector = PlaybackBoundaryDetector()
    private var queueIndex = 0
    /// Called once per natural boundary between queue items. The app plays the DJ break here.
    var onBoundary: ((PlaybackBoundary, Int) -> Void)?
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
        boundaryDetector.userRequestedChange()
        queueIndex = 0
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

    /// A user skip is not a natural boundary: no DJ break is triggered by it.
    func skip() async throws {
        boundaryDetector.userRequestedChange()
        try await player.skipToNextEntry()
        advanceDisplayedTrack()
    }

    /// Called when a spoken interlude is ready: transition -> voice.
    func beginInterlude() {
        stateMachine.apply(.interludeReady)
    }

    /// Called when the spoken interlude ends: voice -> music.
    func endInterlude() {
        stateMachine.apply(.interludeEnded)
    }

    /// Surfaces a non-fatal error in the player UI without interrupting playback.
    func reportError(_ message: String) {
        lastError = message
    }

    /// Called when a boundary has no DJ line: transition -> music, so playback never sticks.
    func skipInterlude() {
        stateMachine.apply(.noInterlude)
    }

    private func advanceDisplayedTrack() {
        queueIndex += 1
        currentTrack = queue.indices.contains(queueIndex) ? queue[queueIndex] : nil
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
        let observation = PlaybackObservation(
            entryID: player.queue.currentEntry?.id,
            isPlaying: player.state.playbackStatus == .playing
        )
        guard let boundary = boundaryDetector.consume(observation) else { return }
        isPlaying = observation.isPlaying
        switch boundary {
        case .naturalEnd:
            queueIndex += 1
            currentTrack = queue.indices.contains(queueIndex) ? queue[queueIndex] : nil
            stateMachine.apply(.trackEnded)
        case .queueFinished:
            currentTrack = nil
            stateMachine.apply(.stop)
        }
        onBoundary?(boundary, queueIndex)
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