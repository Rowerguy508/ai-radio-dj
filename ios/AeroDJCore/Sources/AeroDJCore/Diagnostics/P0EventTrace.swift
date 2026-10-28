// TEMPORARY P0 diagnostics: on-screen playback event trace (remove with #121 / #133). -Fry
// Compiled only in Debug (so `swift test` runs its tests) and in AERODJ_P0_DIAG builds.
//
// The last 30 playback events, for a screenshot after song 1 ends on the owner's device.
// Sanitized by construction: a row is t, an event enum, queue index and count, and `k=v`
// pairs whose keys are enums and whose values are booleans, rounded integers or reason-code
// enums. No API here takes a String, so no title, artist, catalog, library or entry ID, route
// or port name can reach a row. Entry identity is compared through a hash and shown as a bool.
#if DEBUG || AERODJ_P0_DIAG
import Foundation

public enum P0TraceEvent: String, Equatable, Sendable, CaseIterable {
    /// A changed player poll (see `P0PollSampler`), with the detector state and the
    /// interpreter's result for it.
    case sample
    /// One of the last 3 polls, kept unconditionally (`P0EventTrace.lastPolls`), so a stuck
    /// state that never changes is still visible.
    case lastPoll
    /// More than 2.5 s passed between two polls: the 1 s timer did not run.
    case pollGap
    /// What `BoundaryInterpreter` told the service to do.
    case boundaryStep
    /// The app's `onBoundary` closure ran.
    case onBoundary
    /// `DJBreakSession.naturalBoundary` returned.
    case naturalBoundary
    /// `startNextTrack(after:)` and its guards.
    case startNextTrack
    /// How one `startTrack(at:)` ended.
    case startTrack
    /// The poll's `RemotePlayGate` paused a playing player.
    case remoteGate
    /// The OS interruption notice as delivered (type, shouldResume, numeric reason).
    case interruption
    /// A session notice as the service handled it, with the SelfStartInterruptionGate decision.
    case sessionNotice
    case scenePhase
    case appLifecycle
}

public enum P0TraceKey: String, Equatable, Sendable, CaseIterable {
    case playing, entry, entryChanged, pos, dur, furthest, wasPlaying, userChangePending, reachedEnd
    case back, end5, durNil, gap
    case notice, deviceRemoved, gate, otherAudio, secondaryHint, intReason, intAge, sincePoll, played
    case result, step, finished, next, after, index
    case takeNext, indexOK, outcome, code, userInitiated
    case mayAutoResume, pausedBySystem, userWantsPlayback
    case began, shouldResume, reason, phase
    case playedThrough, held, intNearEnd, endReported
}

/// Every word a row's value can be. Reason codes only.
public enum P0TraceCode: String, Equatable, Sendable, CaseIterable {
    // interpret result (`none`, the three steps, `noProgressEnd`; `remoteHeld` when the gate
    // returned before interpret) and onBoundary kinds
    case none, naturalEnd, queueFinished, noProgressEnd, remoteHeld
    // boundary step
    case advancedEntry, plannedHandoff, stopped
    // naturalBoundary
    case breakPrepared, noBreak, interludeSpeaking
    // startNextTrack / startTrack
    case called, started, deferredSilently, deferAndReport, refused, superseded, error
    case notQueued, autoplayOff, songUnavailable
    // remote gate
    case pauseBecauseHeld
    // session notices and the self-start gate
    case interruptionBegan, interruptionEnded, routeChanged
    case apply, deferSelfStart, ignorePairedEnd
    // AVAudioSessionInterruptionReasonKey
    case `default`, appWasSuspended, builtInMicMuted, routeDisconnected, unknown
    // lifecycle
    case active, inactive, background
    case willResignActive, didEnterBackground, willEnterForeground, didBecomeActive
}

public enum P0TraceValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case code(P0TraceCode)
    /// Tenths of a second, rendered with one decimal.
    case deci(Int)
    /// The value was not reported (for example no position yet).
    case missing

    /// Seconds, rounded to whole seconds.
    public static func seconds(_ value: TimeInterval?) -> P0TraceValue {
        guard let value, value.isFinite else { return .missing }
        return .int(Int(value.rounded()))
    }

    /// Seconds with one decimal.
    public static func tenths(_ value: TimeInterval?) -> P0TraceValue {
        guard let value, value.isFinite else { return .missing }
        return .deci(Int((value * 10).rounded()))
    }

    var rendered: String {
        switch self {
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return String(i)
        case .deci(let t): return String(format: "%.1f", Double(t) / 10)
        case .code(let c): return c.rawValue
        case .missing: return "-"
        }
    }
}

public struct P0TraceRow: Equatable, Sendable, Identifiable {
    /// Sequence number, increasing across clears.
    public let id: Int
    /// Seconds since app launch, 1 decimal.
    public let t: Double
    public let event: P0TraceEvent
    public let queueIndex: Int?
    public let queueCount: Int?
    /// Only `k=v` pairs of booleans, rounded integers and reason codes, built by the trace.
    public let detail: String

    init(id: Int, t: Double, event: P0TraceEvent, queueIndex: Int?, queueCount: Int?,
         pairs: [(P0TraceKey, P0TraceValue)]) {
        self.id = id
        self.t = (t * 10).rounded() / 10
        self.event = event
        self.queueIndex = queueIndex
        self.queueCount = queueCount
        self.detail = pairs.map { "\($0.0.rawValue)=\($0.1.rendered)" }.joined(separator: " ")
    }

    /// One monospaced line, e.g. `  212.4 sample q=0/5 playing=0 entry=1 pos=0 dur=214 back=1`.
    public var rendered: String {
        let time = String(format: "%7.1f", t)
        let q = "q=\(queueIndex.map(String.init) ?? "-")/\(queueCount.map(String.init) ?? "-")"
        return detail.isEmpty ? "\(time) \(event.rawValue) \(q)" : "\(time) \(event.rawValue) \(q) \(detail)"
    }
}

/// Turns the 1 s poll into change-only samples, so the buffer is not flooded.
public struct P0PollSampler: Sendable {
    /// A sample this close to the duration is always kept.
    public static let nearEndWindow: TimeInterval = 5
    /// A poll later than this after the previous one is reported as `pollGap`.
    public static let gapThreshold: TimeInterval = 2.5

    public struct Change: Equatable, Sendable {
        public var first = false
        public var playingFlipped = false
        public var entryPresenceChanged = false
        public var entryIdentityChanged = false
        public var positionBackwards = false
        public var nearEnd = false
        /// Playing with no duration: logged once per entry.
        public var durationMissing = false
        /// Seconds since the previous poll, when above `gapThreshold`.
        public var gap: TimeInterval?
        /// Seconds since the previous poll, always (nil on the first poll).
        public var sincePrevious: TimeInterval?
        /// Wall time this entry has been playing, summed over poll intervals that started playing
        /// on the same entry. Reset when the entry changes or clears.
        public var playedOnEntry: TimeInterval = 0

        public var isWorthARow: Bool {
            first || playingFlipped || entryPresenceChanged || entryIdentityChanged
                || positionBackwards || nearEnd || durationMissing || gap != nil
        }
    }

    private var lastT: TimeInterval?
    private var lastPlaying = false
    /// Hash of the last entry identity: compared, never shown or stored as the ID.
    private var lastEntryHash: Int?
    private var lastPosition: TimeInterval?
    /// The entry whose missing duration was already logged.
    private var durationMissingLoggedFor: Int??
    private var playedOnEntry: TimeInterval = 0

    public init() {}

    public mutating func consume(_ observation: PlaybackObservation, at t: TimeInterval) -> Change {
        var change = Change()
        let entryHash = observation.entryID.map { $0.hashValue }
        if let lastT {
            change.playingFlipped = observation.isPlaying != lastPlaying
            change.entryPresenceChanged = (entryHash != nil) != (lastEntryHash != nil)
            change.entryIdentityChanged = entryHash != nil && lastEntryHash != nil && entryHash != lastEntryHash
            if let position = observation.position, let previous = lastPosition, !change.entryIdentityChanged {
                change.positionBackwards = position < previous - 0.5
            }
            let elapsed = t - lastT
            change.sincePrevious = elapsed
            if elapsed > Self.gapThreshold { change.gap = elapsed }
            if change.entryIdentityChanged || change.entryPresenceChanged {
                playedOnEntry = 0
            } else if lastPlaying, entryHash != nil {
                playedOnEntry += max(0, elapsed)
            }
        } else {
            change.first = true
        }
        if let position = observation.position, let duration = observation.duration, duration > 0 {
            change.nearEnd = position >= duration - Self.nearEndWindow
        }
        if observation.isPlaying, observation.duration == nil, durationMissingLoggedFor != .some(entryHash) {
            change.durationMissing = true
            durationMissingLoggedFor = .some(entryHash)
        }
        change.playedOnEntry = playedOnEntry
        lastT = t
        lastPlaying = observation.isPlaying
        lastEntryHash = entryHash
        lastPosition = observation.position
        return change
    }
}

/// Ring buffer of the last `capacity` rows, plus the typed entry points that build them.
public struct P0EventTrace: Sendable {
    public static let capacity = 30
    /// Unconditional snapshots of the most recent polls.
    public static let lastPollCount = 3

    public private(set) var rows: [P0TraceRow] = []
    /// The last `lastPollCount` polls, oldest first, recorded even when nothing changed.
    public private(set) var lastPolls: [P0TraceRow] = []
    private var nextPollID = 0
    /// The last interruption that carried a reason, and when.
    private var lastInterruption: (reason: InterruptionReason, t: TimeInterval)?
    private var nextID = 0
    private var sampler = P0PollSampler()

    public init() {}

    public mutating func clear() {
        rows.removeAll()
        lastPolls.removeAll()
    }

    @discardableResult
    public mutating func record(_ event: P0TraceEvent, at t: TimeInterval, queueIndex: Int? = nil,
                                queueCount: Int? = nil, _ pairs: [(P0TraceKey, P0TraceValue)] = []) -> P0TraceRow {
        let row = P0TraceRow(id: nextID, t: t, event: event, queueIndex: queueIndex,
                             queueCount: queueCount, pairs: pairs)
        nextID += 1
        rows.append(row)
        if rows.count > Self.capacity { rows.removeFirst(rows.count - Self.capacity) }
        return row
    }

    // MARK: Entry points

    private struct PendingPoll: Sendable {
        let observation: PlaybackObservation
        let before: P0DetectorState
        let change: P0PollSampler.Change
        let queueIndex: Int
        let queueCount: Int
        let t: TimeInterval
    }
    private var pending: PendingPoll?

    /// Start of one player poll, before `RemotePlayGate` and `interpret`. `before` is the
    /// detector state the sample will be judged against. Records `pollGap` at once.
    @discardableResult
    public mutating func beginPoll(_ observation: PlaybackObservation, before: P0DetectorState,
                                   queueIndex: Int, queueCount: Int, at t: TimeInterval) -> [P0TraceRow] {
        let change = sampler.consume(observation, at: t)
        pending = PendingPoll(observation: observation, before: before, change: change,
                              queueIndex: queueIndex, queueCount: queueCount, t: t)
        guard let gap = change.gap else { return [] }
        return [record(.pollGap, at: t, queueIndex: queueIndex, queueCount: queueCount, [(.gap, .tenths(gap))])]
    }

    /// End of the poll: the interpreter's step and the detector state after it. A `sample` row
    /// is kept when the sample changed or the result is not `none`; a step adds `boundaryStep`.
    @discardableResult
    public mutating func endPoll(_ step: BoundaryStep?, after: P0DetectorState) -> [P0TraceRow] {
        guard let poll = pending else { return [] }
        pending = nil
        let result: P0TraceCode
        var stepPairs: [(P0TraceKey, P0TraceValue)] = []
        switch step {
        case let .advancedEntry(finished, _)?:
            result = .advancedEntry
            stepPairs = [(.finished, .int(finished)), (.next, .int(finished + 1))]
        case let .plannedHandoff(finished, next, _)?:
            result = .plannedHandoff
            stepPairs = [(.finished, .int(finished)), (.next, .int(next))]
        case let .stopped(finished, _)?:
            result = .stopped
            stepPairs = [(.finished, .int(finished)), (.next, .missing)]
        case nil:
            result = after.noProgressEndPending ? .noProgressEnd : .none
        }
        snapshot(poll, furthest: after.furthest, result: result)
        var out: [P0TraceRow] = []
        if poll.change.isWorthARow || result != .none {
            out.append(sampleRow(poll, furthest: after.furthest, result: result))
        }
        if step != nil {
            out.append(record(.boundaryStep, at: poll.t, queueIndex: poll.queueIndex, queueCount: poll.queueCount,
                              [(.step, .code(result))] + stepPairs))
        }
        return out
    }

    /// Convenience for one whole poll (tests and callers without a gate in between).
    @discardableResult
    public mutating func poll(_ observation: PlaybackObservation, before: P0DetectorState,
                              step: BoundaryStep?, after: P0DetectorState,
                              queueIndex: Int, queueCount: Int, at t: TimeInterval) -> [P0TraceRow] {
        beginPoll(observation, before: before, queueIndex: queueIndex, queueCount: queueCount, at: t)
            + endPoll(step, after: after)
    }

    private mutating func sampleRow(_ poll: PendingPoll, furthest: TimeInterval?, result: P0TraceCode) -> P0TraceRow {
        let o = poll.observation
        let c = poll.change
        var pairs: [(P0TraceKey, P0TraceValue)] = [
            (.playing, .bool(o.isPlaying)),
            (.entry, .bool(o.entryID != nil)),
            (.entryChanged, .bool(c.entryIdentityChanged || c.entryPresenceChanged)),
            (.pos, .tenths(o.position)),
            (.dur, .tenths(o.duration)),
            (.furthest, .tenths(furthest)),
            (.wasPlaying, .bool(poll.before.wasPlaying)),
            (.userChangePending, .bool(poll.before.userChangePending)),
            (.reachedEnd, .bool(P0DetectorState.reachedEnd(o, furthest: furthest))),
            (.result, .code(result)),
        ]
        if c.positionBackwards { pairs.append((.back, .bool(true))) }
        if c.nearEnd { pairs.append((.end5, .bool(true))) }
        if c.durationMissing { pairs.append((.durNil, .bool(true))) }
        return record(.sample, at: poll.t, queueIndex: poll.queueIndex, queueCount: poll.queueCount, pairs)
    }

    private mutating func snapshot(_ poll: PendingPoll, furthest: TimeInterval?, result: P0TraceCode) {
        let o = poll.observation
        let pairs: [(P0TraceKey, P0TraceValue)] = [
            (.wasPlaying, .bool(poll.before.wasPlaying)),
            (.playing, .bool(o.isPlaying)),
            (.pos, .tenths(o.position)),
            (.dur, .tenths(o.duration)),
            (.furthest, .tenths(furthest)),
            (.reachedEnd, .bool(P0DetectorState.reachedEnd(o, furthest: furthest))),
            (.userChangePending, .bool(poll.before.userChangePending)),
            (.playedThrough, .bool(poll.before.playedThrough)),
            (.held, .bool(poll.before.held)),
            (.intNearEnd, .bool(poll.before.intNearEnd)),
            (.endReported, .bool(poll.before.endReported)),
            (.result, .code(result)),
            (.intReason, lastInterruption.map { .code($0.reason.code) } ?? .missing),
            (.intAge, lastInterruption.map { .seconds(poll.t - $0.t) } ?? .missing),
            (.sincePoll, .tenths(poll.change.sincePrevious)),
            (.played, .seconds(poll.change.playedOnEntry)),
        ]
        lastPolls.append(P0TraceRow(id: nextPollID, t: poll.t, event: .lastPoll, queueIndex: poll.queueIndex,
                                    queueCount: poll.queueCount, pairs: pairs))
        nextPollID += 1
        if lastPolls.count > Self.lastPollCount { lastPolls.removeFirst(lastPolls.count - Self.lastPollCount) }
    }

    /// A session notice as `MusicKitService.applySession` received it, and the gate's decision.
    @discardableResult
    public mutating func sessionNotice(_ notice: AudioSessionNotice, gate: SelfStartInterruptionGate.Decision,
                                       audio: SessionAudio, at t: TimeInterval) -> P0TraceRow {
        var pairs: [(P0TraceKey, P0TraceValue)]
        switch notice {
        case .interruptionBegan:
            pairs = [(.notice, .code(.interruptionBegan))]
        case let .interruptionEnded(shouldResume):
            pairs = [(.notice, .code(.interruptionEnded)), (.shouldResume, .bool(shouldResume))]
        case let .routeChanged(reason):
            pairs = [(.notice, .code(.routeChanged)), (.deviceRemoved, .bool(reason == .oldDeviceUnavailable))]
        }
        let decision: P0TraceCode
        switch gate {
        case .apply: decision = .apply
        case .deferSelfStart: decision = .deferSelfStart
        case .ignorePairedEnd: decision = .ignorePairedEnd
        }
        pairs.append((.gate, .code(decision)))
        return record(.sessionNotice, at: t, pairs + audio.pairs)
    }

    @discardableResult
    public mutating func onBoundary(_ boundary: PlaybackBoundary, finishedIndex: Int, at t: TimeInterval) -> P0TraceRow {
        let kind: P0TraceCode
        switch boundary {
        case .naturalEnd: kind = .naturalEnd
        case .queueFinished: kind = .queueFinished
        }
        return record(.onBoundary, at: t, [(.result, .code(kind)), (.finished, .int(finishedIndex))])
    }

    public enum BreakResult: Sendable { case breakPrepared, noBreak, interludeSpeaking }

    @discardableResult
    public mutating func naturalBoundary(_ result: BreakResult, afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        let code: P0TraceCode
        switch result {
        case .breakPrepared: code = .breakPrepared
        case .noBreak: code = .noBreak
        case .interludeSpeaking: code = .interludeSpeaking
        }
        return record(.naturalBoundary, at: t, [(.result, .code(code)), (.after, .int(afterTrack))])
    }

    /// The service's hold state, read where a start is decided.
    public struct Gates: Equatable, Sendable {
        public let mayAutoResume: Bool
        public let pausedBySystem: Bool
        public let userWantsPlayback: Bool
        public init(mayAutoResume: Bool, pausedBySystem: Bool, userWantsPlayback: Bool) {
            self.mayAutoResume = mayAutoResume
            self.pausedBySystem = pausedBySystem
            self.userWantsPlayback = userWantsPlayback
        }
        var pairs: [(P0TraceKey, P0TraceValue)] {
            [(.mayAutoResume, .bool(mayAutoResume)), (.pausedBySystem, .bool(pausedBySystem)),
             (.userWantsPlayback, .bool(userWantsPlayback))]
        }
    }

    public enum NextStage: Sendable {
        case called
        case takeNext(Bool)
        case indexOK(Bool)
    }

    @discardableResult
    public mutating func startNextTrack(_ stage: NextStage, after index: Int, queueCount: Int,
                                        gates: Gates, at t: TimeInterval) -> P0TraceRow {
        var pairs: [(P0TraceKey, P0TraceValue)] = [(.after, .int(index))]
        switch stage {
        case .called: pairs.append((.outcome, .code(.called)))
        case .takeNext(let ok): pairs.append((.takeNext, .bool(ok)))
        case .indexOK(let ok): pairs.append((.indexOK, .bool(ok)))
        }
        return record(.startNextTrack, at: t, queueIndex: index, queueCount: queueCount, pairs + gates.pairs)
    }

    public enum StartOutcome: Equatable, Sendable {
        case started, deferredSilently, deferAndReport, refused, superseded
        case notQueued, autoplayOff, songUnavailable
        /// Only the numeric code is kept; type name and domain are dropped.
        case error(PlaybackErrorCode)
    }

    @discardableResult
    public mutating func startTrack(_ outcome: StartOutcome, index: Int, queueCount: Int, userInitiated: Bool,
                                    gates: Gates, at t: TimeInterval) -> P0TraceRow {
        let code: P0TraceCode
        var extra: [(P0TraceKey, P0TraceValue)] = []
        switch outcome {
        case .started: code = .started
        case .deferredSilently: code = .deferredSilently
        case .deferAndReport: code = .deferAndReport
        case .refused: code = .refused
        case .superseded: code = .superseded
        case .notQueued: code = .notQueued
        case .autoplayOff: code = .autoplayOff
        case .songUnavailable: code = .songUnavailable
        case .error(let e):
            code = .error
            extra = [(.code, .int(e.code))]
        }
        return record(.startTrack, at: t, queueIndex: index, queueCount: queueCount,
                      [(.index, .int(index)), (.outcome, .code(code))] + extra
                      + [(.userInitiated, .bool(userInitiated))] + gates.pairs)
    }

    @discardableResult
    public mutating func remoteGatePause(queueIndex: Int, queueCount: Int, gates: Gates, at t: TimeInterval) -> P0TraceRow {
        // The poll returns before interpret: keep its sample, marked `remoteHeld`.
        if let poll = pending {
            pending = nil
            snapshot(poll, furthest: poll.before.furthest, result: .remoteHeld)
            sampleRow(poll, furthest: poll.before.furthest, result: .remoteHeld)
        }
        return record(.remoteGate, at: t, queueIndex: queueIndex, queueCount: queueCount,
               [(.result, .code(.pauseBecauseHeld))] + gates.pairs)
    }

    /// `AVAudioSessionInterruptionReasonKey`, as an enum. Anything else is `unknown`.
    public enum InterruptionReason: Sendable {
        case `default`, appWasSuspended, builtInMicMuted, routeDisconnected, unknown
        var code: P0TraceCode {
            switch self {
            case .default: return .default
            case .appWasSuspended: return .appWasSuspended
            case .builtInMicMuted: return .builtInMicMuted
            case .routeDisconnected: return .routeDisconnected
            case .unknown: return .unknown
            }
        }
    }

    /// The other-audio state read when a notice arrives.
    public struct SessionAudio: Equatable, Sendable {
        public let otherAudio: Bool
        public let secondaryHint: Bool
        public init(otherAudio: Bool, secondaryHint: Bool) {
            self.otherAudio = otherAudio
            self.secondaryHint = secondaryHint
        }
        var pairs: [(P0TraceKey, P0TraceValue)] {
            [(.otherAudio, .bool(otherAudio)), (.secondaryHint, .bool(secondaryHint))]
        }
    }

    /// The OS interruption notice: began or ended, shouldResume (ended only), the reason
    /// (began; nil when the key is absent) and the other-audio state. Never a route or port.
    @discardableResult
    public mutating func interruption(began: Bool, shouldResume: Bool?, reason: InterruptionReason?,
                                      audio: SessionAudio, at t: TimeInterval) -> P0TraceRow {
        if let reason { lastInterruption = (reason, t) }
        var pairs: [(P0TraceKey, P0TraceValue)] = [(.began, .bool(began))]
        pairs.append((.shouldResume, shouldResume.map(P0TraceValue.bool) ?? .missing))
        pairs.append((.reason, reason.map { .code($0.code) } ?? .missing))
        return record(.interruption, at: t, pairs + audio.pairs)
    }

    public enum Phase: Sendable { case active, inactive, background }

    @discardableResult
    public mutating func scenePhase(_ phase: Phase, at t: TimeInterval) -> P0TraceRow {
        let code: P0TraceCode
        switch phase {
        case .active: code = .active
        case .inactive: code = .inactive
        case .background: code = .background
        }
        return record(.scenePhase, at: t, [(.phase, .code(code))])
    }

    public enum Lifecycle: Sendable { case willResignActive, didEnterBackground, willEnterForeground, didBecomeActive }

    @discardableResult
    public mutating func appLifecycle(_ notice: Lifecycle, at t: TimeInterval) -> P0TraceRow {
        let code: P0TraceCode
        switch notice {
        case .willResignActive: code = .willResignActive
        case .didEnterBackground: code = .didEnterBackground
        case .willEnterForeground: code = .willEnterForeground
        case .didBecomeActive: code = .didBecomeActive
        }
        return record(.appLifecycle, at: t, [(.phase, .code(code))])
    }
}
#endif
