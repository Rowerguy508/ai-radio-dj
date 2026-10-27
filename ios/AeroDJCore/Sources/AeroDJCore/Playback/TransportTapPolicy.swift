import Foundation

/// Build 9 P0 (-Atlas; Orion, Nova, Sentinel): what a tap on the in-app Play/Pause button does,
/// and what the button shows. Pure, so the double-tap rule is tested on Linux.
///
/// While a start is `.preparing`, a second tap used to call `pause()` and kill the start the user
/// had just asked for. Now a tap during `.preparing` does nothing until the current attempt's
/// 8 s confirm deadline is reported. After that the button is "Stop": a tap cancels the start as a
/// user pause, so a late `.playing` cannot start audio the user turned down.
public enum TransportTapDecision: Equatable, Sendable {
    /// `.preparing`, before the deadline: no pause, no new attempt.
    case ignore
    /// `.preparing`, after the deadline report: user pause and cancel the attempt.
    case cancelStart
    /// `.playing`: user pause.
    case pause
    /// `.paused` / `.stopped`: resume.
    case play
}

/// The button's face. Label and glyph only; layout and size do not change.
public enum TransportButtonFace: Equatable, Sendable {
    /// Spinner only, VoiceOver "Starting playback", not announced as a button (Nova).
    case starting
    case stop
    case pause
    case play

    public var accessibilityLabel: String {
        switch self {
        case .starting: "Starting playback"
        case .stop: "Stop"
        case .pause: "Pause"
        case .play: "Play"
        }
    }

    /// Nil for `.starting`, which shows only the spinner.
    public var systemImage: String? {
        switch self {
        case .starting: nil
        case .stop: "stop.fill"
        case .pause: "pause.fill"
        case .play: "play.fill"
        }
    }

    /// False for `.starting`: no button trait and no action for VoiceOver.
    public var isActionable: Bool { self != .starting }
}

public enum TransportTapPolicy {
    public static func decide(transport: TransportState, startTimedOut: Bool) -> TransportTapDecision {
        switch transport {
        case .preparing: startTimedOut ? .cancelStart : .ignore
        case .playing: .pause
        case .paused, .stopped: .play
        }
    }

    public static func face(transport: TransportState, startTimedOut: Bool) -> TransportButtonFace {
        switch decide(transport: transport, startTimedOut: startTimedOut) {
        case .ignore: .starting
        case .cancelStart: .stop
        case .pause: .pause
        case .play: .play
        }
    }
}
