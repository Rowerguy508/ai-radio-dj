import Foundation

/// One `play()` of a queue.
///
/// A natural-end continuation captures `value` before it awaits the DJ break.
/// `play()` advances it when the user starts a different queue. The continuation
/// must not load a song into that newer queue.
public struct QueueGeneration: Equatable, Sendable {
    public private(set) var value: UInt64

    public init() {
        value = 0
    }

    /// The queue `play()` is about to install. Returns the generation now in force.
    @discardableResult
    public mutating func beginQueue() -> UInt64 {
        value &+= 1
        return value
    }
}

/// Whether a boundary continuation may still change the live queue.
public enum QueueGenerationGuard {
    public static func isCurrent(captured: UInt64, live: UInt64) -> Bool {
        captured == live
    }

    /// The song a same-generation boundary may load.
    ///
    /// Nil when `play()` has replaced the queue, and nil when `QueueHandoff` says
    /// the finished song was the last one. A stale generation does not advance.
    public static func nextTrack(
        after finishedIndex: Int,
        captured: UInt64,
        live: UInt64,
        queueCount: Int
    ) -> Int? {
        guard isCurrent(captured: captured, live: live) else { return nil }
        guard case let .advance(to: index) = QueueHandoff.afterSongEnds(
            finishedIndex: finishedIndex, count: queueCount
        ) else {
            return nil
        }
        return index
    }
}
