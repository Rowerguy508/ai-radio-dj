import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// #378 App Attest client (-Atlas): enrollment, install-token mint, refresh, backoff, fallback,
// owner precedence, consent gating and redaction. Fake device and fake server; nothing here
// touches DeviceCheck, a Keychain or the network.

// MARK: - Fakes

private func keyID(_ n: UInt8) -> String { Data(repeating: n, count: 32).base64EncodedString() }

private final class FakeAttestDevice: AppAttestDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var _supported: Bool
    private var nextKey: UInt8 = 1
    private var _generated: [String] = []
    private var _attestHashes: [Data] = []
    private var _assertionHashes: [Data] = []
    private var assertionErrors: [AppAttestDeviceError] = []
    var generateError: AppAttestDeviceError?
    var attestError: AppAttestDeviceError?
    init(supported: Bool = true) { _supported = supported }

    var isSupported: Bool { lock.withLock { _supported } }
    var generated: [String] { lock.withLock { _generated } }
    var attestHashes: [Data] { lock.withLock { _attestHashes } }
    var assertionHashes: [Data] { lock.withLock { _assertionHashes } }
    var deviceCalls: Int { lock.withLock { _generated.count + _attestHashes.count + _assertionHashes.count } }
    func failNextAssertions(_ errors: [AppAttestDeviceError]) { lock.withLock { assertionErrors = errors } }

    func generateKey() async throws -> String {
        try lock.withLock {
            if let generateError { throw generateError }
            defer { nextKey += 1 }
            let id = keyID(nextKey)
            _generated.append(id)
            return id
        }
    }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            _attestHashes.append(clientDataHash)
            if let attestError { throw attestError }
            return Data("attestation-object-SECRET".utf8)
        }
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            _assertionHashes.append(clientDataHash)
            if !assertionErrors.isEmpty { throw assertionErrors.removeFirst() }
            return Data("assertion-SECRET".utf8)
        }
    }
}

private struct Reply: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()
    var fails = false

    static func json(_ status: Int, _ json: String, retryAfter: String? = nil) -> Reply {
        var headers = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        return Reply(status: status, headers: headers, body: Data(json.utf8))
    }
    static func reason(_ status: Int, _ reason: String, retryAfter: String? = nil) -> Reply {
        json(status, #"{"error":"x","reason":"\#(reason)"}"#, retryAfter: retryAfter)
    }
    static let transportError = Reply(status: 0, fails: true)
    static let audio = Reply(status: 200, headers: ["Content-Type": "audio/mpeg", "X-Audio-Duration": "2.5"],
                             body: Data([1, 2, 3]))
}

private struct SeenRequest: Sendable {
    let path: String
    let headers: [String: String]
    let body: Data
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:] }
}

/// The proxy, per #378: attest challenge, register, tok challenge, token, tts. Each endpoint
/// answers from its own queue (the last reply repeats); the defaults are the happy path.
private final class FakeProxy: HTTPTransport, @unchecked Sendable {
    enum Endpoint: Hashable { case attestChallenge, register, tokChallenge, token, tts }
    private let lock = NSLock()
    private var scripts: [Endpoint: [Reply]] = [:]
    private var counter = 0
    private var _seen: [SeenRequest] = []
    var seen: [SeenRequest] { lock.withLock { _seen } }
    func count(_ path: String) -> Int { seen.filter { $0.path == path }.count }
    var total: Int { seen.count }

    func script(_ endpoint: Endpoint, _ replies: [Reply]) { lock.withLock { scripts[endpoint] = replies } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let body = request.httpBody ?? Data()
        let reply: Reply = lock.withLock {
            counter += 1
            _seen.append(SeenRequest(path: path, headers: request.allHTTPHeaderFields ?? [:], body: body))
            let purpose = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["purpose"] as? String
            let endpoint: Endpoint
            switch path {
            case "/api/attest/challenge": endpoint = purpose == "tok" ? .tokChallenge : .attestChallenge
            case "/api/attest/register": endpoint = .register
            case "/api/attest/token": endpoint = .token
            default: endpoint = .tts
            }
            if var queue = scripts[endpoint], !queue.isEmpty {
                let next = queue.count > 1 ? queue.removeFirst() : queue[0]
                scripts[endpoint] = queue
                return next
            }
            switch endpoint {
            case .attestChallenge, .tokChallenge: return .json(200, #"{"challenge":"ch_\#(counter)-SECRET","expiresIn":120}"#)
            case .register: return Reply(status: 204)
            case .token: return .json(200, #"{"token":"tok\#(counter).SECRETTOKEN","expiresIn":1800}"#)
            case .tts: return .audio
            }
        }
        if reply.fails { throw URLError(.timedOut) }
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                            headerFields: reply.headers)!)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [InstallTokenSource.LogEntry] = []
    var entries: [InstallTokenSource.LogEntry] { lock.withLock { _entries } }
    func add(_ e: InstallTokenSource.LogEntry) { lock.withLock { _entries.append(e) } }
}

private final class FlakyKeyStorage: AttestKeyIDStorage, @unchecked Sendable {
    func readKeyID() -> AttestKeyIDRead { .notFound }
    func saveKeyID(_ keyId: String) -> Bool { false }
    func clearKeyID() {}
}

private struct LocalVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data([7]), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private let base = URL(string: "https://aerodj-tts.vercel.app")!
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// One wired-up client: fake device, fake proxy, in-memory key and install-ID storage.
private struct Rig {
    let device: FakeAttestDevice
    let proxy = FakeProxy()
    let keys: AttestKeyIDStorage
    let clock = Clock(t0)
    let backoff: PaidVoiceBackoff
    let logs = LogSink()
    let source: InstallTokenSource

    init(supported: Bool = true, consent: any PaidVoiceConsentProviding = TesterVoiceConsentReader(.inMemory(.accepted)),
         keys: AttestKeyIDStorage = InMemoryAttestKeyIDStorage(), registered: Bool = false) {
        device = FakeAttestDevice(supported: supported)
        if registered { _ = keys.saveKeyID(keyID(200)) }
        self.keys = keys
        let clock = self.clock
        backoff = PaidVoiceBackoff(now: { clock.now })
        let logs = self.logs
        source = InstallTokenSource(
            device: device, keyStore: keys,
            attest: AttestClient(baseURL: base, transport: proxy, installID: AttestInstallID(storage: InMemoryAttestInstallIDStorage()))!,
            tokens: InstallTokenClient(baseURL: base, transport: proxy)!,
            consent: consent, backoff: backoff, now: { clock.now }, log: { logs.add($0) })
    }

    func token() async -> Result<InstallToken, InstallTokenSource.Unavailable> {
        do { return .success(try await source.installToken()) }
        catch { return .failure(error as! InstallTokenSource.Unavailable) }
    }

    func tokenValue() async -> String? {
        if case .success(let t) = await token() { return t.headerValue }
        return nil
    }

    /// The renderer the tester build composes: attested ElevenLabs route, then on-device.
    func renderer(route: CloudVoiceCredentialPolicy.Route = .installToken) -> (VoiceRenderer, PremiumVoiceRoutes.AttestedDecision) {
        let device = [VoiceRoute(providerID: "device", provider: LocalVoice(), voice: VoiceProfile(id: "host", name: "Host"))]
        let c = PremiumVoiceRoutes.composeAttested(onDevice: device, route: route,
                                                   voiceID: TesterVoice.voiceID(selected: nil),
                                                   tokens: source, transport: proxy, backoff: backoff)
        return (VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache()),
                c.decision)
    }
}

/// A distinct catalog-safe presenter line each time (the cache never answers for the proxy).
private func render(_ r: VoiceRenderer, attribution: SpokenAttribution? = .presenter) async -> String? {
    let cue = NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: "That was Song \(UUID().uuidString.prefix(6)).",
                           estimatedSeconds: 2, maxSeconds: 12, sourceItemID: nil, source: nil, provenance: nil)
    guard case .success(let clip) = await r.render(cue, userID: "u", stationID: "s", attribution: attribution) else { return nil }
    return clip.audio.providerID
}

// MARK: - Requests and parsing (pure)

final class InstallTokenClientTests: XCTestCase {
    private let client = InstallTokenClient(baseURL: base, transport: FakeProxy())!

    func testRefusesNonHTTPSOrUnpinnedHosts() {
        for url in ["http://aerodj-tts.vercel.app", "https://evil.example", "https://aerodj-tts-git-x.vercel.app"] {
            XCTAssertNil(InstallTokenClient(baseURL: URL(string: url)!, transport: FakeProxy()), url)
        }
    }

    func testTokChallengeRequestIsKeyBoundAndCarriesNothingElse() throws {
        let r = try client.challengeRequest(keyId: keyID(3))
        XCTAssertEqual(r.url?.path, "/api/attest/challenge")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-OnAirly-Key"), keyID(3))
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["purpose": "tok", "keyId": keyID(3)])
    }

    func testTokenBodyAndClientDataFollowTheContract() throws {
        let body = try XCTUnwrap(InstallTokenClient.tokenBody(challenge: "Ab_9-z"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"challenge":"Ab_9-z"}"#)
        let clientData = String(decoding: InstallTokenClient.assertionClientData(challenge: "Ab_9-z", body: body), as: UTF8.self)
        XCTAssertEqual(clientData, "onairly-tok-v1\nAb_9-z\n" + AttestHash.sha256Hex(body))
        XCTAssertEqual(InstallTokenClient.assertionClientDataHash(challenge: "Ab_9-z", body: body),
                       AttestHash.sha256(Data(clientData.utf8)))
        // Known-answer check of the hex digest (SHA-256 of the empty string).
        XCTAssertEqual(AttestHash.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // Never builds a body around a challenge that would need escaping.
        for bad in ["", "a\"b", "a b", "a\nb", "ü", String(repeating: "a", count: 129)] {
            XCTAssertNil(InstallTokenClient.tokenBody(challenge: bad), bad)
        }
    }

    func testTokenRequestSendsKeyAndStandardBase64AssertionAndNoAuthorization() {
        let body = InstallTokenClient.tokenBody(challenge: "c1")!
        let r = client.tokenRequest(keyId: keyID(4), body: body, assertion: Data([0xfb, 0xff]))
        XCTAssertEqual(r.url?.path, "/api/attest/token")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-OnAirly-Key"), keyID(4))
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-OnAirly-Assertion"), "+/8=")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(r.httpBody, body, "the exact bytes the assertion covers")
        XCTAssertLessThanOrEqual(body.count, 1024)
    }

    func testParsesOnlyAWellFormedToken() {
        let ok = InstallTokenClient.parseToken(Data(#"{"token":"abc.def","expiresIn":1800}"#.utf8), startedAt: t0)
        XCTAssertEqual(ok?.headerValue, "abc.def")
        XCTAssertEqual(ok?.expiresAt, t0.addingTimeInterval(1800))
        for bad in [#"{"token":"","expiresIn":1800}"#, #"{"token":"a b","expiresIn":1800}"#,
                    #"{"token":"abc","expiresIn":10}"#, #"{"token":"abc","expiresIn":86400}"#,
                    #"{"token":"abc"}"#, #"{"expiresIn":1800}"#, "not json",
                    #"{"token":"\#(String(repeating: "a", count: 2049))","expiresIn":1800}"#] {
            XCTAssertNil(InstallTokenClient.parseToken(Data(bad.utf8), startedAt: t0), bad)
        }
    }

    func testFailureReasonsMustMatchTheirStatus() {
        func map(_ status: Int, _ reason: String, retry: String? = nil) -> InstallTokenClient.Failure {
            let r = Reply.reason(status, reason, retryAfter: retry)
            return InstallTokenClient.failure(status: status, data: r.body,
                                              response: HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: r.headers)!)
        }
        XCTAssertEqual(map(429, "rate", retry: "120"), .init(reason: .rate, status: 429, retryAfter: "120"))
        XCTAssertEqual(map(401, "reattest").reason, .reattest)
        XCTAssertEqual(map(403, "no_entitlement").reason, .noEntitlement)
        XCTAssertEqual(map(400, "challenge_expired").reason, .challengeExpired)
        XCTAssertEqual(map(400, "mixed_auth").reason, .mixedAuth)
        XCTAssertEqual(map(503, "disabled", retry: "3600").retryAfter, "3600")
        XCTAssertEqual(map(401, "rate").reason, .unexpected, "reason and status disagree")
        XCTAssertEqual(map(418, "nonsense").reason, .unexpected)
    }

    func testTokenNeverAppearsInDescriptionsOrMirrors() {
        let token = InstallToken(value: "SECRETTOKEN", expiresAt: t0)
        for text in ["\(token)", String(describing: token), String(reflecting: token), "\([token])"] {
            XCTAssertFalse(text.contains("SECRETTOKEN"), text)
        }
        var dumped = ""
        dump(token, to: &dumped)
        XCTAssertFalse(dumped.contains("SECRETTOKEN"), dumped)
    }
}

// MARK: - State machine

final class InstallTokenSourceTests: XCTestCase {
    // Enrollment

    func testFirstCallStartsEnrollmentInTheBackgroundAndReturnsAtOnce() async {
        let rig = Rig()
        let first = await rig.token()
        XCTAssertEqual(first, .failure(.enrolling), "the first cue goes on-device, it never waits on attestation")
        await rig.source.waitForEnrollment()
        let id = rig.device.generated.first
        XCTAssertNotNil(id)
        XCTAssertEqual((rig.keys as! InMemoryAttestKeyIDStorage).stored, id, "a 204 saves the key ID")
        XCTAssertEqual(rig.proxy.count("/api/attest/register"), 1)
        let register = rig.proxy.seen.first { $0.path == "/api/attest/register" }!.json
        XCTAssertEqual(register["keyId"] as? String, id)
        XCTAssertEqual(register["attestationObject"] as? String, Data("attestation-object-SECRET".utf8).base64EncodedString())
        let attestChallenge = rig.proxy.seen.first { $0.path == "/api/attest/challenge" }!.json
        XCTAssertEqual(attestChallenge["purpose"] as? String, "attest")
        XCTAssertEqual(register["challenge"] as? String, "ch_1-SECRET", "the challenge from the first request")
        XCTAssertEqual(rig.device.attestHashes, [AttestHash.attestClientDataHash(challenge: "ch_1-SECRET")])

        // Next cue: mint with the registered key, then the cached token.
        let token = await rig.tokenValue()
        XCTAssertNotNil(token)
        let got1 = await rig.tokenValue()
        XCTAssertEqual(got1, token, "cached: no second mint")
        XCTAssertEqual(rig.proxy.count("/api/attest/token"), 1)
    }

    func testRegisterFailureKeepsNoKeyAndDoesNotRetryThisLaunch() async {
        let rig = Rig()
        rig.proxy.script(.register, [.reason(400, "assertion")])
        _ = await rig.token()
        await rig.source.waitForEnrollment()
        XCTAssertNil((rig.keys as! InMemoryAttestKeyIDStorage).stored)
        XCTAssertTrue(rig.backoff.isStoppedForThisLaunch)
        let got2 = await rig.token()
        XCTAssertEqual(got2, .failure(.backingOff))
        await rig.source.waitForEnrollment()
        XCTAssertEqual(rig.device.generated.count, 1, "one enrollment per launch")
    }

    func testEnroll429HonorsRetryAfter() async {
        let rig = Rig()
        rig.proxy.script(.register, [.reason(429, "enroll", retryAfter: "7200")])
        _ = await rig.token()
        await rig.source.waitForEnrollment()
        XCTAssertEqual(rig.backoff.suspendedUntil(), t0.addingTimeInterval(7200))
        XCTAssertFalse(rig.backoff.isStoppedForThisLaunch)
    }

    func testKeychainSaveFailureKeepsTheKeyForThisLaunchOnly() async {
        let rig = Rig(keys: FlakyKeyStorage())
        _ = await rig.token()
        await rig.source.waitForEnrollment()
        let got3 = await rig.tokenValue()
        XCTAssertNotNil(got3, "the registered key is used from memory")
        XCTAssertEqual(rig.device.generated.count, 1)
    }

    func testUnreadableKeychainNeverEnrollsANewKey() async {
        let keys = InMemoryAttestKeyIDStorage(keyID(9))
        keys.readFails = true
        let rig = Rig(keys: keys)
        let got4 = await rig.token()
        XCTAssertEqual(got4, .failure(.keyUnreadable))
        await rig.source.waitForEnrollment()
        XCTAssertEqual(rig.device.deviceCalls, 0)
        XCTAssertEqual(rig.proxy.total, 0)
    }

    func testStoredGarbageKeyIsClearedAndReEnrolled() async {
        let keys = InMemoryAttestKeyIDStorage("not-a-key")
        let rig = Rig(keys: keys)
        let got5 = await rig.token()
        XCTAssertEqual(got5, .failure(.enrolling))
        await rig.source.waitForEnrollment()
        XCTAssertEqual(keys.stored, rig.device.generated.first)
    }

    // Mint and refresh

    func testMintSignsTheExactBodyWithTheTokChallenge() async throws {
        let rig = Rig(registered: true)
        let token = await rig.tokenValue()
        XCTAssertNotNil(token)
        let tok = try XCTUnwrap(rig.proxy.seen.first { $0.path == "/api/attest/challenge" })
        XCTAssertEqual(tok.json["purpose"] as? String, "tok")
        XCTAssertEqual(tok.header("X-OnAirly-Key"), keyID(200))
        let mint = try XCTUnwrap(rig.proxy.seen.first { $0.path == "/api/attest/token" })
        let challenge = "ch_1-SECRET"  // the fake proxy's answer to the first request
        XCTAssertEqual(mint.body, InstallTokenClient.tokenBody(challenge: challenge))
        XCTAssertEqual(rig.device.assertionHashes, [InstallTokenClient.assertionClientDataHash(challenge: challenge, body: mint.body)])
        XCTAssertEqual(mint.header("X-OnAirly-Assertion"), Data("assertion-SECRET".utf8).base64EncodedString())
        XCTAssertNil(mint.header("Authorization"))
        XCTAssertEqual(rig.device.generated, [], "a registered key is reused, never regenerated")
    }

    func testRefreshesOnlyInsideTheFiveMinuteWindowAndInTheBackground() async {
        let rig = Rig(registered: true)
        let first = await rig.tokenValue()
        rig.clock.advance(1800 - 301)  // 5 min 1 s left: still cached
        let got6 = await rig.tokenValue()
        XCTAssertEqual(got6, first)
        XCTAssertEqual(rig.proxy.count("/api/attest/token"), 1)
        rig.clock.advance(2)  // 4 min 59 s left: this cue keeps the token, a refresh starts
        let got7 = await rig.tokenValue()
        XCTAssertEqual(got7, first, "the cue never waits on the refresh")
        await rig.source.waitForMint()
        XCTAssertEqual(rig.proxy.count("/api/attest/token"), 2)
        let second = await rig.tokenValue()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
    }

    func testAnExpiredTokenIsNeverSentAndTheCueWaitsForAFreshOne() async {
        let rig = Rig(registered: true)
        let first = await rig.tokenValue()
        rig.clock.advance(1800 - 59)  // under a minute left: not usable
        let second = await rig.tokenValue()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
    }

    func testConcurrentCallersShareOneMint() async {
        let rig = Rig(registered: true)
        async let a = rig.tokenValue()
        async let b = rig.tokenValue()
        async let c = rig.tokenValue()
        let all = await [a, b, c]
        XCTAssertEqual(Set(all.compactMap { $0 }).count, 1)
        XCTAssertEqual(rig.proxy.count("/api/attest/token"), 1)
    }

    func testChallengeExpiredIsRetriedOnceThenGivesUpQuietly() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.token, [.reason(400, "challenge_expired"), .json(200, #"{"token":"t2","expiresIn":1800}"#)])
        let got8 = await rig.tokenValue()
        XCTAssertEqual(got8, "t2")
        XCTAssertEqual(rig.proxy.count("/api/attest/challenge"), 2)

        let again = Rig(registered: true)
        again.proxy.script(.token, [.reason(400, "challenge_expired")])
        let got9 = await again.token()
        XCTAssertEqual(got9, .failure(.failed))
        XCTAssertEqual(again.proxy.count("/api/attest/token"), 2, "exactly one retry")
        XCTAssertNil(again.backoff.suspendedUntil(), "no backoff for an expired challenge")
    }

    func testMintFailureFallsBackToAStillUsableToken() async {
        let rig = Rig(registered: true)
        let first = await rig.tokenValue()
        rig.proxy.script(.token, [.transportError])
        rig.clock.advance(1800 - 120)  // 2 min left
        let got10 = await rig.tokenValue()
        XCTAssertEqual(got10, first)
        await rig.source.waitForMint()
        XCTAssertNotNil(rig.backoff.suspendedUntil(), "transport failure backs off")
        let got11 = await rig.tokenValue()
        XCTAssertEqual(got11, first, "suspended: keeps using the usable token")
    }

    // Backoff

    func test429OnMintHonorsRetryAfterAndMakesNoCallsMeanwhile() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.token, [.reason(429, "rate", retryAfter: "900")])
        let got12 = await rig.token()
        XCTAssertEqual(got12, .failure(.backingOff))
        XCTAssertEqual(rig.backoff.suspendedUntil(), t0.addingTimeInterval(900))
        let calls = rig.proxy.total
        rig.clock.advance(899)
        let got13 = await rig.token()
        XCTAssertEqual(got13, .failure(.backingOff))
        XCTAssertEqual(rig.proxy.total, calls, "no request while suspended")
        rig.proxy.script(.token, [.json(200, #"{"token":"after","expiresIn":1800}"#)])
        rig.clock.advance(2)
        let got14 = await rig.tokenValue()
        XCTAssertEqual(got14, "after")
    }

    func test429WithoutRetryAfterUsesTheShortFloor() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.tokChallenge, [.reason(429, "rate")])
        let got15 = await rig.token()
        XCTAssertEqual(got15, .failure(.backingOff))
        XCTAssertEqual(rig.backoff.suspendedUntil(), t0.addingTimeInterval(PaidVoiceBackoff.shortRateLimitWait))
    }

    func test503DisabledHonorsRetryAfter() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.token, [.reason(503, "disabled", retryAfter: "3600")])
        let got16 = await rig.token()
        XCTAssertEqual(got16, .failure(.backingOff))
        XCTAssertEqual(rig.backoff.suspendedUntil(), t0.addingTimeInterval(3600))
    }

    func testHardFailuresStopForThisLaunch() async {
        for reply in [Reply.reason(403, "no_entitlement"), .reason(401, "assertion"), .reason(400, "mixed_auth"),
                      .reason(400, "bad_request"), .json(200, "{}"), .reason(418, "teapot")] {
            let rig = Rig(registered: true)
            rig.proxy.script(.token, [reply])
            let got17 = await rig.token()
            XCTAssertEqual(got17, .failure(.stopped), "\(reply.status)")
            XCTAssertTrue(rig.backoff.isStoppedForThisLaunch, "\(reply.status)")
            let calls = rig.proxy.total
            let got18 = await rig.token()
            XCTAssertEqual(got18, .failure(.backingOff))
            XCTAssertEqual(rig.proxy.total, calls)
        }
    }

    // Invalidated key: regenerate once

    func testReattestRegeneratesTheKeyOnceThenStops() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.token, [.reason(401, "reattest"), .json(200, #"{"token":"fresh","expiresIn":1800}"#)])
        let got19 = await rig.token()
        XCTAssertEqual(got19, .failure(.enrolling))
        await rig.source.waitForEnrollment()
        let newKey = rig.device.generated.first
        XCTAssertNotNil(newKey)
        XCTAssertNotEqual(newKey, keyID(200))
        XCTAssertEqual((rig.keys as! InMemoryAttestKeyIDStorage).stored, newKey)
        let got20 = await rig.tokenValue()
        XCTAssertEqual(got20, "fresh")
        XCTAssertFalse(rig.backoff.isStoppedForThisLaunch)

        // A second invalidation in the same launch: no third key, the paid route stops.
        rig.proxy.script(.token, [.reason(401, "reattest")])
        await rig.source.tokenRejected(InstallToken(value: "fresh", expiresAt: t0.addingTimeInterval(1800)))
        let got21 = await rig.token()
        XCTAssertEqual(got21, .failure(.enrolling))
        await rig.source.waitForEnrollment()
        XCTAssertEqual(rig.device.generated.count, 1, "regenerated once only")
        XCTAssertTrue(rig.backoff.isStoppedForThisLaunch)
        XCTAssertNil((rig.keys as! InMemoryAttestKeyIDStorage).stored)
    }

    func testDeviceInvalidKeyOnAssertionAlsoRegeneratesOnce() async {
        let rig = Rig(registered: true)
        rig.device.failNextAssertions([.invalidKey])
        let got22 = await rig.token()
        XCTAssertEqual(got22, .failure(.enrolling))
        await rig.source.waitForEnrollment()
        XCTAssertEqual(rig.device.generated.count, 1)
        let got23 = await rig.tokenValue()
        XCTAssertNotNil(got23)
    }

    func testDeviceFailuresMapToBackoffOrStop() async {
        let busy = Rig(registered: true)
        busy.device.failNextAssertions([.serverUnavailable])
        let got24 = await busy.token()
        XCTAssertEqual(got24, .failure(.backingOff))
        XCTAssertFalse(busy.backoff.isStoppedForThisLaunch)
        XCTAssertNotNil(busy.backoff.suspendedUntil())

        let broken = Rig()
        broken.device.attestError = .failed
        _ = await broken.token()
        await broken.source.waitForEnrollment()
        XCTAssertTrue(broken.backoff.isStoppedForThisLaunch)
        XCTAssertNil((broken.keys as! InMemoryAttestKeyIDStorage).stored, "an unattested key is never saved")
        XCTAssertEqual(broken.proxy.count("/api/attest/register"), 0)
    }

    // Gates

    func testNoConsentMeansNoKeychainDeviceOrNetworkAtAll() async {
        let store = CloudVoiceConsentStore.inMemory()  // undecided: the sheet was never answered
        let keys = InMemoryAttestKeyIDStorage()
        let rig = Rig(consent: TesterVoiceConsentReader(store), keys: keys)
        let got25 = await rig.token()
        XCTAssertEqual(got25, .failure(.noConsent))
        await rig.source.prepare()
        await rig.source.waitForEnrollment()
        XCTAssertEqual(rig.device.deviceCalls, 0)
        XCTAssertEqual(rig.proxy.total, 0)
        store.accept()
        await rig.source.prepare()
        await rig.source.waitForEnrollment()
        XCTAssertEqual(rig.device.generated.count, 1, "control: consent starts enrollment")
    }

    func testWithdrawnConsentStopsTheNextCueEvenWithACachedToken() async {
        let store = CloudVoiceConsentStore.inMemory(.accepted)
        let rig = Rig(consent: TesterVoiceConsentReader(store), registered: true)
        let got26 = await rig.tokenValue()
        XCTAssertNotNil(got26)
        store.decline()
        let got27 = await rig.token()
        XCTAssertEqual(got27, .failure(.noConsent))
    }

    func testUnsupportedDeviceOrSimulatorNeverCallsAnything() async {
        let rig = Rig(supported: false, registered: true)
        let got28 = await rig.token()
        XCTAssertEqual(got28, .failure(.unsupported))
        await rig.source.prepare()
        XCTAssertEqual(rig.device.deviceCalls, 0)
        XCTAssertEqual(rig.proxy.total, 0)
    }

    // Redaction

    func testLogsCarryNoTokenKeyChallengeOrAssertion() async {
        let rig = Rig()
        _ = await rig.token()
        await rig.source.waitForEnrollment()
        _ = await rig.token()
        rig.proxy.script(.token, [.reason(401, "reattest")])
        rig.clock.advance(1800)
        _ = await rig.token()
        await rig.source.waitForEnrollment()
        let lines = rig.logs.entries.map { "\($0.event.rawValue) \($0.outcome) \($0.status ?? 0) \($0)" }
        XCTAssertFalse(lines.isEmpty)
        let secrets = ["SECRET", "ch_", keyID(1), keyID(200), "assertion-", "attestation-"]
        for line in lines {
            for s in secrets { XCTAssertFalse(line.contains(s), "\(s) in \(line)") }
        }
        let allowed = Set(InstallTokenClient.Failure.Reason.allCases.map(\.rawValue)
                          + AttestClient.Failure.Reason.allCases.map(\.rawValue)
                          + ["ok", "regenerate", "stopped", "unexpected"]
                          + ["unsupported", "invalidKey", "serverUnavailable", "failed"].map { "device_\($0)" })
        for entry in rig.logs.entries { XCTAssertTrue(allowed.contains(entry.outcome), entry.outcome) }
        for error in [InstallTokenSource.Unavailable.noConsent, .enrolling, .stopped] {
            XCTAssertFalse(String(describing: error).contains("SECRET"))
        }
    }
}

// MARK: - Proxy, renderer, policy

final class AttestedVoiceRouteTests: XCTestCase {
    func testTTSSendsOnlyTheInstallTokenNeverAuthorization() async throws {
        let rig = Rig(registered: true)
        let (r, decision) = rig.renderer()
        XCTAssertEqual(decision, .included(catalogIndex: 0))
        let got29 = await render(r)
        XCTAssertEqual(got29, PremiumVoiceRoutes.providerID)
        let tts = try XCTUnwrap(rig.proxy.seen.first { $0.path == "/api/tts" })
        let token = try XCTUnwrap(rig.proxy.seen.first { $0.path == "/api/attest/token" }).body
        XCTAssertFalse(token.isEmpty)
        XCTAssertNotNil(tts.header("X-OnAirly-Install-Token"))
        XCTAssertEqual(tts.header("X-OnAirly-Install-Token")?.hasSuffix(".SECRETTOKEN"), true)
        XCTAssertNil(tts.header("Authorization"), "never both credentials (400 mixed_auth)")
        XCTAssertNil(tts.header("X-OnAirly-Key"))
        XCTAssertEqual(tts.json["voiceId"] as? String, PremiumVoiceCatalog.voices[0].id)
        XCTAssertNil(tts.json["installId"])
    }

    func testFirstCueOfAFreshInstallIsOnDeviceAndNeverStalls() async {
        let rig = Rig()
        let (r, _) = rig.renderer()
        let started = Date()
        let got30 = await render(r)
        XCTAssertEqual(got30, "device")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        await rig.source.waitForEnrollment()
        let got31 = await render(r)
        XCTAssertEqual(got31, PremiumVoiceRoutes.providerID, "the next break uses the cloud voice")
    }

    func testPrivateLinesNeverReachTheAttestedRouteOrMintAToken() async {
        let rig = Rig(registered: true)
        let (r, _) = rig.renderer()
        let got32 = await render(r, attribution: .trackMetadata(trackIDs: ["lib-1"], origin: .unknown))
        XCTAssertEqual(got32, "device")
        let got33 = await render(r, attribution: nil)
        XCTAssertEqual(got33, "device")
        XCTAssertEqual(rig.proxy.total, 0, "mayLeaveDevice false: no token, no request")
    }

    func testNoConsentMeansEveryCueOnDeviceAndZeroRequests() async {
        let rig = Rig(consent: TesterVoiceConsentReader(.inMemory(.declined)), registered: true)
        let (r, _) = rig.renderer()
        for _ in 0..<3 {
            let got = await render(r)
            XCTAssertEqual(got, "device")
        }
        XCTAssertEqual(rig.proxy.total, 0)
        XCTAssertEqual(rig.device.deviceCalls, 0)
    }

    func testTokenExpiredRefreshesOnceForTheCue() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.tts, [.reason(401, "token_expired"), .audio])
        let (r, _) = rig.renderer()
        let got34 = await render(r)
        XCTAssertEqual(got34, PremiumVoiceRoutes.providerID)
        XCTAssertEqual(rig.proxy.count("/api/attest/token"), 2, "one refresh")
        XCTAssertEqual(rig.proxy.count("/api/tts"), 2)
        let tokens = rig.proxy.seen.filter { $0.path == "/api/tts" }.map { $0.header("X-OnAirly-Install-Token") }
        guard tokens.count == 2 else { return XCTFail("expected two /api/tts requests, got \(tokens.count)") }
        XCTAssertNotEqual(tokens[0], tokens[1], "the retry carries the new token")
        XCTAssertFalse(rig.backoff.isStoppedForThisLaunch)
    }

    func testSecondTokenExpiredGoesOnDeviceForTheCueWithoutStopping() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.tts, [.reason(401, "token_expired")])
        let (r, _) = rig.renderer()
        let got35 = await render(r)
        XCTAssertEqual(got35, "device")
        XCTAssertEqual(rig.proxy.count("/api/tts"), 2, "no third try")
        XCTAssertFalse(rig.backoff.isStoppedForThisLaunch)
    }

    func testOther401OnTTSStopsThePaidRouteForTheLaunch() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.tts, [.reason(401, "assertion")])
        let (r, _) = rig.renderer()
        let got36 = await render(r)
        XCTAssertEqual(got36, "device")
        XCTAssertEqual(rig.proxy.count("/api/tts"), 1)
        XCTAssertTrue(rig.backoff.isStoppedForThisLaunch)
        let calls = rig.proxy.total
        let got37 = await render(r)
        XCTAssertEqual(got37, "device")
        XCTAssertEqual(rig.proxy.total, calls)
    }

    func testTTS429BacksOffAndFallsBack() async {
        let rig = Rig(registered: true)
        rig.proxy.script(.tts, [.reason(429, "install_daily", retryAfter: "600")])
        let (r, _) = rig.renderer()
        let got38 = await render(r)
        XCTAssertEqual(got38, "device")
        XCTAssertEqual(rig.backoff.suspendedUntil(), t0.addingTimeInterval(600))
        let calls = rig.proxy.total
        let got39 = await render(r)
        XCTAssertEqual(got39, "device")
        XCTAssertEqual(rig.proxy.total, calls)
    }

    func testOwnerTokenPathTakesPrecedenceAndIsUnchanged() async throws {
        XCTAssertEqual(CloudVoiceCredentialPolicy.resolve(ownerABBuild: true, testerVoiceBuild: true, attestSupported: true), .ownerToken)
        XCTAssertEqual(CloudVoiceCredentialPolicy.resolve(ownerABBuild: true, testerVoiceBuild: false, attestSupported: false), .ownerToken)
        XCTAssertEqual(CloudVoiceCredentialPolicy.resolve(ownerABBuild: false, testerVoiceBuild: true, attestSupported: true), .installToken)
        XCTAssertEqual(CloudVoiceCredentialPolicy.resolve(ownerABBuild: false, testerVoiceBuild: true, attestSupported: false),
                       .onDeviceOnly(.attestUnsupported))
        XCTAssertEqual(CloudVoiceCredentialPolicy.resolve(ownerABBuild: false, testerVoiceBuild: false, attestSupported: true),
                       .onDeviceOnly(.notTesterBuild))

        // In an owner build the attested composition adds nothing and touches nothing.
        let rig = Rig(registered: true)
        let (r, decision) = rig.renderer(route: .ownerToken)
        XCTAssertEqual(decision, .omitted(.ownerPathApplies))
        let got40 = await render(r)
        XCTAssertEqual(got40, "device")
        XCTAssertEqual(rig.proxy.total, 0)

        // The owner (Bearer) request is byte-for-byte what it was: Authorization, no install token.
        let owner = FakeProxy()
        let creds = PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "owner-tok")
        let c = PremiumVoiceRoutes.compose(onDevice: [], paidProvidersEnabled: true, access: .allowed,
                                           selectedVoiceID: PremiumVoiceCatalog.voices[0].id, credentials: creds, transport: owner)
        let ownerRoute = try XCTUnwrap(c.routes.first)
        _ = try await ownerRoute.provider.synthesize("Hi", voice: ownerRoute.voice,
                                                      context: RequestContext(stationID: "s", isReusableGeneric: false))
        let sent = try XCTUnwrap(owner.seen.first)
        XCTAssertEqual(sent.header("Authorization"), "Bearer owner-tok")
        XCTAssertNil(sent.header("X-OnAirly-Install-Token"))
        XCTAssertEqual(owner.total, 1)
    }

    func testOwnerBearer401TokenExpiredStillStopsAsBefore() async throws {
        let owner = FakeProxy()
        owner.script(.tts, [.reason(401, "token_expired")])
        let backoff = PaidVoiceBackoff()
        let creds = PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "owner-tok")
        let c = PremiumVoiceRoutes.compose(onDevice: [], paidProvidersEnabled: true, access: .allowed,
                                           selectedVoiceID: PremiumVoiceCatalog.voices[0].id, credentials: creds,
                                           transport: owner, backoff: backoff)
        let ownerRoute = try XCTUnwrap(c.routes.first)
        _ = try? await ownerRoute.provider.synthesize("Hi", voice: ownerRoute.voice,
                                                       context: RequestContext(stationID: "s", isReusableGeneric: false))
        XCTAssertEqual(owner.total, 1, "the owner path never retries")
        XCTAssertTrue(backoff.isStoppedForThisLaunch)
    }

    func testUnsupportedOrNonTesterBuildsComposeOnlyOnDevice() async {
        for (route, reason) in [(CloudVoiceCredentialPolicy.Route.onDeviceOnly(.attestUnsupported), PremiumVoiceRoutes.AttestedOmitReason.attestUnsupported),
                                (.onDeviceOnly(.notTesterBuild), .notTesterBuild)] {
            let rig = Rig(registered: true)
            let (r, decision) = rig.renderer(route: route)
            XCTAssertEqual(decision, .omitted(reason))
            let got41 = await render(r)
            XCTAssertEqual(got41, "device")
            XCTAssertEqual(rig.proxy.total, 0)
        }
    }

    func testAttestedRouteLeavesTheDeviceIsPinnedAndFree() throws {
        let rig = Rig(registered: true)
        let device = [VoiceRoute(providerID: "device", provider: LocalVoice(), voice: VoiceProfile(id: "h", name: "H"))]
        let c = PremiumVoiceRoutes.composeAttested(onDevice: device, route: .installToken, voiceID: PremiumVoiceCatalog.voices[0].id,
                                                   tokens: rig.source, transport: rig.proxy, backoff: rig.backoff)
        let attested = try XCTUnwrap(c.routes.first)
        XCTAssertTrue(attested.leavesDevice)
        XCTAssertFalse(attested.isPaid, "server-capped like the owner route; the app budget is unchanged")
        XCTAssertEqual(attested.timeout, PremiumVoiceRoutes.timeout)
        for bad in ["https://evil.example/api/tts", "http://aerodj-tts.vercel.app/api/tts"] {
            let o = PremiumVoiceRoutes.composeAttested(onDevice: device, route: .installToken, voiceID: PremiumVoiceCatalog.voices[0].id,
                                                       endpoint: URL(string: bad)!, tokens: rig.source, backoff: nil)
            XCTAssertEqual(o.decision, .omitted(.endpointNotAllowed), bad)
        }
        let unknown = PremiumVoiceRoutes.composeAttested(onDevice: device, route: .installToken, voiceID: "nope",
                                                         tokens: rig.source, backoff: nil)
        XCTAssertEqual(unknown.decision, .omitted(.unknownVoice))
    }

    func testTesterVoiceDefaultsToTheSavedPickThenTheCatalogLead() {
        XCTAssertEqual(TesterVoice.voiceID(selected: nil), PremiumVoiceCatalog.voices[0].id)
        XCTAssertEqual(TesterVoice.voiceID(selected: "nope"), PremiumVoiceCatalog.voices[0].id)
        let second = PremiumVoiceCatalog.voices[1].id
        XCTAssertEqual(TesterVoice.voiceID(selected: second), second)
        XCTAssertEqual(TesterVoice.baseURL.host, "aerodj-tts.vercel.app")
        XCTAssertTrue(PremiumVoiceRoutes.allowedHosts.contains(TesterVoice.ttsEndpoint.host!))
    }
}

// MARK: - Consent

final class TesterVoiceConsentReaderTests: XCTestCase {
    func testReadsTheExistingCloudVoiceConsentStore() async throws {
        let suite = "TesterVoiceConsentReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudVoiceConsentStore(defaults: defaults)
        let reader = TesterVoiceConsentReader(store)
        XCTAssertTrue(reader.shouldOfferSheet)
        let undecided = await reader.hasPaidVoiceConsent()
        XCTAssertFalse(undecided)
        store.decline()
        XCTAssertFalse(reader.shouldOfferSheet, "a decline is not asked again by the tester sheet")
        let declined = await reader.hasPaidVoiceConsent()
        XCTAssertFalse(declined)
        store.accept()
        let accepted = await reader.hasPaidVoiceConsent()
        XCTAssertTrue(accepted)
        // Same keys as the store's own sheet and toggle (#258): one stored answer, not two.
        let relaunched = TesterVoiceConsentReader(CloudVoiceConsentStore(defaults: defaults))
        let persisted = await relaunched.hasPaidVoiceConsent()
        XCTAssertTrue(persisted, "persists across launches")
        store.decline()
        let withdrawn = await reader.hasPaidVoiceConsent()
        XCTAssertFalse(withdrawn, "off applies to the next cue")
    }

    func testAnAcceptanceOfOlderCopyIsAskedAgain() async throws {
        let suite = "TesterVoiceConsentReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(CloudVoiceConsentState.accepted.rawValue, forKey: CloudVoiceConsentStore.stateKey)
        defaults.set(CloudVoiceConsentStore.currentVersion - 1, forKey: CloudVoiceConsentStore.versionKey)
        let reader = TesterVoiceConsentReader(CloudVoiceConsentStore(defaults: defaults))
        let granted = await reader.hasPaidVoiceConsent()
        XCTAssertFalse(granted)
        XCTAssertTrue(reader.shouldOfferSheet)
    }
}

// MARK: - Build flag

final class TesterVoiceBuildFlagTests: XCTestCase {
    func testTesterVoiceFollowsTheBuildFlag() {
        #if AERODJ_TESTER_VOICE
        XCTAssertTrue(TesterVoice.enabled)
        XCTAssertEqual(TesterVoice.buildMarker, "AERODJ_TESTER_VOICE_ATTEST_BUILD")
        #else
        XCTAssertFalse(TesterVoice.enabled, "Release and Debug builds have no attested route")
        #endif
    }
}
