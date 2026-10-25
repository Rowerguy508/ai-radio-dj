import Foundation
import Combine

/// A playable track. UI-facing; real MusicKit integration maps Song -> this.
struct PlayableTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
}

/// Playback contract the UI depends on. Real MusicKitService conforms later;
/// the UI is built against this so integration is a drop-in, not a redesign.
protocol PlaybackService: ObservableObject {
    var currentTrack: PlayableTrack? { get }
    var isPlaying: Bool { get }
    var isLoading: Bool { get }
    var errorMessage: String? { get }

    func play(_ track: PlayableTrack) async
    func togglePlayPause() async
    func skip() async
}

/// Mock service for UI development. Deterministic, no network, no MusicKit.
@MainActor
final class MockPlaybackService: PlaybackService, ObservableObject {
    @Published private(set) var currentTrack: PlayableTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let tracks: [PlayableTrack]
    private var index = 0

    init(tracks: [PlayableTrack] = MockPlaybackService.defaultTracks) {
        self.tracks = tracks
    }

    static let defaultTracks: [PlayableTrack] = [
        PlayableTrack(id: "1", title: "Morning Light", artist: "The Calm Collective", artworkURL: nil),
        PlayableTrack(id: "2", title: "Slow Burn", artist: "Neon Harbor", artworkURL: nil),
        PlayableTrack(id: "3", title: "Golden Hour", artist: "Paper Satellites", artworkURL: nil),
    ]

    func play(_ track: PlayableTrack) async {
        isLoading = true
        errorMessage = nil
        // Simulate a short load so the loading state is visible.
        try? await Task.sleep(nanoseconds: 600_000_000)
        currentTrack = track
        isPlaying = true
        isLoading = false
    }

    func togglePlayPause() async {
        guard currentTrack != nil else { return }
        isPlaying.toggle()
    }

    func skip() async {
        guard !tracks.isEmpty else { return }
        index = (index + 1) % tracks.count
        await play(tracks[index])
    }
}