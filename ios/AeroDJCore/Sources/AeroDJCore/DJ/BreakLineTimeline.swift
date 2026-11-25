import Foundation

// The break's line clock across a system interruption (#377, -Fry). Pure: no audio session,
// no player, and no timer that fires on its own. The app does not call this type. It models
// the decisions `InterludePlaybackAdapter` already makes; the tests prove the model, and a
// source pin checks the adapter still pauses before any halt. Linux green is not device evidence.
//
// A `.playback` session that mixes with others may get no `.began` at all, so this clock never
// runs for that notice. Whether Siri delivers `.began` is the Duo P0 DIAG `interruption` rows.

/// What `MusicKitService`'s untagged `.interruption` stop does to a break the state machine
/// has already classified. A speaking gap break is paused. It is not cancelled.
public enum BreakTimelineStop: Equatable, Sendable {
    /// Apply the interruption action. Do not halt the break.
    case apply
    /// Talk-over, or audio the state machine is not tracking: the caller's existing halt.
    case halt
    /// Duplicate notice, or a break already held. Do not halt and do not apply again.
    case ignore
}

public enum BreakTimelineStopPolicy {
    /// `action` is `BreakInterruptionState.interruptionBegan`. `isHolding` is the machine
    /// after that call. A pause is `.apply`. A second `.began` while already paused is
    /// `.ignore`. Talk-over is `.halt` (the outro is not replayed).
    public static func untaggedInterruption(_ action: BreakInterruptionState.Action, isHolding: Bool) -> BreakTimelineStop {
        switch action {
        case .stopTalkover:
            return .halt
        case .none:
            return isHolding ? .ignore : .halt
        case .pause, .playAcknowledgement, .resume, .stayPaused:
            return .apply
        }
    }
}

/// Script lines and the one acknowledgement, on a clock the tests advance.
///
/// `.began` disarms the line timer: a later `advance` starts no next line. `.ended` with
/// `shouldResume` and a ready acknowledgement appends exactly one acknowledgement, then the
/// interrupted line from its beginning. Without `shouldResume` this model stays `.held` and
/// disarmed. The adapter is not identical there: it then ends that break as cancelled so the
/// break does not stay open, and music stays held. No break, a second `.began`, or a second
/// `.ended` changes nothing. An interruption during the acknowledgement pauses it and does not
/// play a second one. Talk-over stops and is not replayed.
public struct BreakLineTimeline: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case scriptLine(Int)
        case acknowledgement
    }

    private enum Armed: Equatable {
        case script(line: Int, ends: Double)
        case acknowledgement(ends: Double)
    }

    /// Test-clock estimate only, so `advance` can finish the acknowledgement. Not a playback
    /// schedule: the adapter plays whatever on-device `VoiceRenderer` produced.
    private static let acknowledgementSeconds = 2.0

    private var interruption = BreakInterruptionState()
    private var durations: [Double] = []
    private var armed: Armed?
    public private(set) var events: [Event] = []

    public init() {}

    public var phase: BreakInterruptionState.Phase { interruption.phase }
    public var isHolding: Bool { interruption.isHolding }
    /// A line or the acknowledgement is due. False while paused or held: nothing is scheduled.
    public var timerArmed: Bool { armed != nil }

    /// Line `0` starts at `t`. `lineSeconds` is one duration per script line, in order.
    public mutating func start(lineSeconds: [Double], kind: BreakInterruptionKind = .boundary, at t: Double) {
        durations = lineSeconds
        events = []
        armed = nil
        interruption.breakStarted(kind)
        if !lineSeconds.isEmpty {
            beginScriptLine(0, at: t)
        }
    }

    /// Move the clock to `t`. A due script line starts the next one only while the break is
    /// speaking. A paused or held clock starts nothing, even if `t` is past the old line end.
    public mutating func advance(to t: Double) {
        var steps = 0
        while steps < 64 {
            steps += 1
            switch armed {
            case .script(let line, let ends) where t >= ends:
                armed = nil
                let next = line + 1
                guard next < durations.count, Self.acceptsNextScriptLine(interruption.phase) else { return }
                beginScriptLine(next, at: ends)
            case .acknowledgement(let ends) where t >= ends:
                armed = nil
                if case .resume(let line) = interruption.acknowledgementEnded() {
                    beginScriptLine(line, at: ends)
                }
            default:
                return
            }
        }
    }

    @discardableResult
    public mutating func began(at t: Double) -> BreakInterruptionState.Action {
        let action = interruption.interruptionBegan(at: t)
        switch action {
        case .pause, .stopTalkover:
            armed = nil
        case .none, .playAcknowledgement, .resume, .stayPaused:
            break
        }
        return action
    }

    @discardableResult
    public mutating func ended(shouldResume: Bool, acknowledgementReady: Bool, at t: Double) -> BreakInterruptionState.Action {
        let action = interruption.interruptionEnded(shouldResume: shouldResume,
                                                    acknowledgementReady: acknowledgementReady, at: t)
        switch action {
        case .playAcknowledgement:
            events.append(.acknowledgement)
            armed = .acknowledgement(ends: t + Self.acknowledgementSeconds)
        case .resume(let line):
            beginScriptLine(line, at: t)
        case .stayPaused:
            armed = nil
        case .none, .pause, .stopTalkover:
            break
        }
        return action
    }

    /// A script line may start only while the break is speaking. Paused, held, acknowledging,
    /// and idle do not start one.
    private static func acceptsNextScriptLine(_ phase: BreakInterruptionState.Phase) -> Bool {
        if case .speaking = phase { return true }
        return false
    }

    private mutating func beginScriptLine(_ index: Int, at t: Double) {
        guard durations.indices.contains(index), Self.acceptsNextScriptLine(interruption.phase) else { return }
        let seconds = durations[index]
        guard seconds > 0 else { return }
        interruption.lineStarted(index)
        events.append(.scriptLine(index))
        armed = .script(line: index, ends: t + seconds)
    }
}
