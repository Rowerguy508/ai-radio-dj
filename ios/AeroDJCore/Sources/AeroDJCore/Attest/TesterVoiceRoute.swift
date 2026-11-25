import Foundation

/// The attested ElevenLabs route for internal TestFlight testers (#378, -Atlas). Same proxy host,
/// same `ProxyVoiceProvider`, same `VoiceRenderer` fallback chain as the owner route; only the
/// credential differs (an App Attest install token, `X-OnAirly-Install-Token`).
///
/// - The route is `leavesDevice: true`, so `VoiceRenderer` skips it for any line without
///   `mayLeaveDevice` under the renderer's `cloudScope` (#433): `.noLines` (nothing is sent)
///   until cloud-voice copy v2 is accepted, then `.allLines`: every attributed line, personal
///   briefing items, library songs, typed station names, news and weather included, as the v2
///   sheet says. Unattributed lines stay on the device.
/// - Consent is checked per request by the token source before any network call: until the
///   sheet is accepted every cue goes on-device and nothing is sent.
/// - Priced at 0 µ$ like the owner route: spend is capped server-side (#378 §2: per-install,
///   tester-tier and global daily caps, the ElevenLabs key's own cap), so the app's VoiceBudget is unchanged.
extension PremiumVoiceRoutes {
    public enum AttestedOmitReason: String, Equatable, Sendable {
        case ownerPathApplies, notTesterBuild, attestUnsupported, unknownVoice, endpointNotAllowed
    }

    public enum AttestedDecision: Equatable, Sendable {
        case included(catalogIndex: Int)
        case omitted(AttestedOmitReason)
    }

    public struct AttestedComposition: Sendable {
        public let routes: [VoiceRoute]
        public let decision: AttestedDecision
    }

    /// `[ElevenLabs(voice) via install token] + onDevice` only when `CloudVoiceCredentialPolicy`
    /// says `.installToken`; otherwise `onDevice` unchanged. An owner A/B build always gets
    /// `.omitted(.ownerPathApplies)`: the owner-token composition stays the only one there.
    public static func composeAttested(onDevice: [VoiceRoute], route policyRoute: CloudVoiceCredentialPolicy.Route,
                                       voiceID: String?, endpoint: URL = TesterVoice.ttsEndpoint,
                                       tokens: any InstallTokenProviding,
                                       pinnedHosts: Set<String> = allowedHosts,
                                       transport: any HTTPTransport = URLSessionTransport(),
                                       backoff: PaidVoiceBackoff?) -> AttestedComposition {
        func omit(_ reason: AttestedOmitReason) -> AttestedComposition {
            AttestedComposition(routes: onDevice, decision: .omitted(reason))
        }
        switch policyRoute {
        case .ownerToken: return omit(.ownerPathApplies)
        case .onDeviceOnly(.notTesterBuild): return omit(.notTesterBuild)
        case .onDeviceOnly(.attestUnsupported): return omit(.attestUnsupported)
        case .installToken: break
        }
        guard let voiceID, let index = PremiumVoiceCatalog.index(ofVoiceID: voiceID) else { return omit(.unknownVoice) }
        guard let host = endpoint.host?.lowercased(), isAllowed(host: host, pinned: pinnedHosts),
              let configuration = try? ProxyVoiceProvider.Configuration(endpoint: endpoint, allowedHosts: [host],
                                                                        upstream: .elevenlabs, installTokens: tokens)
        else { return omit(.endpointNotAllowed) }
        let option = PremiumVoiceCatalog.voices[index]
        let route = VoiceRoute(providerID: providerID,
                               provider: ProxyVoiceProvider(configuration: configuration, transport: transport,
                                                            backoff: backoff),
                               voice: VoiceProfile(id: option.id, name: option.displayName),
                               microdollarsPerThousandCharacters: 0, timeout: timeout, acceptsSSML: false,
                               leavesDevice: true,
                               // Same stitching context as the owner ElevenLabs route. The per-cue
                               // check still decides which lines may be context (#365).
                               sendsSpeechContext: true, supportsAudioTags: false)
        return AttestedComposition(routes: [route] + onDevice, decision: .included(catalogIndex: index))
    }
}
