import Foundation

/// The song scrubber's own state (owner request, 7:40 PM: "We also need scrubbing for songs").
///
/// Pure and display-only: it never touches playback. It decides what position the bar
/// shows and which single target to hand to `PlaybackActions.seek(to:trackID:)`, which
/// is called once on release and never during a drag.
///
/// - `idle`: the bar follows the playback snapshot.
/// - `dragging`: the bar shows the finger's target. The clock-driven fill is paused.
/// - `committing`: the seek was sent. The bar holds the target until the snapshot is within
///   `settleTolerance` of it or `holdTimeout` has passed, so it does not snap back while
///   the player catches up. A failed seek returns to the snapshot at once.
///
/// `now` is any monotonic seconds value from the caller, so tests drive time directly.
public struct ScrubberState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case dragging(target: TimeInterval)
        case committing(target: TimeInterval, startedAt: TimeInterval)
    }

    /// The hold ends once the snapshot is this close to the committed target.
    public static let settleTolerance: TimeInterval = 1.5
    /// The hold ends after this long even if the snapshot never arrives.
    public static let holdTimeout: TimeInterval = 2
    /// VoiceOver adjustable step.
    public static let accessibilityStep: TimeInterval = 15

    public private(set) var phase: Phase = .idle
    public private(set) var trackID: String?
    /// Bumped on every commit so a late seek result for an older commit is ignored.
    public private(set) var commitID: Int = 0

    public init(trackID: String? = nil) {
        self.trackID = trackID
    }

    public var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    /// The clock-driven fill is paused while the finger is down.
    public var pausesClock: Bool { isDragging }

    // MARK: Events

    /// A different track resets to idle: an old drag or hold never carries over.
    public mutating func trackChanged(to id: String?) {
        guard id != trackID else { return }
        trackID = id
        phase = .idle
    }

    /// Starts or moves a drag. Returns true only when a new drag began (for the haptic).
    /// Ignored when seeking is unavailable or the duration is unknown.
    @discardableResult
    public mutating func drag(to seconds: TimeInterval, duration: TimeInterval?, canSeek: Bool) -> Bool {
        guard canSeek, let duration, duration > 0 else {
            cancelDrag()
            return false
        }
        let began = !isDragging
        phase = .dragging(target: Self.clamp(seconds, duration: duration))
        return began
    }

    /// Finger lifted. Returns the one target to seek to, or nil when there was no drag.
    public mutating func endDrag(now: TimeInterval) -> TimeInterval? {
        guard case let .dragging(target) = phase else { return nil }
        return commit(target, now: now)
    }

    /// A commit without a drag (VoiceOver's adjustable action). Clamped.
    @discardableResult
    public mutating func commit(_ seconds: TimeInterval, duration: TimeInterval? = nil, now: TimeInterval) -> TimeInterval {
        let target = duration.map { Self.clamp(seconds, duration: $0) } ?? max(0, seconds)
        commitID += 1
        phase = .committing(target: target, startedAt: now)
        return target
    }

    /// Drag cancelled (gesture cancelled, or seeking became unavailable). Back to the snapshot.
    public mutating func cancelDrag() {
        if isDragging { phase = .idle }
    }

    /// `canSeek` turned false (DJ break, loading, track change): a drag in progress is dropped
    /// without seeking.
    public mutating func canSeekChanged(_ canSeek: Bool) {
        if !canSeek { cancelDrag() }
    }

    /// The seek for commit `id` returned. A failure goes straight back to the snapshot; a
    /// success keeps holding until the snapshot catches up or the hold times out.
    public mutating func seekFinished(commitID id: Int, succeeded: Bool) {
        guard id == commitID, case .committing = phase else { return }
        if !succeeded { phase = .idle }
    }

    /// Ends a hold that has settled or timed out. Call on a tick or after `holdTimeout`.
    public mutating func settle(snapshotPosition: TimeInterval, now: TimeInterval) {
        guard case let .committing(target, startedAt) = phase else { return }
        if Self.holdEnded(target: target, startedAt: startedAt, snapshotPosition: snapshotPosition, now: now) {
            phase = .idle
        }
    }

    // MARK: Display

    /// What the bar shows. Pure: a hold that has ended reads as the snapshot even before
    /// `settle` runs.
    public func displayedPosition(snapshotPosition: TimeInterval, duration: TimeInterval?, now: TimeInterval) -> TimeInterval {
        let shown: TimeInterval
        switch phase {
        case .idle:
            shown = snapshotPosition
        case let .dragging(target):
            shown = target
        case let .committing(target, startedAt):
            shown = Self.holdEnded(target: target, startedAt: startedAt, snapshotPosition: snapshotPosition, now: now)
                ? snapshotPosition : target
        }
        guard let duration, duration > 0 else { return max(0, shown) }
        return Self.clamp(shown, duration: duration)
    }

    public static func holdEnded(target: TimeInterval, startedAt: TimeInterval,
                                 snapshotPosition: TimeInterval, now: TimeInterval) -> Bool {
        abs(snapshotPosition - target) <= settleTolerance || now - startedAt >= holdTimeout
    }

    public static func clamp(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0 }
        return min(max(0, seconds), max(0, duration))
    }

    /// 0...1 fill for a position. 0 when the duration is unknown.
    public static func fraction(position: TimeInterval, duration: TimeInterval?) -> Double {
        guard let duration, duration > 0 else { return 0 }
        return clamp(position, duration: duration) / duration
    }

    /// Position under a finger at `x` on a track `width` points wide.
    public static func position(atX x: Double, width: Double, duration: TimeInterval) -> TimeInterval {
        guard width > 0 else { return 0 }
        return clamp(x / width * duration, duration: duration)
    }
}

/// Elapsed and remaining labels: `m:ss` under an hour, `h:mm:ss` from an hour.
public enum PlaybackTimeFormat {
    public static func label(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h):\(pad(m)):\(pad(s))"
        }
        return "\(m):\(pad(s))"
    }

    /// Time left, never negative.
    public static func remaining(position: TimeInterval, duration: TimeInterval) -> String {
        label(max(0, duration - position))
    }

    /// VoiceOver value: "1:12 of 3:45".
    public static func accessibilityValue(position: TimeInterval, duration: TimeInterval) -> String {
        "\(label(position)) of \(label(duration))"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
