import Foundation

/// One installed on-device voice, as the inventory sees it. The app maps `AVSpeechSynthesisVoice`
/// onto this (see `AVSpeechVoiceProvider`), so everything built on it is testable on Linux.
///
/// Privacy: `name` and `identifier` identify what the user has installed. They are for local
/// choice only and are never logged, cached or sent anywhere; log `tier` instead.
public struct OnDeviceVoice: Equatable, Sendable, Identifiable {
    public let identifier: String
    public let name: String
    public let language: String
    public let tier: VoiceQualityTier
    public let isNovelty: Bool
    public let isPersonalVoice: Bool

    public var id: String { identifier }

    public init(identifier: String, name: String, language: String, tier: VoiceQualityTier,
                isNovelty: Bool = false, isPersonalVoice: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.tier = tier
        self.isNovelty = isNovelty
        self.isPersonalVoice = isPersonalVoice
    }

    /// The DJ may use this voice. Novelty voices and the user's Personal Voice never qualify,
    /// the same rule `VoiceQualitySelector` applies.
    public var isSelectable: Bool { !isNovelty && !isPersonalVoice }

    /// The reduced form `VoiceQualitySelector` ranks.
    public var candidate: VoiceCandidate {
        VoiceCandidate(identifier: identifier, language: language, tier: tier,
                       isNovelty: isNovelty, isPersonalVoice: isPersonalVoice)
    }
}

/// Where the list of installed voices comes from. The real one wraps AVFoundation; tests inject a list.
public protocol OnDeviceVoiceProviding: Sendable {
    func installedVoices() -> [OnDeviceVoice]
}

/// A fixed list, for tests, previews and the Linux build.
public struct StaticOnDeviceVoiceProvider: OnDeviceVoiceProviding {
    private let voices: [OnDeviceVoice]
    public init(_ voices: [OnDeviceVoice]) { self.voices = voices }
    public func installedVoices() -> [OnDeviceVoice] { voices }
}

/// A snapshot of the voices installed on this device, for voice preferences and for the DJ's pick.
///
/// Pure data: building one never speaks, never loads audio and never touches the network, so a
/// preferences screen can read it without any effect on playback. The snapshot is ordered
/// deterministically (best tier first, then language, name, identifier) with duplicate identifiers
/// dropped, so a list built from it does not reshuffle between reads.
public struct OnDeviceVoiceInventory: Equatable, Sendable {
    public let voices: [OnDeviceVoice]

    public init(voices: [OnDeviceVoice]) {
        var seen = Set<String>()
        let unique = voices.filter { seen.insert($0.identifier).inserted }
        self.voices = unique.sorted { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.language != b.language { return a.language < b.language }
            if a.name != b.name { return a.name < b.name }
            return a.identifier < b.identifier
        }
    }

    public init(provider: some OnDeviceVoiceProviding) {
        self.init(voices: provider.installedVoices())
    }

    /// Voices the DJ may use: no novelty voices, no Personal Voice.
    public var selectable: [OnDeviceVoice] { voices.filter(\.isSelectable) }

    /// Selectable voices whose language family matches `language` ("en" matches en-US and en-GB).
    public func selectable(inLanguageFamily language: String) -> [OnDeviceVoice] {
        let family = Self.languageFamily(language)
        return selectable.filter { Self.languageFamily($0.language) == family }
    }

    /// How many selectable voices each tier has. Safe to log: counts and tiers only.
    public var selectableTierCounts: [VoiceQualityTier: Int] {
        selectable.reduce(into: [:]) { $0[$1.tier, default: 0] += 1 }
    }

    public func voice(identifier: String) -> OnDeviceVoice? {
        voices.first { $0.identifier == identifier }
    }

    /// The DJ's automatic pick: `VoiceQualitySelector`'s rule, so there is one ranking.
    public func best(preferredLanguage: String = "en-US") -> OnDeviceVoice? {
        guard let pick = VoiceQualitySelector.best(from: voices.map(\.candidate), preferredLanguage: preferredLanguage)
        else { return nil }
        return voice(identifier: pick.identifier)
    }

    /// How `resolve` arrived at a voice.
    public enum Source: Equatable, Sendable {
        /// The saved preference is installed and usable.
        case preference
        /// No preference, or it is gone or no longer usable: the automatic pick.
        case automatic
    }

    public struct Resolution: Equatable, Sendable {
        public let voice: OnDeviceVoice
        public let source: Source
    }

    /// The voice to speak with. A saved `preferredIdentifier` wins only while that voice is still
    /// installed, selectable and in the DJ's language family; otherwise (removed in Settings,
    /// replaced by a novelty voice, wrong language) the automatic pick is used, so a stale
    /// preference can never silence the DJ. Nil only when no usable voice exists at all.
    public func resolve(preferredIdentifier: String?, preferredLanguage: String = "en-US") -> Resolution? {
        if let preferredIdentifier, let chosen = voice(identifier: preferredIdentifier), chosen.isSelectable,
           Self.languageFamily(chosen.language) == Self.languageFamily(preferredLanguage) {
            return Resolution(voice: chosen, source: .preference)
        }
        return best(preferredLanguage: preferredLanguage).map { Resolution(voice: $0, source: .automatic) }
    }

    static func languageFamily(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}
