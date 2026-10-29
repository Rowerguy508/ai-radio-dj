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
    private let sawyer = "8dEUmyPMdDdK91vboYih"
    private let jade = "g7LVvkPWALzPxOQbF6OE"
    private let pinned: Set<String> = ["aerodj-tts.vercel.app"]
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
                       ["8dEUmyPMdDdK91vboYih", "ktkP7Nsj67dw2zcplQYt", "OZ0L6eISlOejga3XjDFt", "g7LVvkPWALzPxOQbF6OE"])
        XCTAssertEqual(PremiumVoiceCatalog.voices.map(\.displayName), ["Sawyer", "Lawrence", "Talia", "Jade"])
        XCTAssertEqual(Set(PremiumVoiceCatalog.voices.map(\.upstream)), [.elevenlabs])
        XCTAssertEqual(PremiumVoiceCatalog.allowlistCSV,
                       "8dEUmyPMdDdK91vboYih,ktkP7Nsj67dw2zcplQYt,OZ0L6eISlOejga3XjDFt,g7LVvkPWALzPxOQbF6OE")
    }

    // MARK: Selection store

    func testSelectionPersistsOnlyAKnownVoiceID() {
        let d = freshDefaults()
        let store = PremiumVoiceSelectionStore(defaults: d)
        XCTAssertNil(store.selectedVoiceID)
        store.select(jade)
        XCTAssertEqual(PremiumVoiceSelectionStore(defaults: d).selectedVoiceID, jade, "survives a new store")
        store.select("not-in-catalog")
        XCTAssertEqual(store.selectedVoiceID, jade, "unknown ids are ignored")
        d.set("tampered", forKey: PremiumVoiceSelectionStore.key)
        XCTAssertNil(store.selectedVoiceID, "an unknown stored id reads as none")
        store.select(nil)
        XCTAssertNil(d.object(forKey: PremiumVoiceSelectionStore.key))
        XCTAssertEqual(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("AeroDJ.premiumVoice") },
                       [], "nothing else is stored")
    }

    // MARK: Gate (default off; Release needle)

    func testBetaDefaultStaysOff() {
        XCTAssertFalse(BetaVoicePolicy.paidProvidersEnabled)
    }

    #if AERODJ_OWNER_AB
    /// Only in an owner A/B build (`-DAERODJ_OWNER_AB`, check-release-disables-paid-voice.sh).
    func testOwnerABBuildEnablesGate() {
        XCTAssertTrue(OwnerVoiceTrial.paidProvidersEnabled)
        XCTAssertEqual(OwnerVoiceTrial.buildMarker, "AERODJ_OWNER_AB_VOICE_TRIAL_BUILD")
    }
    #else
    /// Release needle: every build without AERODJ_OWNER_AB (Debug and Release) has the gate off.
    func testGateOffWithoutOwnerABFlag() {
        XCTAssertFalse(OwnerVoiceTrial.paidProvidersEnabled)
        let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: OwnerVoiceTrial.paidProvidersEnabled,
                                           selectedVoiceID: jade, credentials: creds, pinnedHosts: pinned)
        XCTAssertEqual(c.routes.map(\.providerID), ["device"])
        XCTAssertEqual(c.decision, .omitted(.paidDisabled))
    }
    #endif

    // MARK: Route ordering and omission

    func testEnabledWithSelectionPutsElevenLabsFirstThenOnDevice() {
        let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: jade,
                                           credentials: creds, pinnedHosts: pinned)
        XCTAssertEqual(c.routes.map(\.providerID), ["elevenlabs", "device"])
        XCTAssertEqual(c.routes.first?.voice.id, jade)
        XCTAssertEqual(c.routes.first?.acceptsSSML, false)
        XCTAssertEqual(c.routes.first?.isPaid, false, "app-side $0 budget is not consumed; cap is server-side")
        XCTAssertEqual(c.decision, .included(catalogIndex: 3))
    }

    func testOmittedWhenDisabledUnselectedOrWithoutToken() {
        let cases: [(Bool, String?, PremiumProxyCredentials?, PremiumVoiceRoutes.OmitReason)] = [
            (false, jade, creds, .paidDisabled),
            (true, nil, creds, .noSelection),
            (true, "unknown", creds, .unknownVoice),
            (true, jade, nil, .noCredentials),
            (true, jade, PremiumProxyCredentials(endpoint: creds.endpoint, token: "  \n"), .emptyToken),
            (true, jade, PremiumProxyCredentials(endpoint: URL(string: "http://aerodj-tts.vercel.app/api/tts")!,
                                                    token: "t"), .endpointNotAllowed),
            (true, jade, PremiumProxyCredentials(endpoint: URL(string: "https://evil.example/api/tts")!,
                                                    token: "t"), .endpointNotAllowed),
            (true, jade, PremiumProxyCredentials(endpoint: URL(string: "https://vercel.app/api/tts")!,
                                                    token: "t"), .endpointNotAllowed),
        ]
        for (enabled, voice, credentials, reason) in cases {
            let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: enabled,
                                               selectedVoiceID: voice, credentials: credentials, pinnedHosts: pinned)
            XCTAssertEqual(c.routes.map(\.providerID), ["device"], "\(reason)")
            XCTAssertEqual(c.decision, .omitted(reason))
        }
    }

    /// Fail-closed host pinning: exact hosts only, no suffix rule, empty pins omit the route.
    func testHostPinningIsExactAndFailsClosed() {
        XCTAssertEqual(PremiumVoiceRoutes.allowedHosts, ["aerodj-tts.vercel.app"], "the production host only")
        let lookalike = PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts-x.vercel.app/api/tts")!, token: "t")
        XCTAssertFalse(PremiumVoiceRoutes.isAllowed(host: "aerodj-tts-x.vercel.app", pinned: pinned))
        XCTAssertEqual(PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: jade,
                                                  credentials: lookalike, pinnedHosts: pinned).decision,
                       .omitted(.endpointNotAllowed))
        XCTAssertEqual(PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: jade,
                                                  credentials: creds).decision,
                       .included(catalogIndex: 3), "the default pin admits the production host")
        let preview = PremiumProxyCredentials(
            endpoint: URL(string: "https://aerodj-tts-git-main-rowerguy508.vercel.app/api/tts")!, token: "t")
        XCTAssertEqual(PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: jade,
                                                  credentials: preview).decision,
                       .omitted(.endpointNotAllowed), "a preview deployment is not pinned")
        XCTAssertEqual(PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: jade,
                                                  credentials: creds, pinnedHosts: pinned).decision,
                       .included(catalogIndex: 3))
    }

    // MARK: Cache key per voice

    func testCacheKeyDiffersPerVoiceID() {
        let routes = PremiumVoiceCatalog.voices.map {
            PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: $0.id,
                                       credentials: creds, pinnedHosts: pinned).routes[0]
        }
        let keys = routes.map { VoiceRenderer.cacheKey(text: "Same line.", route: $0) }
        XCTAssertEqual(Set(keys).count, 4)
        XCTAssertFalse(keys.contains(VoiceRenderer.cacheKey(text: "Same line.", route: device()[0])))
    }

    // MARK: Rendering through the existing chain

    func testProxySuccessRendersSelectedVoiceThroughExistingRenderer() async {
        let transport = StubProxyTransport(status: 200, headers: StubProxyTransport.ok)
        let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: sawyer,
                                           credentials: creds, pinnedHosts: pinned, transport: transport)
        let renderer = VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache())
        guard case .success(let clip) = await renderer.render(cue(), userID: "u", stationID: "s", attribution: .presenter) else {
            return XCTFail("proxy route should render")
        }
        XCTAssertEqual(clip.audio.providerID, "elevenlabs")
        XCTAssertEqual(clip.audio.voiceID, sawyer)
        let ids = await transport.calls.voiceIDs
        XCTAssertEqual(ids, [sawyer])
    }

    func testProxyFailureFallsBackToOnDevice() async {
        for (status, headers) in [(502, ["Content-Type": "application/json"]),
                                  (401, ["Content-Type": "application/json"]),
                                  (200, ["Content-Type": "audio/wav"])] {  // missing duration
            let transport = StubProxyTransport(status: status, headers: headers)
            let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: sawyer,
                                               credentials: creds, pinnedHosts: pinned, transport: transport)
            let renderer = VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0),
                                         cache: InMemoryAudioCache())
            guard case .success(let clip) = await renderer.render(cue(), userID: "u", stationID: "s", attribution: .presenter) else {
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
        let c = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: sawyer,
                                           credentials: creds, pinnedHosts: pinned, transport: transport)
        let renderer = VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0),
                                     cache: InMemoryAudioCache())
        guard case .success(let clip) = await renderer.render(cue(), userID: "u", stationID: "s", attribution: .presenter) else {
            return XCTFail("on-device must rescue an over-cap clip")
        }
        XCTAssertEqual(clip.audio.providerID, "device")
    }

    // MARK: Picker sheet status (display only)

    func testEndpointPrefillsDefaultOnlyWhenNoneSaved() {
        XCTAssertEqual(PremiumVoiceRoutes.defaultEndpoint, "https://aerodj-tts.vercel.app/api/tts")
        XCTAssertEqual(PremiumVoicePickerStatus.initialEndpoint(saved: nil), PremiumVoiceRoutes.defaultEndpoint)
        XCTAssertEqual(PremiumVoicePickerStatus.initialEndpoint(saved: ""), PremiumVoiceRoutes.defaultEndpoint)
        XCTAssertEqual(PremiumVoicePickerStatus.initialEndpoint(saved: "https://other.example/x"), "https://other.example/x")
    }

    /// The footer uses the exact rule `compose` uses, so the two can never disagree.
    func testEndpointFooterMatchesComposeDecision() {
        let endpoints = ["https://aerodj-tts.vercel.app/api/tts", "  https://AERODJ-TTS.vercel.app/api/tts \n",
                         "http://aerodj-tts.vercel.app/api/tts", "https://user:pw@aerodj-tts.vercel.app/api/tts",
                         "https://aerodj-tts-x.vercel.app/api/tts", "https://vercel.app/api/tts", "aerodj-tts.vercel.app",
                         "", "not a url"]
        for pins in [pinned, PremiumVoiceRoutes.allowedHosts] {
            for endpoint in endpoints {
                let composed = PremiumVoicePickerStatus.pendingDecision(
                    paidProvidersEnabled: true, selectedVoiceID: jade, endpoint: endpoint, enteredToken: "t",
                    hasSavedToken: false, pinnedHosts: pins)
                let allowed = PremiumVoicePickerStatus.isEndpointAllowed(endpoint, pinnedHosts: pins)
                XCTAssertEqual(allowed, composed == .included(catalogIndex: 3), "\(endpoint) \(pins)")
            }
        }
        XCTAssertEqual(PremiumVoicePickerStatus.endpointFooter(PremiumVoiceRoutes.defaultEndpoint, pinnedHosts: pinned),
                       "Host allowed")
        XCTAssertEqual(PremiumVoicePickerStatus.endpointFooter("http://aerodj-tts.vercel.app/api/tts", pinnedHosts: pinned),
                       "Not the pinned host: route will be omitted")
    }

    func testPendingDecisionMirrorsWhatDoneSaves() {
        func decide(_ enabled: Bool = true, _ voice: String? = "g7LVvkPWALzPxOQbF6OE",
                    endpoint: String = PremiumVoiceRoutes.defaultEndpoint, token: String = "",
                    saved: Bool = true) -> PremiumVoiceRoutes.Decision {
            PremiumVoicePickerStatus.pendingDecision(paidProvidersEnabled: enabled, selectedVoiceID: voice,
                                                     endpoint: endpoint, enteredToken: token, hasSavedToken: saved,
                                                     pinnedHosts: pinned)
        }
        XCTAssertEqual(decide(), .included(catalogIndex: 3), "saved token is kept when the field is empty")
        XCTAssertEqual(decide(token: "new", saved: false), .included(catalogIndex: 3))
        XCTAssertEqual(decide(saved: false), .omitted(.noCredentials))
        XCTAssertEqual(decide(token: "  "), .omitted(.noCredentials), "a blank typed token deletes the saved one")
        XCTAssertEqual(decide(endpoint: "  "), .omitted(.noCredentials), "an empty endpoint is deleted on save")
        XCTAssertEqual(decide(endpoint: "https://evil.example/api/tts"), .omitted(.endpointNotAllowed))
        XCTAssertEqual(decide(false), .omitted(.paidDisabled))
        XCTAssertEqual(decide(true, nil), .omitted(.noSelection))
        XCTAssertEqual(PremiumVoicePickerStatus.pendingDecision(
            paidProvidersEnabled: true, selectedVoiceID: jade, endpoint: PremiumVoiceRoutes.defaultEndpoint,
            enteredToken: "", hasSavedToken: true),
                       PremiumVoiceRoutes.compose(onDevice: [], paidProvidersEnabled: true, selectedVoiceID: jade,
                                                  credentials: creds).decision, "defaults to compose's pins")
    }

    /// Security review: the sheet's check only reads the pin; running it never widens it.
    func testSheetValidationNeverWidensTheAllowlist() {
        let before = PremiumVoiceRoutes.allowedHosts
        let evil = "https://evil.example/api/tts"
        XCTAssertFalse(PremiumVoicePickerStatus.isEndpointAllowed(evil))
        _ = PremiumVoicePickerStatus.endpointFooter(evil)
        _ = PremiumVoicePickerStatus.pendingDecision(paidProvidersEnabled: true, selectedVoiceID: jade, endpoint: evil,
                                                     enteredToken: "t", hasSavedToken: true)
        XCTAssertEqual(PremiumVoiceRoutes.allowedHosts, before, "validation must not mutate the pin")
        XCTAssertFalse(PremiumVoiceRoutes.isAllowed(host: "evil.example"))
        XCTAssertFalse(PremiumVoicePickerStatus.isEndpointAllowed(evil), "still refused after validation ran")
        XCTAssertEqual(PremiumVoicePickerStatus.endpointFooter(evil), "Not the pinned host: route will be omitted")
        let after = PremiumVoiceRoutes.compose(onDevice: device(), paidProvidersEnabled: true, selectedVoiceID: jade,
                                               credentials: PremiumProxyCredentials(endpoint: URL(string: evil)!,
                                                                                    token: "t"))
        XCTAssertEqual(after.decision, .omitted(.endpointNotAllowed))
        XCTAssertEqual(after.routes.map(\.providerID), ["device"])
    }

    func testStatusLineShowsOnlyIndexOrReasonCode() {
        XCTAssertEqual(PremiumVoicePickerStatus.statusLine(.included(catalogIndex: 3)), "Premium: included (catalog index 3)")
        XCTAssertEqual(PremiumVoicePickerStatus.statusLine(.omitted(.endpointNotAllowed)),
                       "Premium: omitted (endpointNotAllowed)")
    }

    // MARK: Captions

    func testElevenLabsCaptionsAreWholeLine() {
        XCTAssertFalse(PremiumVoiceRoutes.hasWordTimings(providerID: PremiumVoiceRoutes.providerID))
    }
}
