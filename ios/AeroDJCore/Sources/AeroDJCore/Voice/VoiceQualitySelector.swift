import Foundation

/// How good an installed on-device voice is, in the order Apple ranks them.
/// Logged as this enum only, never a voice name, identifier or language.
public enum VoiceQualityTier: String, Comparable, Sendable, CaseIterable {
    case standard, enhanced, premium

    private var rank: Int {
        switch self {
        case .standard: 0
        case .enhanced: 1
        case .premium: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// One installed voice, reduced to the fields the choice needs. The app maps
/// `AVSpeechSynthesisVoice` onto this so the ranking is testable on Linux.
public struct VoiceCandidate: Equatable, Sendable {
    public let identifier: String
    public let language: String
    public let tier: VoiceQualityTier
    public let isNovelty: Bool
    public let isPersonalVoice: Bool

    public init(identifier: String, language: String, tier: VoiceQualityTier,
                isNovelty: Bool = false, isPersonalVoice: Bool = false) {
        self.identifier = identifier
        self.language = language
        self.tier = tier
        self.isNovelty = isNovelty
        self.isPersonalVoice = isPersonalVoice
    }
}

/// Picks the on-device DJ voice. The compact default `en-US` voice is the most robotic
/// one on the phone, so the best installed English voice wins instead.
///
/// Order: quality tier first (a premium en-GB voice beats a standard en-US one), then
/// the exact preferred language, then any English, then identifier for a stable pick.
/// Novelty voices and the user's Personal Voice are never used.
public enum VoiceQualitySelector {
    public static func best(from candidates: [VoiceCandidate], preferredLanguage: String = "en-US") -> VoiceCandidate? {
        let preferredFamily = languageFamily(preferredLanguage)
        let eligible = candidates.filter {
            !$0.isNovelty && !$0.isPersonalVoice && languageFamily($0.language) == preferredFamily
        }
        return eligible.min { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            let aExact = a.language == preferredLanguage, bExact = b.language == preferredLanguage
            if aExact != bExact { return aExact }
            return a.identifier < b.identifier
        }
    }

    /// The retry voice when a higher-tier voice renders nothing: the best standard-tier
    /// voice, which ships with iOS and needs no download. Nil when none is installed.
    public static func fallback(from candidates: [VoiceCandidate], preferredLanguage: String = "en-US") -> VoiceCandidate? {
        best(from: candidates.filter { $0.tier == .standard }, preferredLanguage: preferredLanguage)
    }

    private static func languageFamily(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}
