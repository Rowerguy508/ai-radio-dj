import Foundation
import XCTest
@testable import AeroDJCore

struct FixedEntitlement: ProEntitlementProviding {
    let state: ProEntitlementState
    init(_ state: ProEntitlementState) { self.state = state }
    func currentProEntitlement() async -> ProEntitlementState { state }
}

struct FixedConsent: PaidVoiceConsentProviding {
    let granted: Bool
    init(_ granted: Bool) { self.granted = granted }
    func hasPaidVoiceConsent() async -> Bool { granted }
}

final class SwitchableConsent: PaidVoiceConsentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool
    init(_ granted: Bool) { self.granted = granted }
    func set(_ value: Bool) { lock.withLock { granted = value } }
    func hasPaidVoiceConsent() async -> Bool { lock.withLock { granted } }
}

/// Counts reads, to prove consent is asked first and a refusal never reads the entitlement.
final class CountingEntitlement: ProEntitlementProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let state: ProEntitlementState
    init(_ state: ProEntitlementState) { self.state = state }
    var reads: Int { lock.withLock { count } }
    func currentProEntitlement() async -> ProEntitlementState { lock.withLock { count += 1 }; return state }
}

extension ProVoiceAccess {
    static let proWithConsentForTests = ProVoiceAccess(
        entitlement: FixedEntitlement(.pro(productID: ProSubscriptionConfig.monthlyProductID, expiresAt: nil)),
        consent: FixedConsent(true))

    static func testing(_ state: ProEntitlementState, consent: Bool) -> ProVoiceAccess {
        ProVoiceAccess(entitlement: FixedEntitlement(state), consent: FixedConsent(consent))
    }
}

final class ProVoiceGateTests: XCTestCase {
    private let id = ProSubscriptionConfig.monthlyProductID
    private var epoch: Date { Date(timeIntervalSince1970: 0) }
    private var allStates: [ProEntitlementState] {
        [.free, .pro(productID: id, expiresAt: nil), .unverified(productID: id),
         .expired(productID: id, expiredAt: epoch), .revoked(productID: id, revokedAt: epoch)]
    }

    func testOnlyProWithConsentIsAllowed() {
        XCTAssertEqual(ProVoiceGate.decide(entitlement: .pro(productID: id, expiresAt: nil), paidVoiceConsent: true), .allowed)
        XCTAssertEqual(ProVoiceGate.decide(entitlement: .free, paidVoiceConsent: true), .denied(.notPro))
        XCTAssertEqual(ProVoiceGate.decide(entitlement: .unverified(productID: id), paidVoiceConsent: true), .denied(.unverified))
        XCTAssertEqual(ProVoiceGate.decide(entitlement: .expired(productID: id, expiredAt: epoch), paidVoiceConsent: true), .denied(.expired))
        XCTAssertEqual(ProVoiceGate.decide(entitlement: .revoked(productID: id, revokedAt: epoch), paidVoiceConsent: true), .denied(.revoked))
    }

    /// Consent first: no subscription state stands in for the consent sheet.
    func testWithoutConsentEveryStateIsDeniedForConsent() {
        for state in allStates {
            XCTAssertEqual(ProVoiceGate.decide(entitlement: state, paidVoiceConsent: false), .denied(.noConsent), "\(state)")
        }
    }

    func testOnlyAllowedAndOwnerTrialPermitPaidVoice() {
        XCTAssertTrue(ProVoiceGate.Decision.allowed.permitsPaidVoice)
        XCTAssertTrue(ProVoiceGate.Decision.ownerTrial.permitsPaidVoice)
        for denial in [ProVoiceGate.Denial.noConsent, .notPro, .unverified, .expired, .revoked] {
            XCTAssertFalse(ProVoiceGate.Decision.denied(denial).permitsPaidVoice, "\(denial)")
        }
    }

    func testAccessAsksConsentFirstAndNeverReadsTheEntitlementWithoutIt() async {
        let spy = CountingEntitlement(.pro(productID: id, expiresAt: nil))
        let refused = await ProVoiceAccess(entitlement: spy, consent: FixedConsent(false)).decision()
        XCTAssertEqual(refused, .denied(.noConsent))
        XCTAssertEqual(spy.reads, 0)
        let granted = await ProVoiceAccess(entitlement: spy, consent: FixedConsent(true)).decision()
        XCTAssertEqual(granted, .allowed)
        XCTAssertEqual(spy.reads, 1)
    }

    func testDefaultAccessIsFailClosed() async {
        let none = await ProVoiceAccess.none.decision()
        XCTAssertEqual(none, .denied(.noConsent))
        let free = await NoProEntitlement().currentProEntitlement()
        XCTAssertEqual(free, .free)
        let consent = await NoPaidVoiceConsent().hasPaidVoiceConsent()
        XCTAssertFalse(consent)
    }

    // MARK: the paid proxy route at setup

    private func device() -> [VoiceRoute] {
        [VoiceRoute(providerID: "avspeech", provider: DJFakeVoice(), voice: VoiceProfile(id: "d", name: "Host"))]
    }

    private func compose(_ access: ProVoiceGate.Decision) -> PremiumVoiceRoutes.Composition {
        PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, access: access,
                                   selectedVoiceID: PremiumVoiceCatalog.voices[0].id,
                                   credentials: PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!,
                                                                        token: "test-token"))
    }

    func testPaidRouteIsSetUpOnlyForProWithConsentOrTheOwnerTrial() {
        XCTAssertEqual(compose(.allowed).decision, .included(catalogIndex: 0))
        XCTAssertEqual(compose(.allowed).routes.first?.providerID, PremiumVoiceRoutes.providerID)
        XCTAssertEqual(compose(.ownerTrial).decision, .included(catalogIndex: 0))
    }

    func testFreeNoConsentUnverifiedExpiredOrRevokedGetNoPaidRoute() {
        for denial in [ProVoiceGate.Denial.noConsent, .notPro, .unverified, .expired, .revoked] {
            let c = compose(.denied(denial))
            XCTAssertEqual(c.decision, .omitted(.notEntitled), "\(denial)")
            XCTAssertEqual(c.routes.map(\.providerID), ["avspeech"], "on-device only for \(denial)")
            XCTAssertFalse(c.routes.contains { $0.leavesDevice })
        }
    }

    func testDisabledPaidProvidersStillWinOverAccess() {
        let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: false, access: .allowed,
                                           selectedVoiceID: PremiumVoiceCatalog.voices[0].id, credentials: nil)
        XCTAssertEqual(c.decision, .omitted(.paidDisabled))
    }
}
