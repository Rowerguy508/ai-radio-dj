import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

private struct StubDeviceProvider: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data([1, 2, 3]), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private struct StubProxyTransport: HTTPTransport {
    let status: Int
    let headers: [String: String]
    let calls = CallCount()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await calls.bump(voiceID: Self.voiceID(request))
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    static func voiceID(_ request: URLRequest) -> String? {
        guard let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: String] else { return nil }
        return json["voiceId"]
    }
    static let ok = ["Content-Type": "audio/wav", "X-Audio-Duration": "3.0", "X-Billed-Characters": "20"]
}

private actor CallCount {
    var count = 0
    var voiceIDs: [String?] = []
    func bump(voiceID: String?) { count += 1; voiceIDs.append(voiceID) }
}

final class PremiumVoicePickerTests: XCTestCase {
    private let brian = "nPczCjzI2devNBz1zQrb"
    private let jessica = "cgSgspJ2msm6clMCkdW9"
    private let creds = PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!,
                                                token: "owner-test-token")

    private func device() -> [VoiceRoute] {
        [VoiceRoute(providerID: "device", provider: StubDeviceProvider(), voice: VoiceProfile(id: "host", name: "Host"))]
    }

    private func freshDefaults() -> UserDefaults {
        let name = "PremiumVoicePickerTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func cue(_ text: String = "That was Song 1.") -> NarrationCue {
        NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: text, estimatedSeconds: 2,
                     maxSeconds: 12, sourceItemID: nil, source: nil, provenance: nil)
    }

    // MARK: Catalog

    func testCatalogHasExactlyTheFourOwnerApprovedVoices() {
        XCTAssertEqual(PremiumVoiceCatalog.voices.map(\.id),
                       ["nPczCjzI2devNBz1zQrb", "TX3LPaxmHKxFdv7VOQHJ", "EXAVITQu4vr4xnSDxMaL", "cgSgspJ2msm6clMCkdW9"])
        XCTAssertEqual(PremiumVoiceCatalog.voices.map(\.displayName), ["Brian", "Liam", "Sarah", "Jessica"])
        XCTAssertEqual(Set(PremiumVoiceCatalog.voices.map(\.upstream)), [.elevenlabs])
        XCTAssertEqual(PremiumVoiceCatalog.allowlistCSV,
                       "nPczCjzI2devNBz1zQrb,TX3LPaxmHKxFdv7VOQHJ,EXAVITQu4vr4xnSDxMaL,cgSgspJ2msm6clMCkdW9")
    }

    // MARK: Selection store

    func testSelectionPersistsOnlyAKnownVoiceID() {
        let d = freshDefaults()
        let store = PremiumVoiceSelectionStore(defaults: d)
        XCTAssertNil(store.selectedVoiceID)
        store.select(jessica)
        XCTAssertEqual(PremiumVoiceSelectionStore(defaults: d).selectedVoiceID, jessica, "survives a new store")
        store.select("not-in-catalog")
        XCTAssertEqual(store.selectedVoiceID, jessica, "unknown ids are ignored")
        d.set("tampered", forKey: PremiumVoiceSelectionStore.key)
        XCTAssertNil(store.selectedVoiceID, "an unknown stored id reads as none")
        store.select(nil)
        XCTAssertNil(d.object(forKey: PremiumVoiceSelectionStore.key))
        XCTAssertEqual(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("AeroDJ.premiumVoice") },
                       [], "nothing else is stored")
    }

    // MARK: Gate (default off; Release needle)

    func testPaidProvidersOffByDefault() {
        XCTAssertFalse(BetaVoicePolicy.paidProvidersEnabled)
        XCTAssertFalse(OwnerVoiceTrial.paidProvidersEnabled(defaults: freshDefaults()))
    }

    #if DEBUG
    func testDebugOwnerToggleEnablesGate() {
        let d = freshDefaults()
        d.set(true, forKey: OwnerVoiceTrial.paidProvidersDefaultsKey)
        XCTAssertTrue(OwnerVoiceTrial.paidProvidersEnabled(defaults: d))
    }
    #else
    /// Release needle: runs under `swift test -c release` (check-release-disables-paid-voice.sh).
    func testReleaseNeverEnablesPaidProviders() {
        let d = freshDefaults()
        d.set(true, forKey: "AeroDJPaidProvidersEnabled")
        XCTAssertFalse(OwnerVoiceTrial.buildAllowsPaidProviders)
        XCTAssertFalse(OwnerVoiceTrial.paidProvidersEnabled(defaults: d))
    }
    #endif

    // MARK: Route ordering and omission

    func testEnabledWithSelectionPutsElevenLabsFirstThenOnDevice() {
        let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: jessica,
                                           credentials: creds)
        XCTAssertEqual(c.routes.map(\.providerID), ["elevenlabs", "device"])
        XCTAssertEqual(c.routes.first?.voice.id, jessica)
        XCTAssertEqual(c.routes.first?.acceptsSSML, false)
        XCTAssertEqual(c.routes.first?.isPaid, false, "app-side $0 budget is not consumed; cap is server-side")
        XCTAssertEqual(c.decision, .included(catalogIndex: 3))
    }

    func testOmittedWhenDisabledUnselectedOrWithoutToken() {
        let cases: [(Bool, String?, PremiumProxyCredentials?, PremiumVoiceRoutes.OmitReason)] = [
            (false, jessica, creds, .paidDisabled),
            (true, nil, creds, .noSelection),
            (true, "unknown", creds, .unknownVoice),
            (true, jessica, nil, .noCredentials),
            (true, jessica, PremiumProxyCredentials(endpoint: creds.endpoint, token: "  \n"), .emptyToken),
            (true, jessica, PremiumProxyCredentials(endpoint: URL(string: "http://aerodj-tts.vercel.app/api/tts")!,
                                                    token: "t"), .endpointNotAllowed),
            (true, jessica, PremiumProxyCredentials(endpoint: URL(string: "https://evil.example/api/tts")!,
                                                    token: "t"), .endpointNotAllowed),
            (true, jessica, PremiumProxyCredentials(endpoint: URL(string: "https://vercel.app/api/tts")!,
                                                    token: "t"), .endpointNotAllowed),
        ]
        for (enabled, voice, credentials, reason) in cases {
            let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: enabled,
                                               selectedVoiceID: voice, credentials: credentials)
            XCTAssertEqual(c.routes.map(\.providerID), ["device"], "\(reason)")
            XCTAssertEqual(c.decision, .omitted(reason))
        }
    }

    // MARK: Cache key per voice

    func testCacheKeyDiffersPerVoiceID() {
        let routes = PremiumVoiceCatalog.voices.map {
            PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: $0.id,
                                       credentials: creds).routes[0]
        }
        let keys = routes.map { VoiceRenderer.cacheKey(text: "Same line.", route: $0) }
        XCTAssertEqual(Set(keys).count, 4)
        XCTAssertFalse(keys.contains(VoiceRenderer.cacheKey(text: "Same line.", route: device()[0])))
    }

    // MARK: Rendering through the existing chain

    func testProxySuccessRendersSelectedVoiceThroughExistingRenderer() async {
        let transport = StubProxyTransport(status: 200, headers: StubProxyTransport.ok)
        let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: brian,
                                           credentials: creds, transport: transport)
        let renderer = VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache())
        guard case .success(let clip) = await renderer.render(cue(), userID: "u", stationID: "s") else {
            return XCTFail("proxy route should render")
        }
        XCTAssertEqual(clip.audio.providerID, "elevenlabs")
        XCTAssertEqual(clip.audio.voiceID, brian)
        let ids = await transport.calls.voiceIDs
        XCTAssertEqual(ids, [brian])
    }

    func testProxyFailureFallsBackToOnDevice() async {
        for (status, headers) in [(502, ["Content-Type": "application/json"]),
                                  (401, ["Content-Type": "application/json"]),
                                  (200, ["Content-Type": "audio/wav"])] {  // missing duration
            let transport = StubProxyTransport(status: status, headers: headers)
            let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: brian,
                                               credentials: creds, transport: transport)
            let renderer = VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0),
                                         cache: InMemoryAudioCache())
            guard case .success(let clip) = await renderer.render(cue(), userID: "u", stationID: "s") else {
                return XCTFail("on-device must rescue status \(status)")
            }
            XCTAssertEqual(clip.audio.providerID, "device")
            XCTAssertEqual(clip.attempts.map(\.providerID), ["elevenlabs", "device"])
            let count = await transport.calls.count
            XCTAssertEqual(count, 1)
        }
    }

    func testOverDurationProxyClipFallsBackToOnDevice() async {
        var headers = StubProxyTransport.ok
        headers["X-Audio-Duration"] = "30"
        let transport = StubProxyTransport(status: 200, headers: headers)
        let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: brian,
                                           credentials: creds, transport: transport)
        let renderer = VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache())
        guard case .success(let clip) = await renderer.render(cue(), userID: "u", stationID: "s") else {
            return XCTFail("on-device must rescue an over-cap clip")
        }
        XCTAssertEqual(clip.audio.providerID, "device")
    }

    // MARK: Captions

    func testElevenLabsCaptionsAreWholeLine() {
        XCTAssertFalse(PremiumVoiceRoutes.hasWordTimings(providerID: PremiumVoiceRoutes.providerID))
    }
}
