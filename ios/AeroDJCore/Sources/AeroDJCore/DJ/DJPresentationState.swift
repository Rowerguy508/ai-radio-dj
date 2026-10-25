import Foundation

/// What the UI shows about the DJ. Driven only by real events: `speaking` is
/// true only between the audio engine's "speech audio started" and "finished"
/// callbacks, never because a break was planned or prepared.
public enum DJPresentationState: Equatable, Sendable {
    case idle
    /// Rendering speech for the break after `afterTrack`.
    case preparing(afterTrack: Int)
    /// Speech audio is playing now.
    case speaking(afterTrack: Int)
    /// A prepared break with briefing content plays after this track.
    case upcomingBriefing(afterTrack: Int)
    /// Shared items wait for the user's review; nothing personal is narrated until then.
    case consentReviewRequired(pendingCount: Int)
}

public enum DJPresentationEvent: Equatable, Sendable {
    case consentReviewPending(count: Int)
    case breakPreparing(afterTrack: Int)
    /// `hasBriefing`: the prepared break carries briefing cues.
    case breakPrepared(afterTrack: Int, hasBriefing: Bool)
    case breakSkipped(afterTrack: Int)
    /// From the audio player: speech audio actually began / ended (finished, failed, or interrupted).
    case speechAudioStarted(afterTrack: Int)
    case speechAudioEnded(afterTrack: Int)
    /// The listening session stopped; clears everything except pending consent.
    case sessionStopped
}

/// Reducer for `DJPresentationState`. Priority: consent > speaking > preparing > upcoming briefing > idle.
public struct DJPresentationModel: Equatable, Sendable {
    private var consentPending = 0
    private var speaking: Int?
    private var preparing: Set<Int> = []
    private var upcomingBriefing: Set<Int> = []

    public init() {}

    public var state: DJPresentationState {
        if consentPending > 0 { return .consentReviewRequired(pendingCount: consentPending) }
        if let speaking { return .speaking(afterTrack: speaking) }
        if let k = preparing.min() { return .preparing(afterTrack: k) }
        if let k = upcomingBriefing.min() { return .upcomingBriefing(afterTrack: k) }
        return .idle
    }

    @discardableResult
    public mutating func apply(_ event: DJPresentationEvent) -> DJPresentationState {
        switch event {
        case .consentReviewPending(let count): consentPending = max(0, count)
        case .breakPreparing(let k): preparing.insert(k)
        case .breakPrepared(let k, let hasBriefing):
            preparing.remove(k)
            if hasBriefing { upcomingBriefing.insert(k) }
        case .breakSkipped(let k):
            preparing.remove(k); upcomingBriefing.remove(k)
        case .speechAudioStarted(let k):
            preparing.remove(k); upcomingBriefing.remove(k); speaking = k
        case .speechAudioEnded(let k):
            if speaking == k { speaking = nil }
        case .sessionStopped:
            speaking = nil; preparing.removeAll(); upcomingBriefing.removeAll()
        }
        return state
    }
}

extension DJBreakPreparer.DJBreakEvent {
    /// Maps preparation events. `hasBriefing` comes from the planned break.
    public func presentationEvent(hasBriefing: Bool) -> DJPresentationEvent {
        switch self {
        case .preparing(let k): .breakPreparing(afterTrack: k)
        case .prepared(let k): .breakPrepared(afterTrack: k, hasBriefing: hasBriefing)
        case .skipped(let k, _): .breakSkipped(afterTrack: k)
        }
    }
}
