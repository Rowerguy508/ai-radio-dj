// Compiled only in Debug (so `swift test` runs its tests) and in AERODJ_P0_DIAG builds, like
// DirectModeMachine. A plain Release carries none of it. -Atlas
#if DEBUG || AERODJ_P0_DIAG
import Foundation

// P0 Experiment B (-Atlas): the layer matrix. Direct Mode re-adds the app's real playback layers
// one at a time, cumulatively: level N turns on B1...BN. Level 0 is plain Direct Mode (build 13).
// Every layer here drives the REAL Core types the normal app uses (`PlaybackEngine`,
// `BoundaryInterpreter`, `PlaybackAttempts`, `PlaybackConfirmWatchdog` / `PlaybackConfirmPolicy`,
// `AudioSessionPolicy`); nothing is reimplemented. `MusicKitService` is not involved.
// The trace is sanitized: layer id, state enums and t. No titles, IDs, tokens or route names.

/// The seven layers from docs/qa/p0-direct-mode-experiments.md, Experiment B.
public enum DirectModeLayer: Int, Equatable, Sendable, CaseIterable, Comparable {
    case coordinator = 1
    case queueBoundary = 2
    case confirm = 3
    case interruption = 4
    // TODO(P0 Experiment B, B5-B7): defined so the levels and log ids are stable, NOT wired yet.
    // B5 needs BreakEndSequence + InterludePlaybackAdapter, B6 OnDeviceSpeechProvider, B7
    // narration. Until they are wired the selector cannot reach them (`maxWired`).
    case djBreak = 5
    case speech = 6
    case narration = 7

    /// "B1" ... "B7", as in the experiments doc.
    public var id: String { "B\(rawValue)" }

    /// True for the layers this build can actually turn on.
    public var isWired: Bool { rawValue <= DirectModeLayerLevel.maxWired }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The "layers up to N" selector. Read once at launch; a change applies on the next cold launch.
public struct DirectModeLayerLevel: Equatable, Sendable, CustomStringConvertible {
    /// Highest level defined (B7).
    public static let maxDefined = DirectModeLayer.allCases.count
    /// Highest level this build wires (B4). Raise when B5-B7 land.
    public static let maxWired = 4
    /// Level 0: plain Direct Mode, exactly build 13.
    public static let off = DirectModeLayerLevel(stored: 0)

    public let value: Int

    /// From the stored default. Missing reads as 0; anything outside 0...maxWired is clamped, so a
    /// stale or hand-edited value can never turn on an unwired layer.
    public init(stored: Int) {
        value = min(max(stored, 0), Self.maxWired)
    }

    public func enables(_ layer: DirectModeLayer) -> Bool { layer.rawValue <= value }

    public var enabledLayers: [DirectModeLayer] { DirectModeLayer.allCases.filter(enables) }

    public var isOff: Bool { value == 0 }

    public var description: String {
        value == 0 ? "0 (plain Direct Mode)" : "\(value) (B1-B\(value))"
    }
}

/// B2: what the boundary layer saw.
public enum DirectModeBoundaryKind: String, Equatable, Sendable {
    case advancedEntry, plannedHandoff, stopped, noProgressEnd
}

/// B2: what happened to the next song after a boundary.
public enum DirectModeHandoffResult: String, Equatable, Sendable {
    /// The next song was loaded (one queue change) and asked to play.
    case loaded
    /// `PlaybackAttempts.takeNext` refused: a tap or skip replaced the queue since the boundary.
    case stale
    /// Last song: nothing to load.
    case none
}

/// B3: one non-routine report of the confirm watchdog. `keepWaiting` is never logged.
public enum DirectModeConfirmReport: String, Equatable, Sendable {
    case armed, confirmed, timeoutReported, interruptedReported, stopWaiting, superseded
}

/// B4: an `AVAudioSession` notification, as `AudioSessionNotice` sees it.
public enum DirectModeSessionNoticeKind: String, Equatable, Sendable {
    case interruptionBegan, interruptionEndedShouldResume, interruptionEndedNoResume
    case routeDeviceRemoved, routeOther

    public init(_ notice: AudioSessionNotice) {
        switch notice {
        case .interruptionBegan: self = .interruptionBegan
        case .interruptionEnded(true): self = .interruptionEndedShouldResume
        case .interruptionEnded(false): self = .interruptionEndedNoResume
        case .routeChanged(.oldDeviceUnavailable): self = .routeDeviceRemoved
        case .routeChanged(.other): self = .routeOther
        }
    }
}

/// A player command a layer asks the controller to issue. Only B2 and B4 ever ask.
public enum DirectModeLayerAction: Equatable, Sendable {
    /// B4: the session policy said suspend.
    case pause
    /// B4: the interruption ended with `shouldResume` and the user had been playing.
    case resume
    /// B2: set the queue to the loaded song at `index` (one queue change) and play it.
    case loadAndPlay(index: Int)
}

public struct DirectModeLayerTraceEntry: Equatable, Sendable, CustomStringConvertible {
    public enum Event: Equatable, Sendable {
        case level(Int)
        case routed(DirectModeCommand, TransportState)
        case transport(TransportState)
        case boundary(DirectModeBoundaryKind)
        case handoff(DirectModeHandoffResult)
        case confirm(DirectModeConfirmReport)
        case notice(DirectModeSessionNoticeKind, AudioSessionDirective)
        case action(DirectModeLayerAction)
        /// The controller's player call for an action threw (no error text, by design).
        case actionThrew(DirectModeLayerAction)
    }

    /// Seconds since Direct Mode opened (same clock as the Direct Mode log).
    public let t: Double
    /// nil for the launch line.
    public let layer: DirectModeLayer?
    public let event: Event

    public var description: String {
        let head = "+" + String(format: "%.2f", t) + "s " + (layer.map { "layer.\($0.id) " } ?? "")
        switch event {
        case .level(let n): return head + "layers.level=\(n)"
        case let .routed(c, transport): return head + "routed.\(c.rawValue) transport=\(transport.rawValue)"
        case .transport(let s): return head + "transport=\(s.rawValue)"
        case .boundary(let b): return head + "boundary.\(b.rawValue)"
        case .handoff(let h): return head + "handoff.\(h.rawValue)"
        case .confirm(let c): return head + "confirm.\(c.rawValue)"
        case let .notice(n, d): return head + "session.\(n.rawValue) -> \(Self.name(d))"
        case .action(let a): return head + "action.\(Self.name(a))"
        case .actionThrew(let a): return head + "action.\(Self.name(a)).threw"
        }
    }

    static func name(_ d: AudioSessionDirective) -> String {
        switch d {
        case .suspendPlayback: return "suspendPlayback"
        case .resumeIfPermitted: return "resumeIfPermitted"
        case .none: return "none"
        }
    }

    static func name(_ a: DirectModeLayerAction) -> String {
        switch a {
        case .pause: return "pause"
        case .resume: return "resume"
        case .loadAndPlay(let i): return "loadAndPlay.\(i)"
        }
    }
}

/// The enabled layers' state. Pure and deterministic (time is passed in), so every level is tested
/// on Linux. The app controller feeds it commands, player reads and session notices, and issues
/// exactly the actions it returns. At level 0 it returns nothing and records nothing but the
/// launch line, so Direct Mode behaves exactly as build 13.
public struct DirectModeLayerStack: Sendable {
    public static let traceCapacity = 300
    /// The confirm watchdog's poll spacing (PlaybackConfirmPolicy: 16 x 0.5 s = 8 s).
    public static let confirmPollInterval: Double = 0.5

    public let level: DirectModeLayerLevel
    public let songCount: Int
    public private(set) var trace: [DirectModeLayerTraceEntry] = []

    // B1
    private var engine = PlaybackEngine()
    private var engineHasQueue = false
    // B2
    private var boundaries = BoundaryInterpreter()
    private var attempts = PlaybackAttempts()
    /// Song index the one-song queue holds (B2 loads one song at a time, like the normal app).
    public private(set) var queueIndex = 0
    // B3
    private var watchdog: PlaybackConfirmWatchdog?
    private var lastConfirmPoll: Double = -.infinity
    // B4
    private var sessionPolicy = AudioSessionPolicy()

    public init(level: DirectModeLayerLevel, songCount: Int, at t: Double = 0) {
        self.level = level
        self.songCount = songCount
        record(nil, .level(level.value), at: t)
    }

    /// B1's transport (`PlaybackEngine.snapshot.transport`).
    public var transport: TransportState { engine.snapshot.transport }
    public var startTimedOut: Bool { engine.snapshot.startTimedOut }
    /// B2: Load sets a one-song queue and Next / a boundary loads the next song.
    public var usesOneSongQueue: Bool { level.enables(.queueBoundary) }
    /// B4: the controller installs interruption and route-change observers (observe only).
    public var observesSessionNotifications: Bool { level.enables(.interruption) }
    public var mayAutoResume: Bool { sessionPolicy.mayAutoResume }

    /// The machine accepted a user command and the controller is about to issue it.
    public mutating func userCommand(_ command: DirectModeCommand, at t: Double) {
        guard level.enables(.coordinator) else { return }
        // B4 first, as MusicKitService records intent before it touches the player.
        if level.enables(.interruption) {
            switch command {
            case .play, .resume: sessionPolicy.userPlay()
            case .pause: sessionPolicy.userPause()
            case .load, .next: break
            }
        }
        if level.enables(.queueBoundary) {
            switch command {
            case .next:
                boundaries.userRequestedChange()
                attempts.userChangedQueue()
            case .pause:
                boundaries.pausedByApp(.userPause)
            case .load, .play, .resume:
                break
            }
        }
        switch command {
        case .load:
            break
        case .play, .resume:
            if engineHasQueue {
                engine.apply(.userResumed)
            } else {
                engine.apply(.queueStarted(tracks: Self.placeholders(songCount), startIndex: 0, station: nil))
                engineHasQueue = true
            }
            beginAttempt(at: t)
        case .pause:
            engine.apply(.userPaused)
        case .next:
            queueIndex = min(queueIndex + 1, songCount - 1)
            engine.apply(.userSkipped(nextIndex: queueIndex))
            beginAttempt(at: t)
        }
        record(.coordinator, .routed(command, engine.snapshot.transport), at: t)
    }

    /// One poll of the player. Returns the commands the enabled layers ask for (B2 handoff only;
    /// B3 never asks for anything: the confirm deadline only reports).
    public mutating func observe(status: DirectModeStatus, position: Double, duration: Double?,
                                 entryIndex: Int?, at t: Double) -> [DirectModeLayerAction] {
        guard level.enables(.coordinator) else { return [] }
        var actions: [DirectModeLayerAction] = []
        let before = engine.snapshot.transport

        if level.enables(.confirm) {
            pollConfirm(status: status, at: t)
        } else if status == .playing, engine.snapshot.transport == .preparing {
            engine.apply(.playbackConfirmed)
        }

        if level.enables(.queueBoundary), engineHasQueue {
            let observation = PlaybackObservation(entryID: entryIndex.map(String.init),
                                                  isPlaying: status == .playing,
                                                  position: position, duration: duration)
            if let step = boundaries.interpret(observation, queueIndex: queueIndex, queueCount: songCount) {
                actions += handle(step, at: t)
            } else if boundaries.takeNoProgressEnd() {
                record(.queueBoundary, .boundary(.noProgressEnd), at: t)
            }
        }

        if engine.snapshot.transport != before {
            record(.coordinator, .transport(engine.snapshot.transport), at: t)
        }
        return actions
    }

    /// B4: one interruption or route-change notification, in arrival order.
    public mutating func handle(_ notice: AudioSessionNotice, at t: Double) -> [DirectModeLayerAction] {
        guard level.enables(.interruption) else { return [] }
        let directive = sessionPolicy.handle(notice, breakIsActive: false)
        record(.interruption, .notice(DirectModeSessionNoticeKind(notice), directive), at: t)
        switch directive {
        case .suspendPlayback:
            switch notice {
            case .routeChanged:
                boundaries.pausedByApp(.routeLoss)
                engine.apply(.routePaused)
            default:
                boundaries.pausedByApp(.systemInterruption)
                engine.apply(.interruptionPaused)
            }
            record(.interruption, .action(.pause), at: t)
            return [.pause]
        case .resumeIfPermitted:
            guard sessionPolicy.mayAutoResume else { return [] }
            engine.apply(.userResumed)
            beginAttempt(at: t)
            record(.interruption, .action(.resume), at: t)
            return [.resume]
        case .none:
            return []
        }
    }

    /// The controller's player call for `action` threw. Logged without the error.
    public mutating func actionFailed(_ action: DirectModeLayerAction, at t: Double) {
        let layer: DirectModeLayer
        switch action {
        case .loadAndPlay: layer = .queueBoundary
        case .pause, .resume: layer = .interruption
        }
        record(layer, .actionThrew(action), at: t)
        if transport == .preparing { engine.apply(.playbackStartRefused) }
    }

    /// The Direct Mode log and the layer trace as one list, oldest first, for the screen and
    /// "Copy log". Ordered by t; on a tie the Direct Mode line comes first.
    public static func mergedLog(_ log: [DirectModeLogEntry], _ trace: [DirectModeLayerTraceEntry]) -> [String] {
        let tagged = log.enumerated().map { (t: $0.element.t, rank: 0, i: $0.offset, line: $0.element.description) }
            + trace.enumerated().map { (t: $0.element.t, rank: 1, i: $0.offset, line: $0.element.description) }
        return tagged.sorted { ($0.t, $0.rank, $0.i) < ($1.t, $1.rank, $1.i) }.map(\.line)
    }

    // MARK: - Private

    private mutating func handle(_ step: BoundaryStep, at t: Double) -> [DirectModeLayerAction] {
        switch step {
        case let .advancedEntry(finished, _):
            record(.queueBoundary, .boundary(.advancedEntry), at: t)
            attempts.armNext(after: finished)
            engine.apply(.naturalBoundary(nextIndex: finished + 1))
            queueIndex = finished + 1
            // The multi-song queue already moved on; nothing to load.
            _ = attempts.takeNext(after: finished)
            return []
        case let .plannedHandoff(finished, next, _):
            record(.queueBoundary, .boundary(.plannedHandoff), at: t)
            attempts.armNext(after: finished)
            engine.apply(.naturalBoundary(nextIndex: next))
            // No break layer yet (B5 unwired), so the next song starts straight away, through the
            // same stale-boundary check `startNextTrack` uses.
            guard attempts.takeNext(after: finished) else {
                record(.queueBoundary, .handoff(.stale), at: t)
                return []
            }
            boundaries.userRequestedChange()
            queueIndex = next
            beginAttempt(at: t)
            record(.queueBoundary, .handoff(.loaded), at: t)
            return [.loadAndPlay(index: next)]
        case .stopped:
            record(.queueBoundary, .boundary(.stopped), at: t)
            engine.apply(.queueFinished)
            record(.queueBoundary, .handoff(.none), at: t)
            return []
        }
    }

    private mutating func beginAttempt(at t: Double) {
        let attempt = attempts.beginStart()
        guard level.enables(.confirm) else { return }
        watchdog = PlaybackConfirmWatchdog(attempt: attempt)
        lastConfirmPoll = t
        record(.confirm, .confirm(.armed), at: t)
    }

    private mutating func pollConfirm(status: DirectModeStatus, at t: Double) {
        guard var dog = watchdog, !dog.isFinished, t - lastConfirmPoll >= Self.confirmPollInterval - 0.05 else {
            return
        }
        lastConfirmPoll = t
        let step = dog.observe(status: Self.confirmStatus(status),
                               transportIsPreparing: engine.snapshot.transport == .preparing,
                               currentAttempt: attempts.current)
        watchdog = dog
        // Never pauses or skips: PlaybackConfirmPolicy.pausesPlayer is false for every step.
        assert(!PlaybackConfirmPolicy.pausesPlayer(step))
        switch step {
        case .confirmed:
            engine.apply(.playbackConfirmed)
            record(.confirm, .confirm(.confirmed), at: t)
        case .reportTimeoutKeepPlayer:
            engine.apply(.startConfirmTimedOut)
            record(.confirm, .confirm(.timeoutReported), at: t)
        case .failInterrupted:
            record(.confirm, .confirm(.interruptedReported), at: t)
        case .stopWaiting:
            record(.confirm, .confirm(.stopWaiting), at: t)
        case .superseded:
            record(.confirm, .confirm(.superseded), at: t)
        case .keepWaiting:
            break
        }
    }

    static func confirmStatus(_ status: DirectModeStatus) -> ConfirmStatus {
        switch status {
        case .playing: return .playing
        case .paused: return .paused
        case .stopped, .unknown: return .stopped
        case .interrupted: return .interrupted
        case .seekingForward, .seekingBackward: return .seeking
        }
    }

    /// The engine needs tracks; these carry an index only (never shown or logged).
    static func placeholders(_ count: Int) -> [TrackInfo] {
        (0..<max(count, 1)).map { TrackInfo(id: String($0), title: "", artistName: "") }
    }

    private mutating func record(_ layer: DirectModeLayer?, _ event: DirectModeLayerTraceEntry.Event, at t: Double) {
        trace.append(DirectModeLayerTraceEntry(t: t, layer: layer, event: event))
        if trace.count > Self.traceCapacity { trace.removeFirst(trace.count - Self.traceCapacity) }
    }
}
#endif
