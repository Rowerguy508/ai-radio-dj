import Foundation
import MusicKit
import Combine

/// Native MusicKit adapter. No API secrets in the client — MusicKit framework
/// handles auth. Playback stays managed by MusicKit; no protected-stream mixing.
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

    private var player = ApplicationMusicPlayer.shared
    private var stateMachine = AudioStateMachine()

    var audioState: AudioState { stateMachine.state }

    /// Request MusicKit authorization. Explicit degraded state on denial.
    func authorize() async {
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            authState = .authorized
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

    /// Called when the interlude ends: voice -> music.
    func endInterlude() {
        stateMachine.apply(.interludeEnded)
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
