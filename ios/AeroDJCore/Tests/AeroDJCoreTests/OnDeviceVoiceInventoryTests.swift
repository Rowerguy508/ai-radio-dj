import XCTest
@testable import AeroDJCore

private func v(_ id: String, _ lang: String = "en-US", _ tier: VoiceQualityTier = .standard, name: String? = nil,
               novelty: Bool = false, personal: Bool = false) -> OnDeviceVoice {
    OnDeviceVoice(identifier: id, name: name ?? id, language: lang, tier: tier, isNovelty: novelty, isPersonalVoice: personal)
}

final class OnDeviceVoiceInventoryTests: XCTestCase {
    func testSnapshotIsOrderedBestTierFirstAndDeduplicated() {
        let inv = OnDeviceVoiceInventory(voices: [
            v("b", "en-US", .standard), v("a", "en-US", .premium), v("c", "en-GB", .enhanced),
            v("a", "fr-FR", .standard),  // same identifier again: the first one wins
        ])
        XCTAssertEqual(inv.voices.map(\.identifier), ["a", "c", "b"])
        XCTAssertEqual(inv.voices.first?.language, "en-US")
    }

    func testOrderDoesNotDependOnProviderOrder() {
        let list = [v("x", "en-US", .enhanced, name: "Zed"), v("y", "en-US", .enhanced, name: "Amy"), v("z", "de-DE", .premium)]
        XCTAssertEqual(OnDeviceVoiceInventory(voices: list), OnDeviceVoiceInventory(voices: list.reversed()))
    }

    func testSelectableDropsNoveltyAndPersonalVoices() {
        let inv = OnDeviceVoiceInventory(voices: [
            v("bells", novelty: true), v("me", personal: true), v("plain"),
        ])
        XCTAssertEqual(inv.selectable.map(\.identifier), ["plain"])
        XCTAssertEqual(inv.voices.count, 3, "the inventory still lists them; only `selectable` filters")
    }

    func testLanguageFamilyFilterKeepsEnglishVariantsOnly() {
        let inv = OnDeviceVoiceInventory(voices: [v("us", "en-US"), v("gb", "en_GB"), v("fr", "fr-FR"), v("nov", "en-US", novelty: true)])
        XCTAssertEqual(Set(inv.selectable(inLanguageFamily: "en-AU").map(\.identifier)), ["us", "gb"])
    }

    func testTierCountsCoverSelectableVoicesOnly() {
        let inv = OnDeviceVoiceInventory(voices: [
            v("p1", "en-US", .premium), v("e1", "en-US", .enhanced), v("e2", "en-GB", .enhanced),
            v("pn", "en-US", .premium, novelty: true),
        ])
        XCTAssertEqual(inv.selectableTierCounts, [.premium: 1, .enhanced: 2])
    }

    func testBestAgreesWithVoiceQualitySelector() {
        let list = [v("s", "en-US", .standard), v("gb", "en-GB", .premium), v("us", "en-US", .enhanced),
                    v("me", "en-US", .premium, personal: true)]
        let inv = OnDeviceVoiceInventory(voices: list)
        XCTAssertEqual(inv.best()?.identifier, VoiceQualitySelector.best(from: list.map(\.candidate))?.identifier)
        XCTAssertEqual(inv.best()?.identifier, "gb")
    }

    func testBestIsNilWithNoUsableVoice() {
        XCTAssertNil(OnDeviceVoiceInventory(voices: []).best())
        XCTAssertNil(OnDeviceVoiceInventory(voices: [v("bells", novelty: true), v("fr", "fr-FR")]).best())
    }

    func testProviderIsInjectable() {
        let inv = OnDeviceVoiceInventory(provider: StaticOnDeviceVoiceProvider([v("only")]))
        XCTAssertEqual(inv.voices.map(\.identifier), ["only"])
    }

    // MARK: preference

    func testInstalledPreferenceWinsOverTheAutomaticPick() {
        let inv = OnDeviceVoiceInventory(voices: [v("best", "en-US", .premium), v("mine", "en-GB", .standard)])
        XCTAssertEqual(inv.resolve(preferredIdentifier: "mine"), .init(voice: v("mine", "en-GB", .standard), source: .preference))
    }

    func testMissingPreferenceFallsBackToAutomatic() {
        let inv = OnDeviceVoiceInventory(voices: [v("best", "en-US", .premium)])
        let r = inv.resolve(preferredIdentifier: "deleted-in-settings")
        XCTAssertEqual(r?.voice.identifier, "best")
        XCTAssertEqual(r?.source, .automatic)
        XCTAssertEqual(inv.resolve(preferredIdentifier: nil)?.source, .automatic)
    }

    func testPreferenceThatIsNoLongerUsableNeverSilencesTheDJ() {
        let inv = OnDeviceVoiceInventory(voices: [
            v("plain", "en-US", .standard), v("bells", "en-US", .premium, novelty: true),
            v("me", "en-US", .premium, personal: true), v("fr", "fr-FR", .premium),
        ])
        for stale in ["bells", "me", "fr"] {
            let r = inv.resolve(preferredIdentifier: stale)
            XCTAssertEqual(r?.voice.identifier, "plain", "\(stale)")
            XCTAssertEqual(r?.source, .automatic, "\(stale)")
        }
    }

    func testResolveIsNilOnlyWhenNothingIsUsable() {
        XCTAssertNil(OnDeviceVoiceInventory(voices: [v("bells", novelty: true)]).resolve(preferredIdentifier: "bells"))
    }
}
