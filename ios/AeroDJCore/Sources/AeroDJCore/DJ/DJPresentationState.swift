import Foundation
import Observation

/// What the UI may show about the DJ. See docs/dj-presentation-state.md for the
/// truthful-display rules (LIVE only while `.speaking`).
public enum DJPresentationState: Equatable, Sendable {
    /// No break in progress or pending. Music only.
    case idle
    /// Rendering speech for the break after `afterTrack`. Nothing is audible yet.
    case preparing(afterTrack: Int, includesBriefing: Bool)
    /// Audio is rendered and waiting for the end of the current song.
    case ready(afterTrack: Int, includesBriefing: Bool, seconds: Double)
    /// The player confirmed speech audio is playing now.
    case speaking(afterTrack: Int, includesBriefing: Bool)
    /// The DJ cannot talk right now; music continues.
    case unavailable(DJUnavailableReason)

    /// True only while real speech audio is playing.
    public var isLive: Bool { if case .speaking = self { true } else { false } }

    /// The break that is audible now, or nil when nothing is speaking.
    public var speakingTrack: Int? { if case .speaking(let k, _) = self { k } else { nil } }
}

public enum DJUnavailableReason: Equatable, Sendable {
    /// Shared items wait for review; nothing personal is narrated until the user decides.
    case consentReviewRequired(pendingCount: Int)
    /// Rendering or playback failed for the last break.
    case voiceFailed
    /// The user's voice budget for today is used up and no free voice could render.
    case budgetReached
}

/// Inputs. Each comes from a real source: the consent review, `DJBreakPreparer`, or the audio player.
public enum DJPresentationEvent: Equatable, Sendable {
    case consentReviewPending(count: Int)
    case breakPreparing(afterTrack: Int, includesBriefing: Bool)
    case breakReady(afterTrack: Int, includesBriefing: Bool, seconds: Double)
    case breakSkipped(afterTrack: Int, DJBreakSkipReason)
    /// Player callbacks (Claude's `djStarted` / `djFinished` / `djCancelled`, `djFailed`).
    case playbackStarted(afterTrack: Int)
    case playbackFinished(afterTrack: Int)
    case playbackFailed(afterTrack: Int)
    /// The listening session stopped or the queue was replaced.
    case sessionStopped
}

/// Pure reducer. Precedence: speaking > ready/preparing > unavailable > idle.
/// `speaking` only ever comes from `playbackStarted`, and ends on finished/failed.
public struct DJPresentationModel: Equatable, Sendable {
    private struct Pending: Equatable, Sendable { var includesBriefing: Bool; var seconds: Double? }
    private var consentPending = 0
    private var speaking: (afterTrack: Int, includesBriefing: Bool)?
    private var pending: [Int: Pending] = [:]
    private var failure: DJUnavailableReason?

    public init() {}

    public static func == (a: Self, b: Self) -> Bool {
        a.consentPending == b.consentPending && a.speaking?.afterTrack == b.speaking?.afterTrack
            && a.speaking?.includesBriefing == b.speaking?.includesBriefing && a.pending == b.pending && a.failure == b.failure
    }

    public var state: DJPresentationState {
        if let speaking { return .speaking(afterTrack: speaking.afterTrack, includesBriefing: speaking.includesBriefing) }
        if let k = pending.keys.min(), let p = pending[k] {
            if let seconds = p.seconds { return .ready(afterTrack: k, includesBriefing: p.includesBriefing, seconds: seconds) }
            return .preparing(afterTrack: k, includesBriefing: p.includesBriefing)
        }
        if consentPending > 0 { return .unavailable(.consentReviewRequired(pendingCount: consentPending)) }
        if let failure { return .unavailable(failure) }
        return .idle
    }

    @discardableResult
    public mutating func apply(_ event: DJPresentationEvent) -> DJPresentationState {
        switch event {
        case .consentReviewPending(let count):
            consentPending = max(0, count)
        case .breakPreparing(let k, let briefing):
            pending[k] = Pending(includesBriefing: briefing, seconds: nil)
        case .breakReady(let k, let briefing, let seconds):
            pending[k] = Pending(includesBriefing: briefing, seconds: seconds)
            failure = nil
        case .breakSkipped(let k, let reason):
            pending[k] = nil
            switch reason {
            case .costCap: failure = .budgetReached
            case .renderFailed, .overDuration, .timedOut, .overBreakBudget: failure = .voiceFailed
            case .notReadyAtBoundary, .notPlanned, .notNaturalBoundary, .cancelled, .sourceRevoked, .interrupted: break  // music simply continues
            }
        case .playbackStarted(let k):
            let briefing = pending.removeValue(forKey: k)?.includesBriefing ?? false
            speaking = (k, briefing)
        case .playbackFinished(let k):
            if speaking?.afterTrack == k { speaking = nil; failure = nil }
            pending[k] = nil
        case .playbackFailed(let k):
            if speaking?.afterTrack == k { speaking = nil }
            pending[k] = nil
            failure = .voiceFailed
        case .sessionStopped:
            speaking = nil
            pending.removeAll()
            failure = nil
        }
        return state
    }
}

/// Observable wrapper for SwiftUI (`@Observable`) and for non-UI consumers (`updates()`).
@MainActor @Observable
public final class DJPresentationStore {
    public private(set) var state: DJPresentationState = .idle
    /// Live DJ voice level for the on-air orb, 0...1, smoothed, about 30 updates a second
    /// while speech plays. Exactly 0 unless `state` is `.speaking`: it drops to 0 in the same
    /// update that leaves `.speaking` (finish, failure, revoke, skip, interruption, stop), and
    /// a sample for any other break, or one that arrives late, is ignored. Only the clip
    /// player sets it, through `updateSpeechLevel(_:afterTrack:)`. -Fry
    public private(set) var speechLevel: Float = 0
    @ObservationIgnored private var model = DJPresentationModel()
    @ObservationIgnored private var continuations: [UUID: AsyncStream<DJPresentationState>.Continuation] = [:]

    public init() {}

    public func send(_ event: DJPresentationEvent) {
        let next = model.apply(event)
        guard next != state else { return }
        state = next
        if !next.isLive || next.speakingTrack != speakingLevelTrack { speechLevel = 0; speakingLevelTrack = nil }
        for continuation in continuations.values { continuation.yield(next) }
    }

    /// The break whose level `speechLevel` shows. Reset whenever speaking ends or changes break.
    @ObservationIgnored private var speakingLevelTrack: Int?

    /// A level reading from the clip player for the break after `afterTrack`.
    ///
    /// Applied only while `state` is `.speaking(afterTrack:)` for that same break; otherwise
    /// the level stays 0 and the sample is dropped, so a stale tick after the break ended can
    /// never show DJ activity. 0 is always accepted, so the player can clear it at once on a
    /// stop before the state event arrives. Values are clamped to 0...1; NaN is 0.
    public func updateSpeechLevel(_ level: Float, afterTrack: Int) {
        let clamped: Float = level.isNaN ? 0 : min(1, max(0, level))
        guard clamped > 0 else {
            if speechLevel != 0 { speechLevel = 0 }
            return
        }
        guard state.speakingTrack == afterTrack else { return }
        speakingLevelTrack = afterTrack
        if speechLevel != clamped { speechLevel = clamped }
    }

    /// Current state first, then every change.
    public func updates() -> AsyncStream<DJPresentationState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DJPresentationState>.makeStream(bufferingPolicy: .unbounded)
        continuation.yield(state)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        return stream
    }
}

extension DJBreakPreparer.DJBreakEvent {
    public var presentationEvent: DJPresentationEvent {
        switch self {
        case .preparing(let k, let briefing): .breakPreparing(afterTrack: k, includesBriefing: briefing)
        case .prepared(let k, let briefing, let seconds): .breakReady(afterTrack: k, includesBriefing: briefing, seconds: seconds)
        case .skipped(let k, let reason): .breakSkipped(afterTrack: k, reason)
        }
    }
}
