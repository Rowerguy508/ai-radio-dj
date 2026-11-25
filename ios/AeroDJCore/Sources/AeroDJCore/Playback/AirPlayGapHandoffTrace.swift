// #526 S0b (-Echo): DIAG-only timestamps for one AirPlay gap-break handoff.
// Compiled only in Debug (so `swift test` runs its tests) and in AERODJ_P0_DIAG builds.
// Never in Release. Pure assembly: no session call, no scheduler, no playback.
#if DEBUG || AERODJ_P0_DIAG
import Foundation

/// Collects monotonic timestamps for one AirPlay gap break and emits one DIAG row.
///
/// Every `at:` value is on the same clock `P0EventTrace.record(_:at:)` uses
/// (the host's seconds-since-launch uptime). Relative milliseconds are differences
/// on that clock, never a second time source.
///
/// Steps, in order: song end seen → first DJ clip `play()` → last clip
/// `audioPlayerDidFinishPlaying` → `setActive(false)` (`completeNarration`) → next song
/// `play()` (`startNextTrack`) → MusicKit status `.playing`, plus the session's
/// `outputLatency` on the route, in milliseconds. A skipped or failed step is reported
/// as `missing=…` (codes only); it is never dropped. No API takes a free-form String,
/// so a port name, UID, device name, title or station name cannot reach a row.
public struct AirPlayGapHandoffTrace: Equatable, Sendable {
    public enum Step: String, Equatable, Sendable, CaseIterable {
        case songEnd, firstPlay, lastFinish, sessionOff, nextPlay, musicPlaying
    }

    public enum Outcome: String, Equatable, Sendable, CaseIterable {
        case complete, skipped, timedOut, failed, incomplete
    }

    public struct Row: Equatable, Sendable {
        public let afterTrack: Int?
        /// Milliseconds relative to song end (or to the earliest stamp if song end is missing).
        public let milliseconds: [Step: Int]
        /// Steps that were not recorded, in canonical `Step` order.
        public let missing: [Step]
        public let outcome: Outcome
        public let outputLatencyMs: Int?

        public init(afterTrack: Int?, milliseconds: [Step: Int], missing: [Step],
                    outcome: Outcome, outputLatencyMs: Int?) {
            self.afterTrack = afterTrack
            self.milliseconds = milliseconds
            self.missing = missing
            self.outcome = outcome
            self.outputLatencyMs = outputLatencyMs
        }

        /// Stable `k=v` line: codes and milliseconds only.
        public var detail: String {
            func ms(_ step: Step) -> String { milliseconds[step].map(String.init) ?? "-" }
            let after = afterTrack.map(String.init) ?? "-"
            let latency = outputLatencyMs.map(String.init) ?? "-"
            let missingValue = missing.isEmpty ? "-" : missing.map(\.rawValue).joined(separator: "+")
            return "kind=handoff after=\(after) result=\(outcome.rawValue) songEnd=\(ms(.songEnd)) firstPlay=\(ms(.firstPlay)) lastFinish=\(ms(.lastFinish)) sessionOff=\(ms(.sessionOff)) nextPlay=\(ms(.nextPlay)) musicPlaying=\(ms(.musicPlaying)) latency=\(latency) missing=\(missingValue)"
        }
    }

    public private(set) var isOpen = false
    private var afterTrack: Int?
    private var stamps: [Step: TimeInterval] = [:]
    private var outputLatencyMs: Int?
    private var outcome: Outcome?

    public init() {}

    /// Starts a new break at `t` (the `record(_:at:)` clock). A still-open previous break is finalized
    /// first, with its missing steps reported, and never dropped.
    @discardableResult
    public mutating func begin(afterTrack: Int, outputLatency: TimeInterval? = nil,
                               at t: TimeInterval) -> Row? {
        let previous = finalize()
        isOpen = true
        self.afterTrack = afterTrack
        stamps = [.songEnd: t]
        outputLatencyMs = Self.latencyMs(outputLatency)
        outcome = nil
        return previous
    }

    /// Records `step` at `t` if this break is open and that step has not already been
    /// recorded (first stamp wins). `outputLatency`, when valid, replaces a previous reading
    /// (the long-form route reading at first `play()` is preferred). Returns a row when
    /// MusicKit `.playing` is observed, so the caller can emit it.
    @discardableResult
    public mutating func mark(_ step: Step, outputLatency: TimeInterval? = nil,
                              at t: TimeInterval) -> Row? {
        guard isOpen else { return nil }
        // `.playing` counts only for the next song: a poll before its `play()` is ignored.
        if step == .musicPlaying, stamps[.nextPlay] == nil { return nil }
        if stamps[step] == nil { stamps[step] = t }
        if let ms = Self.latencyMs(outputLatency) { outputLatencyMs = ms }
        if step == .musicPlaying { return finalize() }
        return nil
    }

    /// Notes why the break ended short of a full handoff (skip, timeout, failed start).
    /// Does not emit; later steps (session release, next `play()`, `.playing`) still record.
    public mutating func note(_ outcome: Outcome) {
        guard isOpen, self.outcome == nil, outcome != .complete else { return }
        self.outcome = outcome
    }

    /// Emits the open break now, filling in every missing step. Nil when nothing is open.
    @discardableResult
    public mutating func finalize() -> Row? {
        guard isOpen else { return nil }
        let row = Self.assemble(afterTrack: afterTrack, stamps: stamps,
                                outputLatencyMs: outputLatencyMs, noted: outcome)
        isOpen = false
        afterTrack = nil
        stamps = [:]
        outputLatencyMs = nil
        outcome = nil
        return row
    }

    /// Builds a row from recorded stamps. `songEnd` is t=0; other times are milliseconds
    /// relative to it (or to the earliest stamp if song end itself is missing).
    public static func assemble(afterTrack: Int?, stamps: [Step: TimeInterval],
                                outputLatencyMs: Int?, noted: Outcome?) -> Row {
        let origin = stamps[.songEnd] ?? stamps.values.min()
        var milliseconds: [Step: Int] = [:]
        if let origin {
            for (step, time) in stamps {
                milliseconds[step] = Int(((time - origin) * 1000).rounded())
            }
        }
        let missing = Step.allCases.filter { milliseconds[$0] == nil }
        let outcome: Outcome
        if missing.isEmpty {
            outcome = .complete
        } else if let noted {
            outcome = noted
        } else if missing.contains(.firstPlay) {
            outcome = .skipped
        } else {
            outcome = .incomplete
        }
        return Row(afterTrack: afterTrack, milliseconds: milliseconds, missing: missing,
                   outcome: outcome, outputLatencyMs: outputLatencyMs)
    }

    /// Finite, non-negative seconds → rounded milliseconds. Invalid or nil → nil.
    public static func latencyMs(_ seconds: TimeInterval?) -> Int? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }
}

/// #526 S2 (-Echo): one sample of the DIAG `musicPlaying` stamp. The app
/// captures the start's attempt and asks this before each stamp and each wait.
/// A superseded attempt (a pause and resume begins a new one) must not stamp
/// the resume as `musicPlaying`.
public enum AirPlayGapMusicPlayingSampler: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// MusicKit is `.playing` and the start still owns the player.
        case stamp
        /// The start still owns the player, but MusicKit is not `.playing` yet.
        case wait
        /// The start is no longer current. Do not stamp; cancel the sampler.
        case cancel
    }

    public static func step(isCurrent: Bool, playbackIsPlaying: Bool) -> Action {
        guard isCurrent else { return .cancel }
        return playbackIsPlaying ? .stamp : .wait
    }
}
#endif
