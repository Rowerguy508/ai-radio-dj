#if DEBUG
import Foundation

// #526 S0a (-Echo): DEBUG-only spike. One question: on an AirPlay route, can our DJ audio play
// over Apple Music that is ducked rather than paused? Release does not compile this file. No
// setting, launch argument, URL or default reaches it; the only entry is the DEBUG Developer
// row in Settings (`AirPlayDuckSpikeView`). It never runs inside a DJ break, and it plays one
// 2 s test tone with one player, so two voices never play at once.

/// The session shapes the spike tries, one per run. All are existing `DJSessionConfig` values.
public enum AirPlayDuckSpikeVariant: String, CaseIterable, Equatable, Sendable {
    /// Today's talk-over duck: `.playback`, default policy, `[.duckOthers]`.
    case duckOthers
    /// #525's AirPlay gap session: `.playback`, `.longFormAudio`, no options (Atlas's S0a).
    case longFormAudio
    /// Control: today's normal session, `[.mixWithOthers]`, no duck.
    case mixWithOthers

    public var config: DJSessionConfig {
        switch self {
        case .duckOthers: .talkoverDuck
        case .longFormAudio: .airPlayGap
        case .mixWithOthers: .normal
        }
    }

    /// Codes only, for the log.
    public var sessionDescription: String {
        let c = config
        return "category=\(c.category.rawValue) mode=\(c.mode.rawValue) policy=\(c.policy.rawValue) options=0x\(String(c.options.rawValue, radix: 16))"
    }
}

/// Why the spike refuses to start. Each one keeps it from overlapping a DJ voice or a break.
public enum AirPlayDuckSpikeRefusal: String, Equatable, Sendable {
    case alreadyRunning
    case notOnAirPlay
    case musicNotPlaying
    /// A DJ break is on air or handed out (state `.voice` / `.transition`), or a talk-over holds the session.
    case djBusy
    /// Too close to the song's end: a boundary, break or talk-over arm window could start mid-spike.
    case tooCloseToSongEnd
}

public enum AirPlayDuckSpikeGate {
    /// The song must have at least this long left, well past the talk-over arm window (7.5 s).
    public static let minimumRemainingSeconds: Double = 30

    public static func refusal(running: Bool, onAirPlay: Bool, musicPlaying: Bool, djIdle: Bool,
                               remainingSeconds: Double?) -> AirPlayDuckSpikeRefusal? {
        if running { return .alreadyRunning }
        if !djIdle { return .djBusy }
        if !onAirPlay { return .notOnAirPlay }
        if !musicPlaying { return .musicNotPlaying }
        guard let remainingSeconds, remainingSeconds >= minimumRemainingSeconds else { return .tooCloseToSongEnd }
        return nil
    }
}

/// What the music did while our clip played. Ducking itself is not readable (MusicKit has no
/// volume), so `keptPlaying` means "the owner judges duck or no duck by ear".
public enum AirPlayDuckSpikeMusicOutcome: String, Equatable, Sendable {
    case keptPlaying
    case paused
    case stopped
    case interrupted
    case unknown

    /// From the music player's status samples during the clip (raw MusicKit status names).
    public static func classify(_ statuses: [String]) -> AirPlayDuckSpikeMusicOutcome {
        guard !statuses.isEmpty else { return .unknown }
        if statuses.contains("interrupted") { return .interrupted }
        if statuses.contains("stopped") { return .stopped }
        if statuses.contains("paused") { return .paused }
        if statuses.allSatisfy({ $0 == "playing" }) { return .keptPlaying }
        return .unknown
    }
}

/// One run's log, codes and milliseconds only (Sentinel's privacy bar on #526: port types, no
/// port names, UIDs or device names).
public struct AirPlayDuckSpikeReport: Equatable, Sendable {
    public var variant: AirPlayDuckSpikeVariant
    public var routeBefore: [LongFormPortType] = []
    public var routeDuring: [LongFormPortType] = []
    public var routeAfter: [LongFormPortType] = []
    public var musicBefore = ""
    public var musicDuring: [String] = []
    public var musicAfter = ""
    public var systemMusicBefore = ""
    public var systemMusicDuring: [String] = []
    public var setCategoryOK = false
    public var setActiveOK = false
    public var activateMs: Int?
    public var otherAudioPlaying: Bool?
    public var silenceHint: Bool?
    public var clipStarted = false
    public var clipFinishedOK: Bool?
    public var interruptionBegan = false
    public var interruptionEnded = false
    public var routeChangeReasons: [String] = []
    public var restoreOK = false
    public var refusal: AirPlayDuckSpikeRefusal?

    public init(variant: AirPlayDuckSpikeVariant) { self.variant = variant }

    public var musicOutcome: AirPlayDuckSpikeMusicOutcome {
        interruptionBegan ? .interrupted : AirPlayDuckSpikeMusicOutcome.classify(musicDuring)
    }

    private static func ports(_ p: [LongFormPortType]) -> String {
        p.isEmpty ? "none" : p.map(\.rawValue).joined(separator: "+")
    }

    private static func flag(_ b: Bool?) -> String { b.map { $0 ? "1" : "0" } ?? "-" }

    /// The lines the app logs (OSLog, category "playback") and shows on screen for copying.
    public var lines: [String] {
        if let refusal { return ["S0a variant=\(variant.rawValue) refused=\(refusal.rawValue)"] }
        return [
            "S0a variant=\(variant.rawValue) \(variant.sessionDescription)",
            "S0a route before=\(Self.ports(routeBefore)) during=\(Self.ports(routeDuring)) after=\(Self.ports(routeAfter))",
            "S0a session setCategory=\(Self.flag(setCategoryOK)) setActive=\(Self.flag(setActiveOK)) activateMs=\(activateMs.map(String.init) ?? "-") otherAudio=\(Self.flag(otherAudioPlaying)) silenceHint=\(Self.flag(silenceHint))",
            "S0a music before=\(musicBefore) during=\(musicDuring.joined(separator: ",")) after=\(musicAfter) outcome=\(musicOutcome.rawValue)",
            "S0a systemMusic before=\(systemMusicBefore) during=\(systemMusicDuring.joined(separator: ","))",
            "S0a clip started=\(Self.flag(clipStarted)) finished=\(Self.flag(clipFinishedOK)) interruption began=\(Self.flag(interruptionBegan)) ended=\(Self.flag(interruptionEnded))",
            "S0a routeChanges=\(routeChangeReasons.isEmpty ? "none" : routeChangeReasons.joined(separator: ",")) restore=\(Self.flag(restoreOK))",
        ]
    }
}

/// The spike's only audio: a 2 s 440 Hz tone, 16-bit mono PCM WAV, with 100 ms fades. It stands
/// in for the DJ voice so the spike needs no voice provider, no network and no paid service.
public enum AirPlayDuckSpikeClip {
    public static let seconds: Double = 2
    public static let sampleRate = 44_100

    public static func toneWAV(seconds: Double = seconds, frequency: Double = 440, level: Double = 0.25) -> Data {
        let count = Int(Double(sampleRate) * seconds)
        let fade = Int(Double(sampleRate) * 0.1)
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            var gain = level
            if i < fade { gain *= Double(i) / Double(fade) }
            if i >= count - fade { gain *= Double(count - 1 - i) / Double(fade) }
            let value = Int16(max(-1, min(1, gain * sin(2 * .pi * frequency * Double(i) / Double(sampleRate)))) * Double(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
#endif
