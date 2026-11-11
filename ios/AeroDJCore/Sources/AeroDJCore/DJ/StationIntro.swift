import Foundation

/// Facts a station-start intro may speak (#442). The caller passes the station it is
/// starting: a built-in, a library station, one the listener created, or the station a
/// mid-song switch landed on. `id` is how a later start tells them apart.
public struct StationIntroFacts: Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var seeds: [StationSeed]

    public init(id: String, name: String, description: String? = nil, seeds: [StationSeed] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.seeds = seeds
    }
}

/// The station intro (#442). One break, rendered by the session's existing
/// `DJBreakPreparer` and `VoiceRenderer`. No scheduler and no speech path of its own.
/// Spoken text is only the station name, its description, and its seed names.
public enum StationIntro {
    /// Not a song boundary. Song breaks are numbered from 0.
    public static let afterTrack = -1

    struct Planned {
        var djBreak: DJBreak
        /// Library seeds, or a station name other than the built-in brand, stay on device.
        var onDeviceOnly: Bool
    }

    /// A break whose cue texts are station facts, trimmed to `capSeconds`. Nil when
    /// nothing true can be said, or when the first fact alone does not fit the cap.
    static func planned(from facts: StationIntroFacts, capSeconds: Int) -> Planned? {
        var lines: [(text: String, attribution: SpokenAttribution)] = []
        if let name = speakable(facts.name) {
            let attribution: SpokenAttribution = name == DJScriptWriter.builtInStationName ? .presenter : .stationName
            lines.append((name, attribution))
        }
        if let description = facts.description.flatMap(speakable), lines.last?.text != description {
            lines.append((description, .stationName))
        }
        for seed in facts.seeds {
            guard let normalized = seed.normalized(), let text = speakable(normalized.name) else { continue }
            guard !lines.contains(where: { $0.text == text }) else { continue }
            let origin: TrackOrigin = normalized.source == .catalog ? .catalog : .library
            lines.append((text, .trackMetadata(trackIDs: [normalized.catalogID], origin: origin)))
        }

        let cap = max(0, capSeconds)
        var kept: [(text: String, attribution: SpokenAttribution)] = []
        var seconds = 0
        for line in lines {
            let estimate = DefaultBriefingPlanner.estimatedSpokenSeconds(for: line.text)
            guard estimate > 0, seconds + estimate <= cap else { break }
            kept.append(line)
            seconds += estimate
        }
        guard !kept.isEmpty else { return nil }

        var cues: [NarrationCue] = []
        var attributions: [UUID: SpokenAttribution] = [:]
        for (index, line) in kept.enumerated() {
            let estimate = DefaultBriefingPlanner.estimatedSpokenSeconds(for: line.text)
            let cue = NarrationCue(id: UUID(), order: index, group: -1, kind: .transition, text: line.text,
                                   estimatedSeconds: estimate, maxSeconds: max(8, estimate * 2),
                                   sourceItemID: nil, source: nil, provenance: nil)
            cues.append(cue)
            attributions[cue.id] = line.attribution
        }
        var djBreak = DJBreak(afterTrack: afterTrack, cues: cues, attributions: attributions)
        // The existing opener cap. No talk-over closing line: this break must not land on a song.
        djBreak.shape = .showOpener
        djBreak.talkOverCueID = nil
        let onDevice = facts.seeds.contains { $0.source == .library }
            || attributions.values.contains { if case .stationName = $0 { true } else { false } }
        return Planned(djBreak: djBreak, onDeviceOnly: onDevice)
    }

    /// Non-empty, short, and not an instruction. The same screen the station-name lines use.
    static func speakable(_ raw: String) -> String? {
        EditorialStationName.usable(raw)
    }
}
