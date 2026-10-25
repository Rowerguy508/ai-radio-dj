import Foundation
import Combine

/// A playable track. Mirrors Claude's `TrackInfo` (PlaybackSnapshot) so the
/// real engine drops in without UI changes.
struct PlayableTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
}

/// Transport state. Mirrors Claude's `TransportState`.
enum TransportState: Equatable {
    case stopped, playing, paused
}

/// What the DJ is doing. Mirrors Fry's `DJPresentationState` semantics:
/// `speaking` is true ONLY while speech audio actually plays, never from a
/// planned/prepared break.
enum DJStatus: Equatable {
    case idle
    case preparing
    case speaking
    case upcomingBriefing
    case consentReviewRequired(pendingCount: Int)

    var label: String? {
        switch self {
        case .idle: return nil
        case .preparing: return "DJ is getting ready"
        case .speaking: return "On air"
        case .upcomingBriefing: return "Briefing after this song"
        case .consentReviewRequired(let n): return "\(n) items to review"
        }
    }
}

/// A recoverable playback problem the UI can show.
struct PlaybackError: Equatable {
    let message: String
    let isRecoverable: Bool
}

/// A station the user can tune to. Mirrors Fry's station-config contract
/// (genres/moods/energy/DJ personality) — UI-facing subset only.
struct StationConfig: Identifiable, Hashable {
    let id: UUID
    let name: String
    let djName: String
    let description: String
    let mood: String
    let energy: Int // 0-10
}

/// A consent-controlled integration shown in the Connections panel.
struct Connection: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let isConnected: Bool
}

/// Everything the UI needs, in one value. Mirrors Claude's `PlaybackSnapshot`.
struct PlaybackSnapshot: Equatable {
    var nowPlaying: PlayableTrack?
    var upNext: [PlayableTrack]
    var transport: TransportState
    var dj: DJStatus
    var error: PlaybackError?
    var isLoading: Bool
}

/// Playback contract the UI depends on. Real engine (Claude's PlaybackEngine)
/// conforms later; the UI is built against this so integration is a drop-in.
@MainActor
protocol PlaybackService: ObservableObject {
    var snapshot: PlaybackSnapshot { get }
    var stations: [StationConfig] { get }
    var connections: [Connection] { get }

    func play(_ track: PlayableTrack) async
    func togglePlayPause() async
    func skip() async
    func tune(to station: StationConfig) async
    func moveInQueue(fromOffsets: IndexSet, toOffset: Int)
    func removeFromQueue(_ track: PlayableTrack)
}

/// Mock service for UI development. Deterministic, no network, no MusicKit.
/// Emits the same DJ events the real engine will (speech started/ended).
@MainActor
final class MockPlaybackService: PlaybackService, ObservableObject {
    @Published private(set) var snapshot = PlaybackSnapshot(
        upNext: [], transport: .stopped, dj: .idle, isLoading: false)
    @Published private(set) var stations: [StationConfig] = MockPlaybackService.defaultStations
    @Published private(set) var connections: [Connection] = [
        Connection(id: "calendar", name: "Calendar", icon: "calendar", isConnected: true),
        Connection(id: "obsidian", name: "Notes", icon: "note.text", isConnected: false),
        Connection(id: "messages", name: "Messages", icon: "message", isConnected: false),
    ]

    private let tracks: [PlayableTrack]
    private var index = 0
    private var djModel = MockDJModel()

    init(tracks: [PlayableTrack] = MockPlaybackService.defaultTracks) {
        self.tracks = tracks
        snapshot.upNext = Array(tracks.dropFirst())
    }

    static let defaultTracks: [PlayableTrack] = [
        PlayableTrack(id: "1", title: "Morning Light", artist: "The Calm Collective", artworkURL: nil),
        PlayableTrack(id: "2", title: "Slow Burn", artist: "Neon Harbor", artworkURL: nil),
        PlayableTrack(id: "3", title: "Golden Hour", artist: "Paper Satellites", artworkURL: nil),
    ]

    static let defaultStations: [StationConfig] = [
        StationConfig(id: UUID(), name: "Morning Calm", djName: "Maya",
                      description: "Warm, unhurried host", mood: "Calm", energy: 3),
        StationConfig(id: UUID(), name: "Late Night", djName: "Rico",
                      description: "Smooth vinyl-bar vibes", mood: "Mellow", energy: 4),
        StationConfig(id: UUID(), name: "Focus Flow", djName: "Nia",
                      description: "Deep work, no chatter", mood: "Focused", energy: 5),
    ]

    func play(_ track: PlayableTrack) async {
        snapshot.isLoading = true
        snapshot.error = nil
        try? await Task.sleep(nanoseconds: 600_000_000)
        snapshot.nowPlaying = track
        snapshot.transport = .playing
        snapshot.upNext = tracks.filter { $0.id != track.id }
        snapshot.isLoading = false
        // Simulate a DJ line after the track starts (truthful: speech actually plays).
        djModel.beginSpeech()
        snapshot.dj = djModel.status
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        djModel.endSpeech()
        snapshot.dj = djModel.status
    }

    func togglePlayPause() async {
        guard snapshot.nowPlaying != nil else { return }
        snapshot.transport = (snapshot.transport == .playing) ? .paused : .playing
    }

    func skip() async {
        guard !tracks.isEmpty else { return }
        index = (index + 1) % tracks.count
        await play(tracks[index])
    }

    func tune(to station: StationConfig) async {
        // Mock: tuning swaps the DJ identity; playback continues uninterrupted.
        snapshot.error = nil
        snapshot.isLoading = true
        try? await Task.sleep(nanoseconds: 400_000_000)
        snapshot.isLoading = false
    }

    func moveInQueue(fromOffsets: IndexSet, toOffset: Int) {
        snapshot.upNext.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func removeFromQueue(_ track: PlayableTrack) {
        snapshot.upNext.removeAll { $0.id == track.id }
    }
}

/// Minimal DJ state reducer mirroring Fry's `DJPresentationModel` priority:
/// consent > speaking > preparing > upcoming briefing > idle.
private struct MockDJModel {
    private var speaking = false

    var status: DJStatus { speaking ? .speaking : .idle }

    mutating func beginSpeech() { speaking = true }
    mutating func endSpeech() { speaking = false }
}