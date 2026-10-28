// Compiled only in Debug (so `swift test` runs its tests) and in AERODJ_P0_DIAG builds, like
// DirectModeLayers. A plain Release carries none of it. -Atlas
#if DEBUG || AERODJ_P0_DIAG
import Foundation

// P0 Experiment B, level 8 (-Atlas): Play goes through the real `MusicKitService` path, and the
// service's own calls are traced, observe-only. The app's diag-only `DirectModePlayPathProbe`
// feeds these events from hooks in MusicKitService.swift; this file is the pure, Linux-tested
// part: the event vocabulary, sanitizing and level gating. Each line is
// `+<t>s path.L8 <event> tap+<s>s`: Direct Mode clock, a fixed enum name, seconds since the last
// Play / Resume / Next tap. No titles, IDs, tokens, route names or error text.

/// An error reduced to its NSError domain and code. The domain is cut to [A-Za-z0-9._] and 64
/// characters, so it can never carry free text.
public struct DirectModeErrorTag: Equatable, Sendable, CustomStringConvertible {
    public static let maxDomainLength = 64
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        let allowed = domain.unicodeScalars.filter {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_"
        }
        let cleaned = String(String.UnicodeScalarView(allowed.prefix(Self.maxDomainLength)))
        self.domain = cleaned.isEmpty ? "unknown" : cleaned
        self.code = code
    }

    public init(_ code: PlaybackErrorCode) {
        self.init(domain: code.domain, code: code.code)
    }

    public init(_ error: Error) {
        self.init(PlaybackErrorCode(error))
    }

    public var description: String { "domain=\(domain) code=\(code)" }
}

/// `AVAudioSessionInterruptionReasonKey`, by raw value (AVAudioSessionTypes.h), so Core needs no
/// AVFoundation and the app touches no deprecated case.
public enum DirectModeInterruptionReason: String, Equatable, Sendable {
    /// The key was absent.
    case absent
    case `default`
    case appWasSuspended
    case builtInMicMuted
    case sceneWasBackgrounded
    case routeDisconnected
    case other

    public init(rawReason: UInt?) {
        switch rawReason {
        case nil: self = .absent
        case 0?: self = .default
        case 1?: self = .appWasSuspended
        case 2?: self = .builtInMicMuted
        case 3?: self = .sceneWasBackgrounded
        case 4?: self = .routeDisconnected
        case _?: self = .other
        }
    }
}

/// One step of MusicKitService's play path. Enums, bools and an error tag only.
public enum DirectModePlayPathEvent: Equatable, Sendable {
    /// Level 8's first use of `MusicKitService.shared` this launch (auth refresh: category + observers).
    case serviceEngaged
    /// `AudioSessionActivation.shouldActivate(during: .playback)` was false: no app setActive (#125).
    case setActiveSkipped
    case setActiveStart, setActiveOK
    case setActiveThrew(DirectModeErrorTag)
    case prepareStart, prepareOK
    case prepareThrew(DirectModeErrorTag)
    case playStart, playOK
    case playThrew(DirectModeErrorTag)
    /// From MusicKitService's interruption observer, before the policy sees it.
    case interruptionBegan(reason: DirectModeInterruptionReason, wasSuspended: Bool)
    case interruptionEnded(shouldResume: Bool)
    /// #125's `SelfStartInterruptionGate.decide` in `applySession`, before the policy.
    case selfStartGate(SelfStartInterruptionGate.Decision)
    /// `AudioSessionPolicy.handle` (live or deferred replay): the notice and the directive it returned.
    case sessionPolicy(DirectModeSessionNoticeKind, AudioSessionDirective)
    /// `PlaybackStartGuard.afterPlay` in `playIfStillAllowed`.
    case afterPlay(PlayReturn)
    /// The poll's `RemotePlayGate` said `.pauseBecauseHeld` and the service paused the player.
    case remotePlayGatePause
    /// `pausePlayerForBreak()` ran (break or system hold; the service's own call).
    case pausePlayerForBreak

    public var name: String {
        switch self {
        case .serviceEngaged: return "service.engaged"
        case .setActiveSkipped: return "setActive.skipped"
        case .setActiveStart: return "setActive.start"
        case .setActiveOK: return "setActive.ok"
        case .setActiveThrew(let e): return "setActive.threw \(e)"
        case .prepareStart: return "prepareToPlay.start"
        case .prepareOK: return "prepareToPlay.ok"
        case .prepareThrew(let e): return "prepareToPlay.threw \(e)"
        case .playStart: return "play.start"
        case .playOK: return "play.ok"
        case .playThrew(let e): return "play.threw \(e)"
        case let .interruptionBegan(reason, wasSuspended):
            return "interruption.began reason=\(reason.rawValue) wasSuspended=\(wasSuspended)"
        case .interruptionEnded(let shouldResume): return "interruption.ended shouldResume=\(shouldResume)"
        case .selfStartGate(let d): return "selfStartGate.\(Self.name(d))"
        case let .sessionPolicy(notice, directive):
            return "sessionPolicy.\(notice.rawValue) -> \(DirectModeLayerTraceEntry.name(directive))"
        case .afterPlay(let r): return "afterPlay.\(Self.name(r))"
        case .remotePlayGatePause: return "remotePlayGate.pauseBecauseHeld"
        case .pausePlayerForBreak: return "pausePlayerForBreak"
        }
    }

    static func name(_ d: SelfStartInterruptionGate.Decision) -> String {
        switch d {
        case .apply: return "apply"
        case .deferSelfStart: return "deferSelfStart"
        case .ignorePairedEnd: return "ignorePairedEnd"
        }
    }

    static func name(_ r: PlayReturn) -> String {
        switch r {
        case .keepPlaying: return "keepPlaying"
        case .pauseBecauseHeld: return "pauseBecauseHeld"
        }
    }
}

public struct DirectModePlayPathEntry: Equatable, Sendable, CustomStringConvertible {
    /// Seconds since Direct Mode opened (the Direct Mode log's clock).
    public let t: Double
    /// Seconds since the last Play / Resume / Next tap; nil before the first tap.
    public let sinceTap: Double?
    public let event: DirectModePlayPathEvent

    public var description: String {
        let tap = sinceTap.map { "tap" + String(format: "%+.2f", $0) + "s" } ?? "tap=none"
        return "+" + String(format: "%.2f", t) + "s path.L8 " + event.name + " " + tap
    }
}

/// Level 8's trace. Records only at level 8; at any other level `record` drops everything, so
/// the hooks in MusicKitService.swift change nothing anyone can see.
public struct DirectModePlayPathTrace: Sendable {
    public static let capacity = 300

    public let isEnabled: Bool
    public private(set) var entries: [DirectModePlayPathEntry] = []
    public private(set) var lastTapAt: Double?

    public init(level: DirectModeLayerLevel) {
        isEnabled = level.routesThroughMusicKitService
    }

    /// The tester tapped Play, Resume or Next.
    public mutating func tapped(at t: Double) {
        guard isEnabled else { return }
        lastTapAt = t
    }

    public mutating func record(_ event: DirectModePlayPathEvent, at t: Double) {
        guard isEnabled else { return }
        entries.append(DirectModePlayPathEntry(t: t, sinceTap: lastTapAt.map { t - $0 }, event: event))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// `DirectModeSessionLayer.mergedLog` plus level 8's lines, oldest first by t. On a tie:
    /// Direct Mode, layers, S, then level 8. With an empty `path` it is exactly that function.
    public static func mergedLog(_ log: [DirectModeLogEntry], _ layers: [DirectModeLayerTraceEntry],
                                 _ session: [DirectModeSessionTraceEntry],
                                 _ path: [DirectModePlayPathEntry]) -> [String] {
        let tagged = log.enumerated().map { (t: $0.element.t, rank: 0, i: $0.offset, line: $0.element.description) }
            + layers.enumerated().map { (t: $0.element.t, rank: 1, i: $0.offset, line: $0.element.description) }
            + session.enumerated().map { (t: $0.element.t, rank: 2, i: $0.offset, line: $0.element.description) }
            + path.enumerated().map { (t: $0.element.t, rank: 3, i: $0.offset, line: $0.element.description) }
        return tagged.sorted { ($0.t, $0.rank, $0.i) < ($1.t, $1.rank, $1.i) }.map(\.line)
    }
}
#endif
