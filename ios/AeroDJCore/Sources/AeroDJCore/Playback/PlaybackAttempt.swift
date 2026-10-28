import Foundation

/// Build 9 P0 (-Atlas): one start of playback. A song tap, a resume, a skip, and the next song
/// after a break each begin a new attempt. Anything that finishes late (a confirm watchdog, a
/// thrown `play()`, a refused gate) carries the attempt it belongs to and does nothing once a
/// newer attempt exists, so an old start can never pause, fail or skip a new one.
public struct PlaybackAttemptID: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let number: Int
    public init(number: Int) { self.number = number }
    public var description: String { "#\(number)" }
}

/// Attempt and queue generations, owned by `MusicKitService`. Pure, so the races are tested on Linux.
public struct PlaybackAttempts: Equatable, Sendable {
    public private(set) var current: PlaybackAttemptID?
    /// Bumped by every user queue change (song tap, skip). A natural boundary captures it, and
    /// the next song after that boundary's break is loaded only if it is still the same.
    public private(set) var queueGeneration = 0
    private var counter = 0

    public init() {}

    /// A new start. Every older attempt is stale from here on.
    @discardableResult
    public mutating func beginStart() -> PlaybackAttemptID {
        counter += 1
        let id = PlaybackAttemptID(number: counter)
        current = id
        return id
    }

    public func isCurrent(_ id: PlaybackAttemptID) -> Bool { current == id }

    /// The user cancelled the current start (Stop after its deadline, Sentinel). No attempt is
    /// current until the next start, so a late `.playing`, throw or refusal for it changes nothing.
    public mutating func userCancelledCurrent() {
        current = nil
    }

    /// The user replaced the queue or skipped. Boundaries captured before this are stale.
    @discardableResult
    public mutating func userChangedQueue() -> Int {
        queueGeneration += 1
        return queueGeneration
    }

    /// `startNextTrack` after a natural boundary's break: only when no tap or skip happened since.
    public func mayStartNext(capturedGeneration: Int) -> Bool {
        capturedGeneration == queueGeneration
    }

    /// The natural boundary that may load the next song, captured when the poll reported it.
    public private(set) var pendingNext: PendingNext?

    public struct PendingNext: Equatable, Sendable {
        public let finishedIndex: Int
        public let generation: Int
    }

    /// The poll reported a natural end of `finishedIndex`. Its break (or skip) runs next, then
    /// `startNextTrack(after: finishedIndex)` asks `takeNext`.
    public mutating func armNext(after finishedIndex: Int) {
        pendingNext = PendingNext(finishedIndex: finishedIndex, generation: queueGeneration)
    }

    /// True once, for the boundary that armed it, and only if no tap or skip replaced the queue
    /// in between. A stale boundary (the user tapped a song during the break) loads nothing, so
    /// it cannot replace the tapped song with the next one of the NEW queue.
    public mutating func takeNext(after finishedIndex: Int) -> Bool {
        guard let pending = pendingNext, pending.finishedIndex == finishedIndex else { return false }
        pendingNext = nil
        return mayStartNext(capturedGeneration: pending.generation)
    }

    /// A break's follow-up `resumeIfAllowed` while a start is still preparing belongs to an
    /// older show: the start in flight owns the player, so the resume does nothing.
    public static func breakResumeMayStart(transport: TransportState) -> Bool {
        transport != .preparing
    }
}

/// #109's 8 s start confirm for ONE attempt, as a pure state machine. The app feeds it one
/// MusicKit status per 0.5 s poll; tests feed it status sequences. Every poll goes through
/// `PlaybackConfirmPolicy`. It reports a timeout or an interruption once and keeps watching, so a
/// late `.playing` confirms the same attempt. It never reports or confirms a superseded attempt.
public struct PlaybackConfirmWatchdog: Equatable, Sendable {
    public let attempt: PlaybackAttemptID
    public let maxPolls: Int
    public private(set) var poll = 0
    /// A timeout or interruption was already reported for this attempt. A later `.confirmed`
    /// must clear that error.
    public private(set) var reported = false
    /// Set once the watchdog stops (confirmed, stopWaiting, superseded); later polls return
    /// `.stopWaiting` and change nothing.
    public private(set) var result: ConfirmStep?

    public init(attempt: PlaybackAttemptID, maxPolls: Int = PlaybackConfirmPolicy.maxPolls) {
        self.attempt = attempt
        self.maxPolls = maxPolls
    }

    public var isFinished: Bool { result != nil }

    public mutating func observe(status: ConfirmStatus, transportIsPreparing: Bool,
                                 currentAttempt: PlaybackAttemptID?) -> ConfirmStep {
        if result != nil { return .stopWaiting }
        guard currentAttempt == attempt else {
            result = .superseded
            return .superseded
        }
        poll += 1
        var step = PlaybackConfirmPolicy.step(status: status, transportIsPreparing: transportIsPreparing,
                                              poll: poll, maxPolls: maxPolls)
        switch step {
        case .reportTimeoutKeepPlayer, .failInterrupted:
            // Report once; afterwards keep watching for a late `.playing`.
            if reported { step = .keepWaiting } else { reported = true }
        case .confirmed, .stopWaiting, .superseded:
            result = step
        case .keepWaiting:
            break
        }
        return step
    }
}

/// Error type name, NSError domain and code. Nothing else: no `localizedDescription`, no
/// `userInfo`, no underlying error. Logs only (domain and code); user-facing copy comes from
/// `PlaybackFailureCopy` and never shows it (Sentinel, Orion, #133).
public struct PlaybackErrorCode: Equatable, Sendable, CustomStringConvertible {
    public let typeName: String
    public let domain: String
    public let code: Int

    public init(typeName: String, domain: String, code: Int) {
        self.typeName = typeName
        self.domain = domain
        self.code = code
    }

    public init(_ error: Error) {
        let ns = error as NSError
        self.init(typeName: String(describing: type(of: error)), domain: ns.domain, code: ns.code)
    }

    public var description: String { "\(typeName) \(domain) code \(code)" }
}

/// Why a start did not reach `.playing`.
public enum StartFailure: Equatable, Sendable {
    /// The 8 s confirm deadline passed; the last MusicKit status.
    case confirmDeadline(last: ConfirmStatus)
    /// MusicKit reported `.interrupted` while the start was preparing.
    case confirmInterrupted
    /// `setActive`, `prepareToPlay()` or `play()` threw.
    case threw(PlaybackErrorCode)
    /// The entry changed or cleared before it played 2 s, and MusicKit is not playing.
    case noProgressEnd
    /// The hold gate refused the start after the queue was loaded.
    case refused(pausedBySystem: Bool)
}

/// What the app does for a failed start. It never contains `.naturalBoundary`, `.userSkipped`
/// or `.queueFinished`, and the app never calls `startNextTrack` or moves `queueIndex` for it:
/// a failed start stays on the song the user picked and says so.
public struct StartFailureEffect: Equatable, Sendable {
    /// False for every failure: the app never pauses MusicKit because a start failed.
    public let pausesPlayer: Bool
    public let cancelsConfirm: Bool
    public let events: [PlaybackEvent]
    /// The banner text, when one is raised.
    public let message: String?

    public static let none = StartFailureEffect(pausesPlayer: false, cancelsConfirm: false, events: [], message: nil)

    public var advancesQueue: Bool {
        events.contains { event in
            switch event {
            case .naturalBoundary, .userSkipped, .queueFinished: true
            default: false
            }
        }
    }
}

public enum StartFailurePolicy {
    /// `attempt` is the start that failed, `current` the newest start. A stale failure has no effect.
    public static func effect(_ failure: StartFailure, attempt: PlaybackAttemptID,
                              current: PlaybackAttemptID?) -> StartFailureEffect {
        guard current == attempt else { return .none }
        switch failure {
        case .confirmDeadline:
            // Report only. The player keeps buffering, transport stays `.preparing` (never a false
            // `.playing`), and the watchdog keeps watching for a late `.playing`.
            let message = PlaybackFailureCopy.message(for: .slowStart)
            return StartFailureEffect(pausesPlayer: false, cancelsConfirm: false,
                                      events: raised(message) + [.startConfirmTimedOut], message: message)
        case .confirmInterrupted:
            let message = PlaybackFailureCopy.message(for: .interrupted)
            // Also reported, so the user gets a working Stop instead of a spinner that ignores taps.
            return StartFailureEffect(pausesPlayer: false, cancelsConfirm: false,
                                      events: raised(message) + [.startConfirmTimedOut], message: message)
        case .threw:
            let message = PlaybackFailureCopy.message(for: .couldNotStart)
            return StartFailureEffect(pausesPlayer: false, cancelsConfirm: true,
                                      events: raised(message) + [.userPaused], message: message)
        case .noProgressEnd:
            let message = PlaybackFailureCopy.message(for: .stoppedEarly)
            return StartFailureEffect(pausesPlayer: false, cancelsConfirm: true,
                                      events: raised(message) + [.userPaused], message: message)
        case let .refused(pausedBySystem):
            // The gate already paused the player. Honest UI: not playing, keep a system hold.
            return StartFailureEffect(pausesPlayer: false, cancelsConfirm: true,
                                      events: [pausedBySystem ? .interruptionPaused : .userPaused], message: nil)
        }
    }

    private static func raised(_ message: String) -> [PlaybackEvent] {
        [.errorRaised(PlaybackError(kind: .playbackFailed, message: message, isRecoverable: true))]
    }
}
