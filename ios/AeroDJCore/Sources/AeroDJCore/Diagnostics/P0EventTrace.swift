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
    /// DJ talk-over (flagged): a plan, a timing miss, a cancel or a measured start latency.
    case talkover
    /// A break paused by a system interruption dropped lines (#379 N2): lines skipped on
    /// resume (`resumeDrop`) or the rest of the break (`breakDropped`), counted by kind.
    case breakInterruption
    /// #525 (-Atlas): the long-form route probe (port types only) and the session each break used.
    case sessionRoute
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
    case plan
    // talk-over
    case kind, mode, intro, outro, voice, play, unduck, lat, ms, measured
    // talk-over duck probe (before activation: otherAudio, secondaryHint; after: these two)
    case otherAfter, hintAfter, activated
    // session-order fix (-Fry): app-tracked active, quiet pre-deactivation error code, category
    // options read back, duckOthers set, output volume percent, unduck error code
    case activeBefore, preOff, opts, duckSet, outVol, err
    // Echo's #374 follow-up (-Fry): MusicKit `playbackStatus == .playing` before and right after
    // the duck activation, and in the settle, duck-to-voice (end of the lead) and unduck rows
    case musicBefore, musicAfter, music
    // #379 N2 (-Fry): the paused line, lines dropped, of which time checks and other lines
    case line, dropped, timeChecks, otherCues
    // #388 (-Nova): briefing items counted apart from other lines
    case briefingCues
    // Echo's #396 room N1: cues a narrowed break kept
    case kept
    // #525 (-Atlas): long-form route kind, first two output port types and the output count,
    // the remote flag, whether talk-over is allowed, whether that changed, the break's session
    case route, port1, port2, ports, flag, allowed, changed, shape
    // Echo's #527 ask: the app session's own currentRoute port types, read as-is (types only)
    case cur1, cur2, curN
    // Fry's #527 B1: where `.normal` was (re)applied and which attempt
    case site, attempt
    // #526 S0b (-Echo): AirPlay gap-break handoff timestamps (ms on the record clock) and
    // the route's outputLatency in milliseconds. Codes and milliseconds only.
    case songEnd, firstPlay, lastFinish, sessionOff, nextPlay, musicPlaying, latency, missing
}

extension P0TraceCode {
    init(skip: DJBreakSkipReason) { self = P0TraceCode(rawValue: skip.rawValue) ?? .unknown }
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
    // DJBreakSkipReason, same raw values (a noBreak row's reason)
    case renderFailed, overDuration, costCap, timedOut, notReadyAtBoundary, overBreakBudget
    case notPlanned, notNaturalBoundary, cancelled, sourceRevoked, interrupted, paidVoiceRevoked, stationIntro
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
    // talk-over (row kind, mode, hard-break and intro-skip reasons, misses, cancels)
    case decision, miss, cancel, latency, duckProbe, hardBreak, used
    case duckSettled, duckVoice, unduckProbe, duckReleased
    case outroAndIntro, outroOnly
    case flagOff, durationUnknown, trackTooShort, voiceTooLong, voiceInvalid, tooLateToArm, outroTooShort, endedBeforeVoice
    case noClosingLine, closingTooLong, nextTrackTooShort, nextTrackUnknown, introTooShort
    case voiceStartLate, nextStartLate, nextStartEarly, endAfterPlayCue, voiceEndedFirst
    case seekOutOfWindow, seekWhileSpeaking, skip, userStop, interruption, routeRemoved, revoked, voiceFailed
    // break interruption drops (#379 N2): row kind, then `BreakResumeDrop.Reason` (same raw values)
    case resumeDrop, breakDropped
    case stale, allStale, noResume, musicPlaying, pauseExpired
    /// #387 N1: a rating withdrew the paused break (`StationRatingResumeGate`).
    case ratingWithdrawn
    /// #388: a never faded the talk-over line that named the song and dropped the rest of its break.
    case ratedNever
    /// Echo's #396 room N1: a break lost only the cues that name a song the station now leaves out.
    case cuesDropped, ratingNarrowed
    /// #525 (-Atlas): row kinds, then the route kinds, port types and session shapes (same raw
    /// values as `LongFormRouteKind`, `LongFormPortType` and `DJSessionShape`), and the
    /// talk-over hard-break reason `airPlayRoute`.
    case probe, probeSkipped, breakShape
    case airPlay, bluetooth, carPlay, wired, builtIn, other
    case bluetoothA2DP, bluetoothLE, bluetoothHFP, carAudio, builtInSpeaker, builtInReceiver, headphones, usbAudio, hdmi, lineOut
    case mixDefault, duckDefault, longFormAirPlay
    case airPlayRoute
    /// #525 route-change rows: the kind, then `DJRouteChangeReason` (same raw values).
    case routeChange
    /// Fry's launch-probe row, Echo's re-check row and its kept-talk-over result.
    case launchProbe, recheck, talkover
    /// Fry's #527 B1 restore rows: the kind, the hard-break reason, `RestoreSite` values (`probe`
    /// is shared) and the results.
    case restore, restoreFailed
    case endGapBreak, beforeClip, beforePlay
    case failed, recovered, latched, cleared
    /// #526 S0b (-Echo): the handoff row kind, its steps, and how the break ended.
    case handoff, songEnd, firstPlay, lastFinish, sessionOff, nextPlay, complete, skipped, incomplete
    case newDeviceAvailable, oldDeviceUnavailable, categoryChange, override, wakeFromSleep
    case noSuitableRouteForCategory, routeConfigurationChange, otherReason
}

public enum P0TraceValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case code(P0TraceCode)
    /// Tenths of a second, rendered with one decimal.
    case deci(Int)
    /// The value was not reported (for example no position yet).
    case missing
    /// Several reason codes, rendered as `a+b` or `-` when empty (S0b missing steps).
    case joinedCodes([P0TraceCode])

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
        case .joinedCodes(let codes):
            return codes.isEmpty ? "-" : codes.map(\.rawValue).joined(separator: "+")
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
    /// #526 S0b: in-flight AirPlay gap-break handoff, if any.
    private var airPlayHandoff = AirPlayGapHandoffTrace()

    public init() {}

    public mutating func clear() {
        rows.removeAll()
        lastPolls.removeAll()
        airPlayHandoff = AirPlayGapHandoffTrace()
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
        if observation.isPlaying {
            _ = airPlayGapHandoffMark(.musicPlaying, at: t)
        }
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
        // #526 S0b: start one handoff on the AirPlay gap route only. Headphones are untouched.
        // `!talkoverAllowed` is the same rule the #527/#553 path uses.
        if !DJLongFormRouteState.shared.talkoverAllowed {
            _ = airPlayGapHandoffBegin(afterTrack: finishedIndex, at: t)
        }
        return record(.onBoundary, at: t, [(.result, .code(kind)), (.finished, .int(finishedIndex))])
    }

    public enum BreakResult: Sendable {
        case breakPrepared, interludeSpeaking
        /// `reason` nil: the session reported none. `cadencePlanned`: the cadence had a break here.
        case noBreak(DJBreakSkipReason?, cadencePlanned: Bool)
    }

    @discardableResult
    public mutating func naturalBoundary(_ result: BreakResult, afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        switch result {
        case .breakPrepared:
            return record(.naturalBoundary, at: t, [(.result, .code(.breakPrepared)), (.after, .int(afterTrack))])
        case .interludeSpeaking:
            airPlayGapHandoffNote(.skipped)
            return record(.naturalBoundary, at: t, [(.result, .code(.interludeSpeaking)), (.after, .int(afterTrack))])
        case let .noBreak(reason, planned):
            airPlayGapHandoffNote(.skipped)
            let why: P0TraceValue = reason.map { .code(P0TraceCode(skip: $0)) } ?? .missing
            return record(.naturalBoundary, at: t, [(.result, .code(.noBreak)), (.reason, why),
                                                     (.plan, .bool(planned)), (.after, .int(afterTrack))])
        }
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
        case .takeNext(let ok):
            pairs.append((.takeNext, .bool(ok)))
            if !ok { _ = airPlayGapHandoffFinalize(at: t) }
        case .indexOK(let ok):
            pairs.append((.indexOK, .bool(ok)))
            if !ok { _ = airPlayGapHandoffFinalize(at: t) }
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
        if outcome == .started {
            _ = airPlayGapHandoffMark(.nextPlay, at: t)
        } else {
            _ = airPlayGapHandoffFinalize(at: t)
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

// MARK: DJ talk-over (-Fry)

extension P0EventTrace {
    private static func code(_ raw: String) -> P0TraceValue { .code(P0TraceCode(rawValue: raw) ?? .unknown) }
    private static func ms(_ seconds: Double?) -> P0TraceValue {
        guard let seconds, seconds.isFinite else { return .missing }
        return .int(Int((seconds * 1000).rounded()))
    }

    /// The planner's decision for the break after `afterTrack`. Codes and seconds only.
    @discardableResult
    public mutating func talkoverDecision(_ d: TalkoverDecision, afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        var pairs: [(P0TraceKey, P0TraceValue)] = [(.kind, .code(.decision)), (.after, .int(afterTrack))]
        switch d {
        case .hardBreak(let r):
            pairs += [(.mode, .code(.hardBreak)), (.reason, Self.code(r.rawValue))]
        case .talkover(let p):
            pairs += [(.mode, Self.code(p.mode.rawValue)), (.intro, Self.code(p.introSkip?.rawValue ?? "used")),
                      (.outro, .tenths(p.outroOverlap)), (.voice, .tenths(p.voiceSeconds)),
                      (.play, .tenths(p.nextPlayAfterVoice)), (.unduck, .tenths(p.unduckAfterVoice)),
                      (.lat, Self.ms(p.startLatency))]
        }
        return record(.talkover, at: t, pairs)
    }

    @discardableResult
    public mutating func talkoverMiss(_ m: TalkoverMiss, afterTrack: Int, seconds: Double?, at t: TimeInterval) -> P0TraceRow {
        record(.talkover, at: t, [(.kind, .code(.miss)), (.after, .int(afterTrack)),
                                  (.code, Self.code(m.rawValue)), (.ms, Self.ms(seconds))])
    }

    @discardableResult
    public mutating func talkoverCancel(_ c: TalkoverCancel, afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        record(.talkover, at: t, [(.kind, .code(.cancel)), (.after, .int(afterTrack)), (.reason, Self.code(c.rawValue))])
    }

    @discardableResult
    public mutating func talkoverLatency(measured: Double, next: Double, afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        record(.talkover, at: t, [(.kind, .code(.latency)), (.after, .int(afterTrack)),
                                  (.measured, Self.ms(measured)), (.lat, Self.ms(next))])
    }

    /// What the session reported around the talk-over duck activation (`TalkoverAudioSession.duck`).
    /// `otherAudio=true` while only our own music plays means the system counts
    /// `ApplicationMusicPlayer` as another session, the precondition for `.duckOthers` to reach it.
    /// It cannot show the ducked level: the owner's ears are the proof.
    @discardableResult
    public mutating func talkoverDuckProbe(_ p: TalkoverDuckProbe, afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        record(.talkover, at: t, [(.kind, .code(.duckProbe)), (.after, .int(afterTrack)),
                                  (.otherAudio, .bool(p.otherBefore)), (.secondaryHint, .bool(p.hintBefore)),
                                  (.activated, .bool(p.activated)),
                                  (.otherAfter, .bool(p.otherAfter)), (.hintAfter, .bool(p.hintAfter)),
                                  (.activeBefore, Self.flag(p.activeBefore)), (.preOff, Self.number(p.preDeactivateCode)),
                                  (.opts, Self.number(p.optionsRaw)), (.duckSet, Self.flag(p.duckOthersSet)),
                                  (.outVol, Self.number(p.outputVolumePercent)),
                                  (.musicBefore, Self.flag(p.musicBefore)), (.musicAfter, Self.flag(p.musicAfter))])
    }

    /// The session 0.5 s after the duck activation (`kind=duckSettled`), and right after the
    /// unduck (`kind=unduckProbe`, with the deactivation's error code, 0 when it succeeded) or
    /// the release of a duck whose voice never spoke (`kind=duckReleased`).
    public struct TalkoverSessionSample: Equatable, Sendable {
        public var otherAudio: Bool
        public var secondaryHint: Bool
        public var outputVolumePercent: Int?
        /// Echo's #374 follow-up: MusicKit `playbackStatus == .playing` at this sample (nil: not read).
        public var musicPlaying: Bool?
        public init(otherAudio: Bool, secondaryHint: Bool, outputVolumePercent: Int?, musicPlaying: Bool? = nil) {
            self.otherAudio = otherAudio
            self.secondaryHint = secondaryHint
            self.outputVolumePercent = outputVolumePercent
            self.musicPlaying = musicPlaying
        }
    }

    @discardableResult
    public mutating func talkoverDuckSettled(_ s: TalkoverSessionSample, afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        record(.talkover, at: t, [(.kind, .code(.duckSettled)), (.after, .int(afterTrack))] + Self.pairs(s))
    }

    /// Milliseconds from the duck activation to the voice's real start, and (Echo's #374
    /// follow-up) whether MusicKit was still playing then, at the end of the duck lead.
    @discardableResult
    public mutating func talkoverDuckToVoice(ms: Int?, musicPlaying: Bool? = nil, afterTrack: Int,
                                             at t: TimeInterval) -> P0TraceRow {
        record(.talkover, at: t, [(.kind, .code(.duckVoice)), (.after, .int(afterTrack)), (.ms, Self.number(ms)),
                                  (.music, Self.flag(musicPlaying))])
    }

    @discardableResult
    public mutating func talkoverUnduck(errorCode: Int, released: Bool, _ s: TalkoverSessionSample,
                                        afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        record(.talkover, at: t, [(.kind, .code(released ? .duckReleased : .unduckProbe)), (.after, .int(afterTrack)),
                                  (.err, .int(errorCode))] + Self.pairs(s))
    }

    private static func pairs(_ s: TalkoverSessionSample) -> [(P0TraceKey, P0TraceValue)] {
        [(.otherAudio, .bool(s.otherAudio)), (.secondaryHint, .bool(s.secondaryHint)), (.outVol, number(s.outputVolumePercent)),
         (.music, flag(s.musicPlaying))]
    }
    /// #379 N2 (-Fry): lines a paused break dropped, by kind, and why. Counts and codes only.
    @discardableResult
    public mutating func breakInterruptionDrop(_ drop: BreakResumeDrop, afterTrack: Int?,
                                               at t: TimeInterval) -> P0TraceRow {
        record(.breakInterruption, at: t, [(.kind, .code(drop.breakDropped ? .breakDropped : .resumeDrop)),
                                           (.reason, .code(P0TraceCode(rawValue: drop.reason.rawValue) ?? .unknown)),
                                           (.after, Self.number(afterTrack)), (.line, .int(drop.line)),
                                           (.dropped, .int(drop.count)), (.timeChecks, .int(drop.timeChecks)),
                                           (.otherCues, .int(drop.other))])
    }
    /// #387 N1 (-Nova): lines a break withdrawn by a rating (`StationRatingResumeGate`) did not
    /// air, by kind, in the same row shape. Counts and codes only; nothing about the rating.
    @discardableResult
    public mutating func breakInterruptionWithdrawn(_ withdrawn: StationRatingWithdrawnLines, afterTrack: Int?,
                                                    at t: TimeInterval) -> P0TraceRow {
        record(.breakInterruption, at: t, [(.kind, .code(.breakDropped)), (.reason, .code(.ratingWithdrawn)),
                                           (.after, Self.number(afterTrack)), (.line, .int(withdrawn.line)),
                                           (.dropped, .int(withdrawn.count)), (.timeChecks, .int(withdrawn.timeChecks)),
                                           (.otherCues, .int(withdrawn.other)), (.briefingCues, .int(withdrawn.briefing))])
    }
    /// #388 (-Nova): a never faded the talk-over line that named the song (`StationRatingTalkoverCut`)
    /// and dropped the rest of its break. Same row shape; `line` is the faded line. Counts and codes
    /// only: never the song, its title or artist, or the rating.
    @discardableResult
    public mutating func talkoverRatedNever(_ dropped: StationRatingWithdrawnLines, afterTrack: Int?,
                                            at t: TimeInterval) -> P0TraceRow {
        record(.breakInterruption, at: t, [(.kind, .code(.breakDropped)), (.reason, .code(.ratedNever)),
                                           (.after, Self.number(afterTrack)), (.line, .int(dropped.line)),
                                           (.dropped, .int(dropped.count)), (.timeChecks, .int(dropped.timeChecks)),
                                           (.otherCues, .int(dropped.other)), (.briefingCues, .int(dropped.briefing))])
    }
    /// Echo's #396 room N1 (#388, -Nova): a break was narrowed to the cues that do not name a song the
    /// station now leaves out (`DJBreakSession.naturalBoundary`, or a held talk-over break). Same
    /// counts as `breakInterruptionWithdrawn`, plus how many cues were kept. Counts and codes only:
    /// never a song, its title or artist, a name, or the rating.
    @discardableResult
    public mutating func breakNarrowed(_ counts: ExcludedCueCounts, afterTrack: Int?, at t: TimeInterval) -> P0TraceRow {
        record(.breakInterruption, at: t, [(.kind, .code(.cuesDropped)), (.reason, .code(.ratingNarrowed)),
                                           (.after, Self.number(afterTrack)), (.dropped, .int(counts.dropped)),
                                           (.timeChecks, .int(counts.timeChecks)), (.otherCues, .int(counts.other)),
                                           (.briefingCues, .int(counts.briefing)), (.kept, .int(counts.kept))])
    }

    /// Echo's N2 on #398 (-Nova): a break dropped because cloud-voice consent was withdrawn
    /// (`DJBreakPreparer.observeCloudVoiceDrops`), its cues by kind. Same row shape as
    /// `breakNarrowed`; `kept` is 0 (the whole break goes). Counts and codes only: never a line,
    /// a voice, a provider or a song.
    @discardableResult
    public mutating func cloudVoiceDropped(_ counts: ExcludedCueCounts, afterTrack: Int?, at t: TimeInterval) -> P0TraceRow {
        record(.breakInterruption, at: t, [(.kind, .code(.breakDropped)), (.reason, .code(.paidVoiceRevoked)),
                                           (.after, Self.number(afterTrack)), (.dropped, .int(counts.dropped)),
                                           (.timeChecks, .int(counts.timeChecks)), (.otherCues, .int(counts.other)),
                                           (.briefingCues, .int(counts.briefing)), (.kept, .int(counts.kept))])
    }

    private static func flag(_ b: Bool?) -> P0TraceValue { b.map { .bool($0) } ?? .missing }
    private static func number(_ i: Int?) -> P0TraceValue { i.map { .int($0) } ?? .missing }
}

// MARK: #525 session route (-Atlas)

extension P0EventTrace {
    /// One long-form probe (`site`: the launch probe or a gap break): the route kind, the first two
    /// long-form output port TYPES (never a name, UID or device name) and their count, the app
    /// session's own `currentRoute` port types read before the probe (`cur1`, `cur2`, `curN`), the
    /// remote flag, whether talk-over is allowed after it, and whether that permission changed.
    @discardableResult
    public mutating func sessionRouteProbe(site: DJRouteSessionCore.ProbeSite = .gapBreak, route: LongFormRouteKind,
                                           ports: [LongFormPortType], sessionPorts: [LongFormPortType] = [],
                                           flag: Bool, talkoverAllowed: Bool, changed: Bool,
                                           at t: TimeInterval) -> P0TraceRow {
        record(.sessionRoute, at: t, [(.kind, .code(site == .launch ? .launchProbe : .probe)),
                                      (.route, .code(P0TraceCode(rawValue: route.rawValue) ?? .unknown))]
               + Self.portPairs(ports, first: .port1, second: .port2, count: .ports)
               + Self.portPairs(sessionPorts, first: .cur1, second: .cur2, count: .curN)
               + [(.flag, .bool(flag)), (.allowed, .bool(talkoverAllowed)), (.changed, .bool(changed))])
    }

    /// Port types only: the first two and the count. A missing port is `-`.
    static func portPairs(_ ports: [LongFormPortType], first: P0TraceKey, second: P0TraceKey,
                          count: P0TraceKey) -> [(P0TraceKey, P0TraceValue)] {
        func code(_ p: LongFormPortType?) -> P0TraceValue {
            guard let p else { return .missing }
            return .code(P0TraceCode(rawValue: p.rawValue) ?? .unknown)
        }
        return [(first, code(ports.first)), (second, code(ports.dropFirst().first)), (count, .int(ports.count))]
    }

    /// Echo's #527 ask: the pre-duck re-check, with what it read and no session call. `result` is
    /// `talkover` (kept), `airPlayRoute` or `routeChanged`; `route` is the last probe's route;
    /// `cur1`/`cur2`/`curN` the app session's own `currentRoute` port types; `changed` whether a route
    /// change was marked before this boundary.
    @discardableResult
    public mutating func sessionTalkoverRecheck(_ decision: TalkoverDecision, lastProbedRoute: LongFormRouteKind,
                                                sessionPorts: [LongFormPortType], marked: Bool, flag: Bool,
                                                afterTrack: Int, at t: TimeInterval) -> P0TraceRow {
        let result: P0TraceCode
        switch decision {
        case .talkover: result = .talkover
        case .hardBreak(let r): result = P0TraceCode(rawValue: r.rawValue) ?? .unknown
        }
        return record(.sessionRoute, at: t, [(.kind, .code(.recheck)), (.after, .int(afterTrack)), (.result, .code(result)),
                                             (.route, .code(P0TraceCode(rawValue: lastProbedRoute.rawValue) ?? .unknown))]
                      + Self.portPairs(sessionPorts, first: .cur1, second: .cur2, count: .curN)
                      + [(.changed, .bool(marked)), (.flag, .bool(flag))])
    }

    /// The probe did not run (the app's session was active): the last route stays in effect.
    @discardableResult
    public mutating func sessionRouteProbeSkipped(flag: Bool, at t: TimeInterval) -> P0TraceRow {
        record(.sessionRoute, at: t, [(.kind, .code(.probeSkipped)), (.flag, .bool(flag))])
    }

    /// `routeChangeNotification` as the AirPlay path saw it: the reason code, and whether it
    /// marked the next talk-over for the re-check (false: killed, or our own category change).
    @discardableResult
    public mutating func sessionRouteChange(_ reason: DJRouteChangeReason, marked: Bool, flag: Bool,
                                            at t: TimeInterval) -> P0TraceRow {
        record(.sessionRoute, at: t, [(.kind, .code(.routeChange)),
                                      (.reason, .code(P0TraceCode(rawValue: reason.rawValue) ?? .unknown)),
                                      (.changed, .bool(marked)), (.flag, .bool(flag))])
    }

    /// Fry's #527 B1: one step of the `.normal` restore: `result=failed attempt=1|2`,
    /// `result=recovered attempt=2`, `result=latched` (restore pending) or `result=cleared`.
    @discardableResult
    public mutating func sessionRestore(_ event: DJRouteSessionCore.RestoreEvent, at t: TimeInterval) -> P0TraceRow {
        func site(_ s: DJRouteSessionCore.RestoreSite) -> P0TraceValue { .code(P0TraceCode(rawValue: s.rawValue) ?? .unknown) }
        let pairs: [(P0TraceKey, P0TraceValue)]
        switch event {
        case let .failed(s, n): pairs = [(.site, site(s)), (.result, .code(.failed)), (.attempt, .int(n))]
        case let .recovered(s, n): pairs = [(.site, site(s)), (.result, .code(.recovered)), (.attempt, .int(n))]
        case let .latched(s): pairs = [(.site, site(s)), (.result, .code(.latched))]
        case let .cleared(s): pairs = [(.site, site(s)), (.result, .code(.cleared))]
        }
        return record(.sessionRoute, at: t, [(.kind, .code(.restore))] + pairs)
    }

    /// The session a gap break ran with and the route it was chosen for, with the app session's own
    /// `currentRoute` port types read before any probe (`cur*`) and the probe's long-form port types
    /// (`port*`; `-` and `ports=0` when no probe ran: killed, or the session was active).
    @discardableResult
    public mutating func sessionBreakShape(_ shape: DJSessionShape, route: LongFormRouteKind, afterTrack: Int,
                                           sessionPorts: [LongFormPortType] = [], probePorts: [LongFormPortType] = [],
                                           at t: TimeInterval) -> P0TraceRow {
        record(.sessionRoute, at: t, [(.kind, .code(.breakShape)), (.after, .int(afterTrack)),
                                      (.shape, .code(P0TraceCode(rawValue: shape.rawValue) ?? .unknown)),
                                      (.route, .code(P0TraceCode(rawValue: route.rawValue) ?? .unknown))]
               + Self.portPairs(sessionPorts, first: .cur1, second: .cur2, count: .curN)
               + Self.portPairs(probePorts, first: .port1, second: .port2, count: .ports))
    }
}

// MARK: #526 S0b AirPlay gap-break handoff (-Echo)

extension P0EventTrace {
    /// One hook for the S0b handoff row. `t` is the same monotonic clock `record(_:at:)`
    /// already uses. Marks a step; emits one row when MusicKit `.playing` arrives.
    @discardableResult
    public mutating func airPlayGapHandoffMark(_ step: AirPlayGapHandoffTrace.Step,
                                               outputLatency: TimeInterval? = nil,
                                               at t: TimeInterval) -> P0TraceRow? {
        guard let row = airPlayHandoff.mark(step, outputLatency: outputLatency, at: t) else { return nil }
        return emitAirPlayHandoff(row, at: t)
    }

    /// Notes a skip, timeout or failed start without emitting; later steps still record.
    public mutating func airPlayGapHandoffNote(_ outcome: AirPlayGapHandoffTrace.Outcome) {
        airPlayHandoff.note(outcome)
    }

    /// Starts a handoff for `afterTrack`. Emits a still-open previous break first, with
    /// every missing step reported.
    @discardableResult
    public mutating func airPlayGapHandoffBegin(afterTrack: Int, outputLatency: TimeInterval? = nil,
                                                at t: TimeInterval) -> P0TraceRow? {
        guard let row = airPlayHandoff.begin(afterTrack: afterTrack, outputLatency: outputLatency, at: t) else {
            return nil
        }
        return emitAirPlayHandoff(row, at: t)
    }

    /// Emits the open break now, with missing steps listed. Nil when nothing is open.
    @discardableResult
    public mutating func airPlayGapHandoffFinalize(at t: TimeInterval) -> P0TraceRow? {
        guard let row = airPlayHandoff.finalize() else { return nil }
        return emitAirPlayHandoff(row, at: t)
    }

    private mutating func emitAirPlayHandoff(_ row: AirPlayGapHandoffTrace.Row, at t: TimeInterval) -> P0TraceRow {
        func ms(_ step: AirPlayGapHandoffTrace.Step) -> P0TraceValue {
            row.milliseconds[step].map { .int($0) } ?? .missing
        }
        func code(_ step: AirPlayGapHandoffTrace.Step) -> P0TraceCode {
            P0TraceCode(rawValue: step.rawValue) ?? .unknown
        }
        let missing = row.missing.map { code($0) }
        return record(.sessionRoute, at: t, [
            (.kind, .code(.handoff)),
            (.after, row.afterTrack.map { .int($0) } ?? .missing),
            (.result, .code(P0TraceCode(rawValue: row.outcome.rawValue) ?? .unknown)),
            (.songEnd, ms(.songEnd)),
            (.firstPlay, ms(.firstPlay)),
            (.lastFinish, ms(.lastFinish)),
            (.sessionOff, ms(.sessionOff)),
            (.nextPlay, ms(.nextPlay)),
            (.musicPlaying, ms(.musicPlaying)),
            (.latency, row.outputLatencyMs.map { .int($0) } ?? .missing),
            (.missing, missing.isEmpty ? .missing : .joinedCodes(missing)),
        ])
    }
}
#endif
