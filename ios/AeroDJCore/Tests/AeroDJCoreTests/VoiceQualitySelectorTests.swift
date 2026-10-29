import XCTest
@testable import AeroDJCore

private func c(_ id: String, _ lang: String, _ tier: VoiceQualityTier,
               novelty: Bool = false, personal: Bool = false) -> VoiceCandidate {
    VoiceCandidate(identifier: id, language: lang, tier: tier, isNovelty: novelty, isPersonalVoice: personal)
}

private struct SilentVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data([1]), durationSeconds: 1, billableUnits: 0, provider: "avspeech", cacheKey: nil)
    }
}

final class VoiceQualitySelectorTests: XCTestCase {
    func testPremiumBeatsEnhancedBeatsStandard() {
        let all = [c("s", "en-US", .standard), c("p", "en-US", .premium), c("e", "en-US", .enhanced)]
        XCTAssertEqual(VoiceQualitySelector.best(from: all)?.identifier, "p")
        XCTAssertEqual(VoiceQualitySelector.best(from: all.filter { $0.tier != .premium })?.identifier, "e")
    }

    func testExactLanguageWinsAtTheSameTier() {
        let all = [c("gb", "en-GB", .enhanced), c("us", "en-US", .enhanced), c("au", "en-AU", .enhanced)]
        XCTAssertEqual(VoiceQualitySelector.best(from: all)?.identifier, "us")
    }

    func testTierComesBeforeLanguage() {
        let all = [c("us", "en-US", .standard), c("gb", "en-GB", .premium)]
        XCTAssertEqual(VoiceQualitySelector.best(from: all)?.identifier, "gb")
    }

    func testNoveltyAndPersonalVoiceAreNeverPicked() {
        let all = [c("bells", "en-US", .premium, novelty: true), c("me", "en-US", .premium, personal: true),
                   c("plain", "en-US", .standard)]
        XCTAssertEqual(VoiceQualitySelector.best(from: all)?.identifier, "plain")
    }

    func testNonEnglishVoicesAreIgnored() {
        let all = [c("fr", "fr-FR", .premium), c("us", "en-US", .standard)]
        XCTAssertEqual(VoiceQualitySelector.best(from: all)?.identifier, "us")
        XCTAssertNil(VoiceQualitySelector.best(from: [c("fr", "fr-FR", .premium)]))
    }

    func testEmptyListGivesNil() {
        XCTAssertNil(VoiceQualitySelector.best(from: []))
    }

    func testTiebreakIsStableWhateverTheOrder() {
        let a = c("com.a", "en-US", .premium), b = c("com.b", "en-US", .premium)
        XCTAssertEqual(VoiceQualitySelector.best(from: [a, b])?.identifier, "com.a")
        XCTAssertEqual(VoiceQualitySelector.best(from: [b, a])?.identifier, "com.a")
    }

    func testTierLogTokensAreFixed() {
        XCTAssertEqual(VoiceQualityTier.allCases.map(\.rawValue), ["standard", "enhanced", "premium"])
    }

    /// A voice change must re-render: cached audio from the old voice never airs.
    func testChangingVoiceChangesTheCacheKey() {
        let old = VoiceRoute(providerID: "avspeech", provider: SilentVoice(), voice: VoiceProfile(id: "compact", name: "Host"))
        let new = VoiceRoute(providerID: "avspeech", provider: SilentVoice(), voice: VoiceProfile(id: "premium", name: "Host"))
        XCTAssertNotEqual(VoiceRenderer.cacheKey(text: "Good morning", route: old),
                          VoiceRenderer.cacheKey(text: "Good morning", route: new))
    }
}
