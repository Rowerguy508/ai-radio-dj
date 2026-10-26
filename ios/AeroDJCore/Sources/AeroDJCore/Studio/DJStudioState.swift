import Foundation

// Studio-facing DJ status. A presentation mapping over #55's `DJPresentationState`;
// it does not replace it, so Claude's #58 wiring (which feeds `DJPresentationStore`)
// keeps working unchanged. Owner names: idle, preparing, ready, speaking, failed.

public enum DJStudioState: Equatable, Sendable {
    /// No DJ break pending. Music only.
    case idle
    /// Speech for the next break is being rendered. Nothing from the DJ is audible.
    case preparing(includesBriefing: Bool)
    /// Speech is rendered and waits for the current song to end.
    case ready(includesBriefing: Bool, seconds: Double)
    /// The player confirmed DJ audio started and has not finished. The only On Air state.
    case speaking(includesBriefing: Bool)
    /// The DJ can't talk right now. Music continues. (`DJPresentationState.unavailable`.)
    case failed(DJUnavailableReason)

    public init(_ state: DJPresentationState) {
        switch state {
        case .idle: self = .idle
        case .preparing(_, let b): self = .preparing(includesBriefing: b)
        case .ready(_, let b, let s): self = .ready(includesBriefing: b, seconds: s)
        case .speaking(_, let b): self = .speaking(includesBriefing: b)
        case .unavailable(let r): self = .failed(r)
        }
    }

    /// True only while real DJ audio is playing (player-confirmed). Nothing else may be
    /// labeled On Air or LIVE, and no waveform or caption may animate in any other state.
    public var isOnAir: Bool { if case .speaking = self { true } else { false } }

    /// "On Air" while speaking, otherwise `nil`. Use this for any LIVE badge.
    public var onAirLabel: String? { isOnAir ? "On Air" : nil }

    public var title: String {
        switch self {
        case .idle: "Music"
        case .preparing: "Preparing"
        case .ready: "Ready"
        case .speaking: "On Air"
        case .failed(.consentReviewRequired): "Needs review"
        case .failed: "DJ unavailable"
        }
    }

    public var detail: String {
        switch self {
        case .idle:
            return "The DJ is quiet. Music only."
        case .preparing(let briefing):
            return briefing ? "Getting your briefing ready. The DJ isn't speaking yet."
                : "Getting the next DJ break ready. The DJ isn't speaking yet."
        case .ready(let briefing, let seconds):
            let length = "about \(max(1, Int(seconds.rounded()))) seconds"
            return briefing ? "Briefing ready for after this song (\(length))." : "DJ break ready for after this song (\(length))."
        case .speaking(let briefing):
            return briefing ? "The DJ is reading your briefing now." : "The DJ is speaking now."
        case .failed(.consentReviewRequired(let n)):
            return "\(n) shared \(n == 1 ? "item is" : "items are") waiting for your review. Music continues."
        case .failed(.voiceFailed):
            return "The last DJ break couldn't play. Music continues."
        case .failed(.budgetReached):
            return "Today's voice limit is reached. Music continues."
        }
    }
}

@MainActor
public extension DJPresentationStore {
    var studioState: DJStudioState { DJStudioState(state) }
}
