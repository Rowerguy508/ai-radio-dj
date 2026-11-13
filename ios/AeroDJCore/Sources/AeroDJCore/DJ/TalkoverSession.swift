import Foundation

// DJ talk-over session order and voice fades (-Fry). Pure: the app (`TalkoverAudioSession`,
// `InterludePlaybackAdapter`) executes these steps and ramps; nothing here touches audio.
//
// Root cause this fixes (code reading, NOT device evidence): `decodeTalkover` called
// `AVAudioPlayer.prepareToPlay()`, which activates the app's audio session (Apple doc), with the
// mix-only category, about 1.5 s before `duck()`. `duck()` then set `.duckOthers` on a session
// that was already active and called `setActive(true)` on it. Apple: "Ducking begins when you
// activate your app's audio session", so that activation was most likely not a real one.

/// One audio-session step around the talk-over voice.
public enum TalkoverSessionStep: Equatable, Sendable {
    /// `setActive(false)`; `notifyOthers` adds `.notifyOthersOnDeactivation` (the unduck).
    case deactivate(notifyOthers: Bool)
    /// `setCategory(.playback, mode: .default, options: [.duckOthers])`.
    case setDuckCategory
    /// `setActive(true)`: ducking of other sessions starts here.
    case activate
    /// `setCategory(.playback, mode: .default, options: [.mixWithOthers])` (the app's normal one).
    case restoreCategory
}

public enum TalkoverSessionSequence {
    /// Quiet deactivation first, so the activation is real even if something activated the
    /// session earlier; then the duck option; then the activation.
    public static let duck: [TalkoverSessionStep] = [.deactivate(notifyOthers: false), .setDuckCategory, .activate]

    /// The unduck, and the release of a duck whose voice never spoke: deactivate with notify (the
    /// other session swells back), then the normal category on the inactive session.
    public static let release: [TalkoverSessionStep] = [.deactivate(notifyOthers: true), .restoreCategory]

    /// The ordering rule: the duck option is set before the activation, the activation is the
    /// last step, and a deactivation precedes both.
    public static func ducksOnActivation(_ steps: [TalkoverSessionStep]) -> Bool {
        guard let category = steps.firstIndex(of: .setDuckCategory),
              let activate = steps.firstIndex(of: .activate),
              let off = steps.firstIndex(where: { if case .deactivate = $0 { return true } else { return false } })
        else { return false }
        return off < category && category < activate && activate == steps.count - 1
    }
}

/// When the duck runs against the voice start (song clock).
public enum TalkoverSessionTiming {
    /// Time the app needs between the decision and the duck (take, decode, gains).
    public static let decideMargin: Double = 0.5

    /// Song time of the duck: `duckLead` before the planned voice start.
    public static func duckAt(voiceStartAt: Double, config: TalkoverConfig = TalkoverConfig()) -> Double {
        voiceStartAt - max(0, config.duckLead)
    }

    /// The config is coherent: a positive duck lead that fits inside `armLead` with
    /// `decideMargin` to spare, so a planned talk-over always has time to duck before it speaks.
    public static func isCoherent(_ config: TalkoverConfig) -> Bool {
        config.duckLead.isFinite && config.duckLead > 0 && config.duckLead + decideMargin <= config.armLead
    }

    /// Milliseconds from the duck activation to the voice's real start (uptimes). Nil if unknown.
    public static func duckToVoiceMs(duckedAt: Double?, voiceAt: Double?) -> Int? {
        guard let d = duckedAt, let v = voiceAt, d.isFinite, v.isFinite else { return nil }
        return Int(((v - d) * 1000).rounded())
    }
}

/// A short fade on OUR voice clip (not on Apple Music, which has no volume API).
public struct TalkoverVoiceRamp: Equatable, Sendable {
    /// Default fade in and out.
    public static let fadeSeconds: Double = 0.2

    /// `AVAudioPlayer.volume` before `play()`.
    public var startVolume: Float
    /// Target level (the loudness-matched gain).
    public var gain: Float
    /// `setVolume(gain, fadeDuration: fadeIn)` as the clip's audio starts.
    public var fadeIn: Double
    /// Clip time (from its first sample) of `setVolume(0, fadeDuration: fadeOut)`.
    public var fadeOutAt: Double
    public var fadeOut: Double

    /// The ramp for one clip. Fades are at most half the clip, so they never overlap. A clip
    /// with no usable duration plays flat at `gain`.
    public static func plan(duration: Double, gain: Float, fade: Double = fadeSeconds) -> TalkoverVoiceRamp {
        let g = gain.isFinite ? min(max(gain, 0), 1) : 1
        guard duration.isFinite, duration > 0, fade.isFinite, fade > 0 else {
            return TalkoverVoiceRamp(startVolume: g, gain: g, fadeIn: 0, fadeOutAt: max(0, duration.isFinite ? duration : 0), fadeOut: 0)
        }
        let f = min(fade, duration / 2)
        return TalkoverVoiceRamp(startVolume: 0, gain: g, fadeIn: f, fadeOutAt: duration - f, fadeOut: f)
    }

    /// Level at clip time `t` (linear ramps), for tests and the docs.
    public func level(at t: Double) -> Float {
        if t < 0 { return startVolume }
        if fadeIn > 0, t < fadeIn { return startVolume + (gain - startVolume) * Float(t / fadeIn) }
        if fadeOut > 0, t >= fadeOutAt {
            let x = min(1, (t - fadeOutAt) / fadeOut)
            return gain * Float(1 - x)
        }
        return gain
    }
}
