// Compiled only in Debug (so `swift test` runs its tests) and in AERODJ_P0_DIAG builds.
// A plain Release carries none of it. -Fry
#if DEBUG || AERODJ_P0_DIAG
import Foundation

// TEMPORARY P0 Experiment A follow-up (-Fry): what the app's audio session looked like while
// MusicKit reported `.playing` but the owner heard the start soft. READ-ONLY: Direct Mode still
// makes no AVAudioSession calls. Sanitized like the rest of Direct Mode: enums, booleans and
// rounded numbers only. No port names, titles, catalog IDs or localizedDescription.

/// `AVAudioSession.Category`, as a Sendable value.
public enum DirectModeSessionCategory: String, Equatable, Sendable {
    case soloAmbient, ambient, playback, playAndRecord, record, multiRoute, other
}

/// `AVAudioSession.Mode`, as a Sendable value.
public enum DirectModeSessionMode: String, Equatable, Sendable {
    case `default`, moviePlayback, spokenAudio, voiceChat, videoChat, gameChat, videoRecording,
         measurement, voicePrompt, other
}

/// `AVAudioSession.InterruptionReason`, as a Sendable value. `.none` when the key is absent.
public enum DirectModeInterruptionReason: String, Equatable, Sendable {
    case none, `default`, appWasSuspended, builtInMicMuted, routeDisconnected, other
}

/// `AVAudioSession.RouteChangeReason`, as a Sendable value.
public enum DirectModeRouteChangeReason: String, Equatable, Sendable {
    case unknown, newDeviceAvailable, oldDeviceUnavailable, categoryChange, override,
         wakeFromSleep, noSuitableRouteForCategory, routeConfigurationChange, other
}

/// One read of the app's shared audio session.
public struct DirectModeAudioSample: Equatable, Sendable, CustomStringConvertible {
    /// `outputVolume`, rounded to the nearest 0.05.
    public let outputVolume: Double
    public let route: DirectModeRoute
    public let category: DirectModeSessionCategory
    public let mode: DirectModeSessionMode
    public let otherAudioPlaying: Bool
    public let secondaryAudioShouldBeSilenced: Bool
    /// `outputLatency` in whole milliseconds.
    public let outputLatencyMs: Int

    public init(outputVolume: Double, route: DirectModeRoute, category: DirectModeSessionCategory,
                mode: DirectModeSessionMode, otherAudioPlaying: Bool,
                secondaryAudioShouldBeSilenced: Bool, outputLatencySeconds: Double) {
        let clamped = min(1, max(0, outputVolume.isFinite ? outputVolume : 0))
        self.outputVolume = (clamped * 20).rounded() / 20
        self.route = route
        self.category = category
        self.mode = mode
        self.otherAudioPlaying = otherAudioPlaying
        self.secondaryAudioShouldBeSilenced = secondaryAudioShouldBeSilenced
        let ms = outputLatencySeconds.isFinite ? outputLatencySeconds * 1000 : 0
        self.outputLatencyMs = Int(min(10_000, max(0, ms)).rounded())
    }

    public var description: String {
        "vol=" + String(format: "%.2f", outputVolume) + " route=\(route.rawValue) cat=\(category.rawValue)"
            + " mode=\(mode.rawValue) otherAudio=\(otherAudioPlaying) silenceHint=\(secondaryAudioShouldBeSilenced)"
            + " latMs=\(outputLatencyMs)"
    }
}

/// An `AVAudioSession` notification, sanitized.
public enum DirectModeAudioEvent: Equatable, Sendable, CustomStringConvertible {
    case interruptionBegan(DirectModeInterruptionReason)
    case interruptionEnded(shouldResume: Bool)
    case routeChange(DirectModeRouteChangeReason)
    case silenceSecondaryAudioHint(begin: Bool)

    public var description: String {
        switch self {
        case .interruptionBegan(let r): return "interruption.began reason=\(r.rawValue)"
        case .interruptionEnded(let resume): return "interruption.ended shouldResume=\(resume)"
        case .routeChange(let r): return "routeChange reason=\(r.rawValue)"
        case .silenceSecondaryAudioHint(let begin): return "silenceHint.\(begin ? "begin" : "end")"
        }
    }
}
#endif
