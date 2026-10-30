import AeroDJCore
import Foundation
import OSLog

/// The live app's voice, in every build (-Echo, #174 blocker 9 split). The paid route and its
/// per-cue Pro + consent gate live here, outside `AERODJ_OWNER_AB`:
/// - owner A/B builds: the owner trial composition (`OwnerVoiceTrial+App.swift`, owner-only);
/// - every other build, App Store Release included: `PaidVoice.publicComposition`, which is
///   compiled OFF (`PublicPaidVoiceRoute.compiledIn == false`) until per-install attestation
///   (#233 PRs 3–4) provides `PaidVoiceInstallSessionProviding`. Until then it is the
///   on-device renderer with the fail-closed gate, and no owner credential is reachable.
extension PaidVoice {
    static func live() -> PaidVoice {
        let base = VoiceRenderer.onDeviceDefault()
        #if AERODJ_OWNER_AB
        let voice = ownerTrial(base: base)
        #else
        let voice = publicComposition(base: base, access: .live,
                                      selectedVoiceID: PremiumVoiceSelectionStore().selectedVoiceID,
                                      session: NoInstallSession())
        #endif
        #if AERODJ_PUBLIC_PAID_ROUTE
        PaidVoiceLog.build(PublicPaidVoiceRoute.buildMarker)   // keeps the needle in the binary (control)
        #endif
        PaidVoiceLog.decision(voice.decision, routeCount: voice.renderer.routes.count)
        return voice
    }
}

enum PaidVoiceLog {
    private static let log = Logger(subsystem: "com.aerodj.app", category: "speech")

    /// A fixed build code (no user data).
    static func build(_ code: String) {
        log.notice("voice.route build=\(code, privacy: .public)")
    }

    /// Type, code, catalog index and counts only: never text, voice names, URLs or tokens.
    static func decision(_ decision: PremiumVoiceRoutes.Decision, routeCount: Int) {
        switch decision {
        case .included(let index):
            log.notice("voice.route premium=included index=\(index, privacy: .public) routes=\(routeCount, privacy: .public)")
        case .omitted(let reason):
            log.notice("voice.route premium=omitted code=\(reason.rawValue, privacy: .public) routes=\(routeCount, privacy: .public)")
        }
    }
}
