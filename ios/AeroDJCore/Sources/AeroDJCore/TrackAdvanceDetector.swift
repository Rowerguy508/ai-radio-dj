import Foundation

/// A single sample of the player's observable state. Pure value, feed it from
/// any MusicKit/AVFeedback source so the detector stays testable on CI.
public struct PlaybackSample: Equatable, Sendable {
    public let isPlaying: Bool
    public let reachedEnd: Bool   // playback position hit the end of the current item
    public let itemChanged: Bool  // current queue item differs from the last sample

    public init(isPlaying: Bool, reachedEnd: Bool, itemChanged: Bool) {
        self.isPlaying = isPlaying
        self.reachedEnd = reachedEnd
        self.itemChanged = itemChanged
    }
}

/// Detects a *natural* track end from a stream of samples and reports it once.
/// Pure + deterministic so the radio transition logic is testable on CI without
/// a device. A natural end = playing, then reached the end of the item and
/// stopped advancing (MusicKit auto-advances the queue itself).
public struct TrackAdvanceDetector: Sendable {
    private var lastWasPlaying = false
    private var pendingEnd = false

    public init() {}

    public mutating func consume(_ sample: PlaybackSample) -> Bool {
        if sample.itemChanged {
            lastWasPlaying = sample.isPlaying
            pendingEnd = false
            return false
        }
        // Was playing, now reached end: that's a natural end — fire exactly once.
        if sample.reachedEnd && !pendingEnd {
            pendingEnd = true
            lastWasPlaying = false
            return true
        }
        lastWasPlaying = sample.isPlaying
        if !sample.reachedEnd {
            pendingEnd = false
        }
        return false
    }
}