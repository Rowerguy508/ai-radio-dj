import Foundation
import Combine

/// A playable track. UI-facing; real MusicKit integration maps Song -> this.
struct PlayableTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
}

/// A DJ presence line shown in the studio layout.
struct DJPresence: Identifiable, Hashable {
    let id: String
    let name: String
    let mood: String
}

/// A compact briefing preview line for the unfolded layout.
struct BriefingPreview: Identifiable, Hashable {
    let id: String
    let text: String
}

/// Playback contract the UI depends on. Real MusicKitService conforms later;
/// the UI is built against this so integration is a drop-in, not a redesign.
@MainActor
protocol PlaybackService: ObservableObject {
    var currentTrack: PlayableTrack? { get }
    var isPlaying: Bool { get }
    var isLoading: Bool { get }
    var errorMessage: String? { get }
    var queue: [PlayableTrack] { get }
    var dj: DJPresence? { get }
    var briefing: [BriefingPreview] { get }

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
    @Published private(set) var queue: [PlayableTrack] = []
    @Published private(set) var dj: DJPresence?
    @Published private(set) var briefing: [BriefingPreview] = []

    private let tracks: [PlayableTrack]
    private var index = 0

    init(tracks: [PlayableTrack] = MockPlaybackService.defaultTracks) {
        self.tracks = tracks
        self.queue = Array(tracks.dropFirst())
        self.dj = DJPresence(id: "dj1", name: "Maya", mood: "Warm, unhurried")
        self.briefing = [
            BriefingPreview(id: "b1", text: "Good morning — 3 meetings today, first at 9."),
            BriefingPreview(id: "b2", text: "Rain later; umbrella's by the door."),
        ]
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
        // Rotate the queue so the played track leaves "up next".
        if let idx = queue.firstIndex(where: { $0.id == track.id }) {
            queue.remove(at: idx)
        }
        if let next = tracks.first(where: { $0.id != track.id && !queue.contains($0) }) {
            queue.append(next)
        }
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