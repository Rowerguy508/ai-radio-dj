import XCTest
@testable import AeroDJCore

/// #625 (-Echo): the local weather and news prompt discloses Apple geocoding in every build and
/// makes no claim a build cannot back (privacy.md, #624). Every flag combination, on Linux.
final class LocalAreaConsentCopyBuildTests: XCTestCase {
    private let geocoding = "Apple's geocoding service gets your approximate location, rounded, or the city or ZIP you type"
    private let weather = "Apple Weather gets an approximate point"
    private let newsSource = "sent to the news source"
    private let voice = "voice service"
    private let cloud = "cloud voice"

    private var everyFlagState: [(ownerAB: Bool, testerVoice: Bool)] {
        [(false, false), (true, false), (false, true), (true, true)]
    }

    func testEveryBuildDisclosesGeocodingAndWeather() {
        for f in everyFlagState {
            let body = LocalAreaConsentCopy.body(for: .flags(ownerAB: f.ownerAB, testerVoice: f.testerVoice))
            XCTAssertTrue(body.contains(geocoding), "\(f)")
            XCTAssertTrue(body.contains(weather), "\(f)")
            XCTAssertTrue(body.contains("only, while the app is open"), "\(f)")
        }
    }

    /// The flag mapping is the providers' own: GDELT is `AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB`
    /// (`TesterLocalNews`), the cloud voice either flag (`CloudVoiceConsentPrompt`).
    func testFlagMappingMatchesTheProviders() {
        XCTAssertEqual(LocalAreaConsentCopy.Build.flags(ownerAB: false, testerVoice: false), .appStore)
        XCTAssertEqual(LocalAreaConsentCopy.Build.flags(ownerAB: true, testerVoice: false), .ownerAB)
        XCTAssertEqual(LocalAreaConsentCopy.Build.flags(ownerAB: false, testerVoice: true), .tester)
        XCTAssertEqual(LocalAreaConsentCopy.Build.flags(ownerAB: true, testerVoice: true), .ownerAB)
        for f in everyFlagState {
            XCTAssertEqual(CloudVoiceConsentPrompt.isCloudVoiceOffered(ownerABBuild: f.ownerAB, testerVoiceBuild: f.testerVoice,
                                                                       paidProvidersEnabled: f.ownerAB, selectedVoiceID: "v"),
                           LocalAreaConsentCopy.Build.flags(ownerAB: f.ownerAB, testerVoice: f.testerVoice).cloudVoice, "\(f)")
        }
    }

    func testAppStoreBuildClaimsNoNewsSourceAndNoVoice() {
        let body = LocalAreaConsentCopy.body(for: .appStore)
        XCTAssertFalse(body.contains(newsSource))
        XCTAssertFalse(body.contains("headline"))
        XCTAssertFalse(body.contains(voice))
        XCTAssertFalse(body.contains(cloud))
    }

    func testOwnerABBuildHasTheVoiceButNoNewsSource() {
        let body = LocalAreaConsentCopy.body(for: .ownerAB)
        XCTAssertFalse(body.contains(newsSource))
        XCTAssertFalse(body.contains("headline"))
        XCTAssertFalse(body.contains("news lines"))
        XCTAssertTrue(body.contains("Your coordinates and your location itself are never sent to the voice service."))
        XCTAssertTrue(body.contains("the words of weather lines are sent to it"))
    }

    func testTesterBuildNamesTheNewsSourceAndTheVoice() {
        let body = LocalAreaConsentCopy.body(for: .tester)
        XCTAssertTrue(body.contains("Your city or region is sent to the news source"))
        XCTAssertTrue(body.contains("weather and headlines"))
        XCTAssertTrue(body.contains("Your coordinates and your location itself are never sent to the voice service."))
        XCTAssertTrue(body.contains("a local headline can name your city or area"))
    }

    /// The app view reads `LocalAreaConsentCopy.body`, which is this module's build. Linux tests
    /// compile neither flag, so it is the App Store copy here.
    func testBodyIsThisBuildsCopy() {
        XCTAssertEqual(LocalAreaConsentCopy.body, LocalAreaConsentCopy.body(for: .current))
        XCTAssertEqual(LocalAreaConsentCopy.Build.current,
                       .flags(ownerAB: OwnerVoiceTrial.paidProvidersEnabled, testerVoice: TesterVoice.enabled))
        #if !AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
        XCTAssertEqual(LocalAreaConsentCopy.Build.current, .appStore)
        #endif
    }

    /// Never a coordinate, ZIP or street claimed as sent to news; no precise-location wording.
    func testNoBuildClaimsPreciseLocationOrBackgroundUse() {
        for build in [LocalAreaConsentCopy.Build.appStore, .ownerAB, .tester] {
            let body = LocalAreaConsentCopy.body(for: build).lowercased()
            XCTAssertFalse(body.contains("precise"))
            XCTAssertFalse(body.contains("background"))
            XCTAssertFalse(body.contains("always"))
        }
    }
}
