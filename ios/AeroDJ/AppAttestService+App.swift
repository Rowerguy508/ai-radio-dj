import AeroDJCore
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif
#if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
import OSLog
#endif

/// `AppAttestDevice` over Apple's `DCAppAttestService` (#378, -Atlas). The only file that
/// imports DeviceCheck; all the logic it feeds (`InstallTokenSource`) is in AeroDJCore and is
/// Linux-tested with a fake device. Not exercised on a device or against real App Attest yet.
#if canImport(DeviceCheck)
struct DeviceCheckAppAttestDevice: AppAttestDevice {
    /// False on the simulator, on Macs running the iOS app without support, and on old devices.
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        do { return try await DCAppAttestService.shared.generateKey() } catch { throw Self.map(error) }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        do { return try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
        catch { throw Self.map(error) }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        do { return try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
        catch { throw Self.map(error) }
    }

    /// Codes only: the system error's text never reaches a log or a `VoiceRenderer` attempt.
    /// A build signed without the App Attest entitlement (every build except a tester_voice=true
    /// TestFlight archive, since the #378 entitlement split) fails the key calls here; that maps
    /// to `.unsupported` or `.failed`, which `InstallTokenSource` treats as stop-for-the-launch,
    /// so every cue stays on the on-device voice (pinned on Linux by
    /// testMissingAttestEntitlementFallsBackOnDeviceAndStops).
    static func map(_ error: Error) -> AppAttestDeviceError {
        if error is CancellationError { return .failed }
        guard let error = error as? DCError else { return .failed }
        switch error.code {
        case .featureUnsupported: return .unsupported
        case .invalidKey: return .invalidKey
        case .serverUnavailable: return .serverUnavailable
        default: return .failed  // invalidInput, unknownSystemFailure, future codes
        }
    }
}
#endif

#if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
/// Internal TestFlight tester build (`AERODJ_TESTER_VOICE`): the ElevenLabs voice through an
/// App Attest install token, after the one-time consent sheet. Owner A/B builds never compile
/// this (the owner-token path stays the only paid route there).
enum TesterCloudVoice {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "speech")

    /// The existing cloud-voice consent store (Nova, #258): the same stored answer as its sheet
    /// and Tune toggle. Read before every token request, so a decline applies to the next cue.
    static let consentStore = CloudVoiceConsentStore()
    static let consent = TesterVoiceConsentReader(consentStore)
    /// Its own persisted backoff, so a tester 429 never touches the owner route's state.
    static let backoff = PaidVoiceBackoff(store: UserDefaultsPaidVoiceBackoffStore(key: "voice.paidBackoff.tester.v1"))

    #if canImport(DeviceCheck)
    private static let device: any AppAttestDevice = DeviceCheckAppAttestDevice()
    #else
    private static let device: any AppAttestDevice = UnsupportedAppAttestDevice()
    #endif

    static var attestSupported: Bool { device.isSupported }

    /// nil when either client refuses the base URL (not HTTPS on the pinned host).
    static let tokens: InstallTokenSource? = {
        let transport = URLSessionTransport()
        guard let attest = AttestClient(baseURL: TesterVoice.baseURL, transport: transport,
                                        installID: .shared),
              let mint = InstallTokenClient(baseURL: TesterVoice.baseURL, transport: transport) else { return nil }
        return InstallTokenSource(device: device, keyStore: KeychainAttestKeyIDStorage(), attest: attest,
                                  tokens: mint, consent: consent, backoff: backoff,
                                  log: { entry in
                                      // Event, outcome code and status only (never a token, key ID or challenge).
                                      log.notice("voice.attest event=\(entry.event.rawValue, privacy: .public) outcome=\(entry.outcome, privacy: .public) status=\(entry.status ?? 0, privacy: .public)")
                                  })
    }()

    static func compose(onDevice: [VoiceRoute]) -> [VoiceRoute] {
        let policy = CloudVoiceCredentialPolicy.resolve(ownerABBuild: false, testerVoiceBuild: TesterVoice.enabled,
                                                        attestSupported: attestSupported)
        guard let tokens else {
            log.notice("voice.route tester=omitted code=clientConfig routes=\(onDevice.count, privacy: .public)")
            return onDevice
        }
        let composition = PremiumVoiceRoutes.composeAttested(
            onDevice: onDevice, route: policy,
            voiceID: TesterVoice.voiceID(selected: PremiumVoiceSelectionStore().selectedVoiceID),
            tokens: tokens, backoff: backoff)
        switch composition.decision {
        case .included(let index):
            log.notice("voice.route tester=included index=\(index, privacy: .public) routes=\(composition.routes.count, privacy: .public)")
            // Background only, and a no-op without consent: the first break never waits on it.
            Task.detached(priority: .utility) { await tokens.prepare() }
        case .omitted(let reason):
            log.notice("voice.route tester=omitted code=\(reason.rawValue, privacy: .public) routes=\(composition.routes.count, privacy: .public)")
        }
        return composition.routes
    }
}
#endif
