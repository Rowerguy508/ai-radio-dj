import Foundation

// Station Tuner read model: one row per control, pending vs active, and the exact copy
// the UI shows for when a change applies. Built on `StationConfigurationModel` (#57);
// no second settings model. See docs/studio-presentation-contract.md.

public extension StationChangeTiming {
    /// User-facing copy for a pending change. `immediate` is never pending; it is the copy
    /// shown briefly after a privacy or silence reduction.
    var appliesCopy: String {
        switch self {
        case .immediate: "Applied now"
        case .nextDJBreak: "Applies at the next DJ break"
        case .nextBriefing: "Applies to the next briefing"
        case .nextSongBoundary: "Applies after this song"
        }
    }
}

public extension StationSetting {
    var title: String {
        switch self {
        case .genres: "Genres"
        case .moods: "Mood"
        case .energy: "Energy"
        case .discovery: "Discovery"
        case .seeds: "Built from"
        case .reach: "Reach"
        case .personality: "DJ personality"
        case .commentary: "DJ talk"
        case .briefing: "Morning briefing"
        case .integration(.calendar): "Calendar"
        case .integration(.obsidian): "Obsidian notes"
        case .integration(.shareInbox): "Shared from Mail & Messages"
        }
    }
}

public extension DJPersonality {
    var title: String {
        switch self {
        case .warm: "Warm"
        case .upbeat: "Upbeat"
        case .laidBack: "Laid-back"
        case .minimal: "Minimal"
        }
    }

    /// Honest description: today a preset only changes how long a plain DJ break may be.
    /// It does not change the voice or the words. Do not promise more in the UI.
    var honestDescription: String {
        switch self {
        case .minimal: "Shorter DJ breaks (up to \(maxTransitionSeconds) seconds). Same voice."
        case .warm, .upbeat, .laidBack: "DJ breaks up to \(maxTransitionSeconds) seconds. Same voice; styles are coming later."
        }
    }
}

public extension CommentaryFrequency {
    var title: String {
        switch self {
        case .off: "Off"
        case .rare: "Rarely"
        case .occasional: "Sometimes"
        case .frequent: "Often"
        case .chatty: "Chatty"
        }
    }

    var honestDescription: String {
        switch self {
        case .off: "Music only. The DJ doesn't talk between songs."
        case .chatty: "The DJ talks after every song."
        default: "The DJ talks after about \(Int((StationConfiguration(commentary: self).cadence().expectedTalkShare * 100).rounded()))% of songs, never two in a row."
        }
    }
}

/// One Station Tuner control, ready to render.
public struct StationTunerRow: Equatable, Sendable, Identifiable {
    public let setting: StationSetting
    public let title: String
    /// What playback and the DJ use right now.
    public let activeSummary: String
    /// The value the control shows (pending if one is waiting).
    public let displayedSummary: String
    /// Set while a change is waiting for a safe boundary.
    public let pendingTiming: StationChangeTiming?
    public let status: StationControlStatus
    public var id: String { title }

    public var isPending: Bool { pendingTiming != nil }
    /// "Applies after this song", etc. `nil` when nothing is pending.
    public var appliesCopy: String? { pendingTiming?.appliesCopy }
}

public extension StationConfiguration {
    /// Short, factual summary of one setting's value.
    func summary(of setting: StationSetting) -> String {
        switch setting {
        case .genres: genres.isEmpty ? "Any" : genres.joined(separator: ", ")
        case .moods: moods.isEmpty ? "Any" : moods.joined(separator: ", ")
        case .energy: "\(Int((energy * 100).rounded()))%"
        case .discovery: "\(Int((discovery * 100).rounded()))% new music"
        case .seeds: seedsSummary
        case .reach: reach.title
        case .personality: personality.title
        case .commentary: commentary.title
        case .briefing: briefing.enabled ? "On, about \(briefing.targetSeconds / 60) min" : "Off"
        case .integration(let i): requestedIntegrations.contains(i) ? "Requested" : "Off"
        }
    }
}

public extension StationReach {
    var title: String {
        switch self {
        case .only: "Only this"
        case .related: "Related"
        case .broad: "Broad"
        }
    }

    var honestDescription: String {
        switch self {
        case .only: "Only what you picked: the artist's own songs, the playlist, the genre chart or the song."
        case .related: "What you picked plus similar artists."
        case .broad: "Related, plus the wider genre and charts."
        }
    }
}

extension StationConfiguration {
    /// On-screen only (seed names never leave the device through this). Up to 3 names, then "+N".
    var seedsSummary: String {
        guard !seeds.isEmpty else { return "Any" }
        let shown = seeds.prefix(3).map(\.name).joined(separator: ", ")
        return seeds.count > 3 ? "\(shown) +\(seeds.count - 3)" : shown
    }
}

@MainActor
public extension StationConfigurationModel {
    func tunerRow(for setting: StationSetting) -> StationTunerRow {
        StationTunerRow(setting: setting, title: setting.title,
                        activeSummary: active.summary(of: setting),
                        displayedSummary: displayed.summary(of: setting),
                        pendingTiming: state.pendingSettings[setting],
                        status: status(for: setting))
    }

    /// The Station Tuner controls in display order (connections live in `ConnectionsModel`).
    var tunerRows: [StationTunerRow] { StationSetting.tuning.map(tunerRow(for:)) }
}
