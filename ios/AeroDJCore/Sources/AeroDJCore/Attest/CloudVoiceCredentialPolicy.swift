import Foundation

/// The tester cloud voice (#378): internal TestFlight builds get the ElevenLabs voice through an
/// App Attest install token, with no owner token. Compiled in only with the Swift condition
/// `AERODJ_TESTER_VOICE` (testflight.yml `tester_voice: true`, internal TestFlight only).
/// Every other build compiles the `#else` branch, so an App Store build has no attested route
/// (`check-release-disables-paid-voice.sh` checks the marker).
public enum TesterVoice {
    #if AERODJ_TESTER_VOICE
    /// Found in the binary only when the flag is set (needle positive control).
    public static let buildMarker = "AERODJ_TESTER_VOICE_ATTEST_BUILD"
    public static let enabled = !buildMarker.isEmpty
    #else
    public static let enabled = false
    #endif

    /// The ElevenLabs voice a tester hears until a voice picker ships for testers: the saved
    /// selection if it is in the catalog, else the catalog's first voice (Nathan, the picker's lead).
    public static func voiceID(selected: String?) -> String? {
        if let selected, PremiumVoiceCatalog.index(ofVoiceID: selected) != nil { return selected }
        return PremiumVoiceCatalog.voices.first?.id
    }

    /// The proxy's base URL (same pinned host as the owner route); `/api/tts` and `/api/attest/*`.
    public static let baseURL = URL(string: "https://aerodj-tts.vercel.app")!
    public static var ttsEndpoint: URL { baseURL.appendingPathComponent("api/tts") }
}

/// Which credential the ElevenLabs proxy route uses in this build. Owner first: wherever the
/// owner-token path applies today (an `AERODJ_OWNER_AB` build), it is used unchanged and the
/// attested path is not composed at all. Neither is a fallback for the other (#378 §3).
public enum CloudVoiceCredentialPolicy {
    public enum Route: Equatable, Sendable {
        /// Today's owner A/B route: Keychain owner token, unchanged.
        case ownerToken
        /// App Attest install token (tester builds on a supported device).
        case installToken
        case onDeviceOnly(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        /// Not an owner A/B or tester build (App Store, Debug, Release).
        case notTesterBuild
        /// `DCAppAttestService.isSupported == false`, including the simulator.
        case attestUnsupported
    }

    public static func resolve(ownerABBuild: Bool, testerVoiceBuild: Bool, attestSupported: Bool) -> Route {
        if ownerABBuild { return .ownerToken }
        guard testerVoiceBuild else { return .onDeviceOnly(.notTesterBuild) }
        guard attestSupported else { return .onDeviceOnly(.attestUnsupported) }
        return .installToken
    }
}
