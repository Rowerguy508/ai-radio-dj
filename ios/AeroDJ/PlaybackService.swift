import Foundation
import Combine
import AeroDJCore

/// Playback contract the UI depends on. Uses Claude's shared playback state
/// (`PlaybackSnapshot`, `TrackInfo`, `TransportState`, `DJActivity`,
/// `PlaybackError`) and queue contract (`UpNextEdit`/`UpNextEditor`) from
/// AeroDJCore — no competing models. The real engine (Claude's PlaybackEngine)
/// conforms later; the mock is a labeled stand-in.
@MainActor
protocol PlaybackService: ObservableObject {
    var snapshot: PlaybackSnapshot { get }
    var stations: [StationConfig] { get }
    var connections: [Connection] { get }

    func play(_ track: TrackInfo) async
    func togglePlayPause() async
    func skip() async
    func tune(to station: StationConfig) async

    /// Apply a single up-next edit via Claude's UpNextEditor.
    @discardableResult
    func applyQueueEdit(_ edit: UpNextEdit) -> Result<[TrackInfo], UpNextEditError>
}

/// A station the user can tune to. UI-facing subset of Fry's station-config
/// contract (genres/moods/energy/DJ personality). LABELED MOCK — pending Fry's
/// station-config model.
struct StationConfig: Identifiable, Hashable {
    let id: UUID
    let name: String
    let djName: String
    let description: String
    let artName: String // SF Symbol name; real artwork lands with real config
    let mood: String
    let energy: Int // 0-10
}

/// A consent-controlled integration shown in the Connections panel.
/// LABELED MOCK — pending Fry's connection-state contract.
struct Connection: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let isConnected: Bool
}

/// MOCK playback service for UI development. Deterministic, no network, no
/// MusicKit. Emits the same DJ events the real engine will (speech started/
/// ended). Uses Claude's `PlaybackSnapshot` type so the UI is contract-correct.
@MainActor
final class MockPlaybackService: PlaybackService, ObservableObject {
    @Published private(set) var snapshot = PlaybackSnapshot(
        upNext: [], transport: .stopped, dj: .idle)
    @Published private(set) var stations: [StationConfig] = MockPlaybackService.defaultStations
    @Published private(set) var connections: [Connection] = [
        Connection(id: "calendar", name: "Calendar", icon: "calendar", isConnected: true),
        Connection(id: "obsidian", name: "Notes", icon: "note.text", isConnected: false),
        Connection(id: "messages", name: "Messages", icon: "message", isConnected: false),
    ]

    private let tracks: [TrackInfo]
    private var index = 0
    private var speaking = false

    init(tracks: [TrackInfo] = MockPlaybackService.defaultTracks) {
        self.tracks = tracks
        snapshot.upNext = Array(tracks.dropFirst())
        applyLaunchDemoState()
    }

    static let defaultTracks: [TrackInfo] = [
        TrackInfo(id: "1", title: "Morning Light", artistName: "The Calm Collective"),
        TrackInfo(id: "2", title: "Slow Burn", artistName: "Neon Harbor"),
        TrackInfo(id: "3", title: "Golden Hour", artistName: "Paper Satellites"),
        TrackInfo(id: "4", title: "Silver Lining", artistName: "Heron & Finch"),
    ]

    static let defaultStations: [StationConfig] = [
        StationConfig(id: UUID(), name: "Morning Calm", djName: "Maya",
                      description: "Warm, unhurried host", artName: "sun.max.fill",
                      mood: "Calm", energy: 3),
        StationConfig(id: UUID(), name: "Late Night", djName: "Rico",
                      description: "Smooth vinyl-bar vibes", artName: "moon.stars.fill",
                      mood: "Mellow", energy: 4),
        StationConfig(id: UUID(), name: "Focus Flow", djName: "Nia",
                      description: "Deep work, no chatter", artName: "sparkles",
                      mood: "Focused", energy: 5),
    ]

    func play(_ track: TrackInfo) async {
        snapshot.error = nil
        snapshot.nowPlaying = track
        snapshot.transport = .playing
        snapshot.upNext = tracks.filter { $0.id != track.id }
        // Simulate a DJ line after the track starts (truthful: speech actually plays).
        speaking = true
        snapshot.dj = .speaking(line: "That was \(track.title).")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        speaking = false
        snapshot.dj = .idle
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
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    @discardableResult
    func applyQueueEdit(_ edit: UpNextEdit) -> Result<[TrackInfo], UpNextEditError> {
        let result = UpNextEditor.apply(edit, to: snapshot.upNext, nowPlaying: snapshot.nowPlaying)
        if case .success(let list) = result {
            snapshot.upNext = list
        }
        return result
    }

    /// Screenshot harness: `AERODJ_DEMO` pre-populates a state so CI captures
    /// realistic shots. Values: `playing` (now-playing + speaking), `error`.
    private func applyLaunchDemoState() {
        let demo = ProcessInfo.processInfo.environment["AERODJ_DEMO"]
        switch demo {
        case "playing":
            snapshot.nowPlaying = tracks[0]
            snapshot.transport = .playing
            snapshot.upNext = Array(tracks.dropFirst())
            speaking = true
            snapshot.dj = .speaking(line: "Good morning. Here's what's ahead.")
        case "error":
            snapshot.error = PlaybackError(
                kind: .playbackFailed,
                message: "Could not start this station. Check your connection.",
                isRecoverable: true)
        default:
            break // empty state
        }
    }
}