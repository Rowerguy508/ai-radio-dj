import Foundation

/// Audio playback state machine: `idle -> music -> transition -> voice -> music`.
/// Pure and deterministic; the MusicKit adapter drives it. No protected-stream mixing.
public enum AudioState: String, Codable, Equatable, Sendable {
    case idle
    case music
    case transition
    case voice
}

public enum AudioEvent: String, Codable, Equatable, Sendable {
    case startMusic
    case trackEnded
    case interludeReady
    case interludeEnded
    case pause
    case resume
    case stop
}

public struct AudioStateMachine: Sendable {
    public private(set) var state: AudioState

    public init(state: AudioState = .idle) {
        self.state = state
    }

    /// Returns the new state after applying `event`. Invalid transitions are ignored.
    @discardableResult
    public mutating func apply(_ event: AudioEvent) -> AudioState {
        switch (state, event) {
        case (.idle, .startMusic):
            state = .music
        case (.music, .trackEnded):
            state = .transition
        case (.transition, .interludeReady):
            state = .voice
        case (.voice, .interludeEnded):
            state = .music
        case (_, .pause):
            // Pause is valid from any active state; keep the current state so
            // resume returns to the same phase.
            break
        case (_, .resume):
            break
        case (_, .stop):
            state = .idle
        default:
            // Invalid transition: ignore.
            break
        }
        return state
    }

    public var isActive: Bool {
        state != .idle
    }
}
