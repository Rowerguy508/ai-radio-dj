import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
import XCTest
@testable import AeroDJCore

// App-side `installId` for attest register (Atlas's #270 contract). In-process fakes only:
// no network, no server, no Keychain, no App Attest. -Fry

/// Records every request; answers each with `status` and an optional JSON body.
private final class AttestSpyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    var status: Int
    var body: [String: Any]?
    var headers: [String: String]
    var throwsError = false
    init(status: Int = 204, body: [String: Any]? = nil, headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.headers = headers
    }
    var requests: [URLRequest] { lock.withLock { sent } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        if throwsError { throw URLError(.notConnectedToInternet) }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var h = headers; h["Content-Type"] = "application/json"
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: h)!)
    }
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [AttestClient.LogEntry] = []
    var entries: [AttestClient.LogEntry] { lock.withLock { lines } }
    func append(_ e: AttestClient.LogEntry) { lock.withLock { lines.append(e) } }
}

final class AttestInstallIDTests: XCTestCase {
    private let base = URL(string: "https://aerodj-tts.vercel.app")!
    private let v4 = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    private func json(_ r: URLRequest) -> [String: Any] {
        (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private func client(_ t: AttestSpyTransport, _ id: AttestInstallID = AttestInstallID(storage: InMemoryAttestInstallIDStorage()),
                        log: LogSink = LogSink()) -> AttestClient {
        AttestClient(baseURL: base, transport: t, installID: id, log: { log.append($0) })!
    }

    // MARK: The ID

    func testInstallIDIsStableAcrossCallsAndReloads() {
        let storage = InMemoryAttestInstallIDStorage()
        let a = AttestInstallID(storage: storage).current()
        XCTAssertNotNil(a)
        XCTAssertEqual(AttestInstallID(storage: storage).current(), a, "same ID from a new instance (a relaunch)")
        let id = AttestInstallID(storage: storage)
        XCTAssertEqual((0..<20).map { _ in id.current() }, Array(repeating: a, count: 20))
        XCTAssertEqual(storage.readInstallID(), a?.rawValue, "stored once")
    }

    func testInstallIDIsALowercase36CharacterRandomV4() {
        var seen = Set<String>()
        for _ in 0..<200 {
            guard let id = AttestInstallID(storage: InMemoryAttestInstallIDStorage()).current()?.rawValue else {
                return XCTFail("no ID")
            }
            XCTAssertEqual(id.count, 36)
            XCTAssertEqual(id, id.lowercased())
            XCTAssertNotNil(id.range(of: v4, options: .regularExpression), id)
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 200, "random per install")
        for bad in ["", "6BA7B810-9DAD-41D1-80B4-00C04FD430C8", "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
                    "6ba7b810-9dad-41d1-c0b4-00c04fd430c8", "6ba7b8109dad41d180b400c04fd430c8",
                    " 6ba7b810-9dad-41d1-80b4-00c04fd430c8", "6ba7b810-9dad-41d1-80b4-00c04fd430c8\n"] {
            XCTAssertFalse(AttestInstallIdentifier.isValid(bad), bad)
        }
        XCTAssertTrue(AttestInstallIdentifier.isValid("6ba7b810-9dad-41d1-80b4-00c04fd430c8"))
    }

    func testAnInvalidStoredValueIsReplacedAndAnUnstorableIDIsNotSent() async {
        let storage = InMemoryAttestInstallIDStorage("6BA7B810-9DAD-41D1-80B4-00C04FD430C8")
        let fixed = UUID(uuidString: "0f8fad5b-d9cb-469f-a165-70867728950e")!
        let replaced = AttestInstallID(storage: storage, generate: { fixed }).current()
        XCTAssertEqual(replaced?.rawValue, "0f8fad5b-d9cb-469f-a165-70867728950e")
        XCTAssertEqual(storage.readInstallID(), "0f8fad5b-d9cb-469f-a165-70867728950e")

        let t = AttestSpyTransport()
        let c = client(t, AttestInstallID(storage: InMemoryAttestInstallIDStorage(failsWrites: true)))
        let r = await c.register(keyId: "k", attestationObject: "a", challenge: "c")
        XCTAssertEqual(r.failureValue?.reason, .noInstallID)
        XCTAssertEqual(r.failureValue?.isQuiet, true)
        XCTAssertTrue(t.requests.isEmpty, "no register without a stored ID (it would change every launch)")
    }

    func testTheIDCarriesNoDeviceData() throws {
        let source = try self.source("Attest/AttestInstallID.swift")
        for banned in ["UIDevice", "identifierForVendor", "ASIdentifierManager", "advertisingIdentifier", "sysctl",
                       "utsname", "ProcessInfo", "hostName", "UserDefaults"] {
            XCTAssertFalse(source.contains(banned), banned)
        }
        XCTAssertTrue(source.contains("generate: @escaping @Sendable () -> UUID = { UUID() }"), "random UUID only")
    }

    // MARK: Keychain

    func testLiveStorageIsAThisDeviceOnlyKeychainItem() throws {
        XCTAssertEqual(AttestInstallIDKeychain.accessibilityName, "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly")
        XCTAssertTrue(AttestInstallIDKeychain.accessibilityName.hasSuffix("ThisDeviceOnly"))
        let code = try self.source("Attest/AttestInstallID.swift").split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertTrue(code.contains("{ kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }"))
        XCTAssertTrue(code.contains("q[kSecAttrAccessible as String] = accessibility"))
        XCTAssertTrue(code.contains("kSecAttrSynchronizable as String: kCFBooleanFalse"))
        XCTAssertTrue(code.contains("AttestInstallID(storage: KeychainAttestInstallIDStorage())"), "live() uses the Keychain")
        for banned in ["kSecAttrAccessibleAlways", "kSecAttrAccessibleAfterFirstUnlock }", "kSecAttrAccessibleWhenUnlocked }"] {
            XCTAssertFalse(code.contains(banned), banned)
        }
        #if canImport(Security)
        let attrs = KeychainAttestInstallIDStorage.addAttributes("x")
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attrs[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, AttestInstallIDKeychain.service)
        #endif
    }

    // MARK: On register only

    func testRegisterSendsExactlyTheFourFieldsWithTheLowercaseInstallID() async throws {
        let t = AttestSpyTransport(status: 204)
        let id = AttestInstallID(storage: InMemoryAttestInstallIDStorage())
        let r = await client(t, id).register(keyId: "a2V5", attestationObject: "YXR0", challenge: "Y2hs")
        XCTAssertNotNil(try? r.get())
        let request = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://aerodj-tts.vercel.app/api/attest/register")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = json(request)
        XCTAssertEqual(Set(body.keys), ["keyId", "attestationObject", "challenge", "installId"], "no extra fields")
        let sent = try XCTUnwrap(body["installId"] as? String)
        XCTAssertEqual(sent, id.current()?.rawValue)
        XCTAssertEqual(sent.count, 36)
        XCTAssertNotNil(sent.range(of: v4, options: .regularExpression))
        _ = await client(t, id).register(keyId: "a2V5", attestationObject: "YXR0", challenge: "Y2hs")
        XCTAssertEqual(json(t.requests[1])["installId"] as? String, sent, "the same ID on every register")
    }

    func testTheInstallIDIsAbsentFromEveryOtherRequest() async throws {
        let t = AttestSpyTransport(status: 200, body: ["challenge": "Y2hs", "expiresIn": 300])
        let id = AttestInstallID(storage: InMemoryAttestInstallIDStorage())
        let raw = try XCTUnwrap(id.current()?.rawValue)
        let c = client(t, id)
        _ = await c.challenge()
        _ = await c.challenge(keyId: "a2V5")
        t.status = 204; t.body = nil
        _ = await c.register(keyId: "a2V5", attestationObject: "YXR0", challenge: "Y2hs")
        // The voice proxy request is another request the app sends.
        let proxyT = AttestSpyTransport(status: 200)
        let config = try XCTUnwrap(PremiumVoiceRoutes.proxyConfiguration(
            endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "t", pinnedHosts: PremiumVoiceRoutes.allowedHosts))
        _ = try? await ProxyVoiceProvider(configuration: config, transport: proxyT)
            .synthesize("Hi", voice: VoiceProfile(id: PremiumVoiceCatalog.voices[0].id, name: "v"),
                        context: RequestContext(stationID: "s", isReusableGeneric: false))
        let others = t.requests.filter { $0.url?.path != "/api/attest/register" } + proxyT.requests
        XCTAssertEqual(others.count, 3)
        for r in others {
            let wire = (r.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "") + (r.url?.absoluteString ?? "")
                + "\(r.allHTTPHeaderFields ?? [:])"
            XCTAssertFalse(wire.contains(raw), "\(r.url?.path ?? ""): no install ID value")
            XCTAssertFalse(wire.lowercased().contains("installid"), "\(r.url?.path ?? ""): no installId field")
        }
        XCTAssertEqual(Set(json(t.requests[0]).keys), ["purpose"])
        XCTAssertEqual(Set(json(t.requests[1]).keys), ["purpose", "keyId"])
        XCTAssertEqual(t.requests.filter { $0.url?.path == "/api/attest/register" }.count, 1)
        // Only the register body builder names the field.
        let sources = try ["Attest/AttestClient.swift", "Voice/ProxyVoiceProvider.swift"].map(self.source)
        XCTAssertEqual(sources[0].components(separatedBy: "let installId: String").count - 1, 1)
        XCTAssertFalse(sources[1].contains("installId"))
    }

    // MARK: Not logged

    func testTheInstallIDIsNeverLoggedOrPrinted() async throws {
        let id = AttestInstallID(storage: InMemoryAttestInstallIDStorage())
        let value = try XCTUnwrap(id.current())
        let raw = value.rawValue
        var dumped = ""
        dump(value, to: &dumped)
        for shown in ["\(value)", String(describing: value), String(reflecting: value), dumped, "\(Optional(value) as Any)"] {
            XCTAssertFalse(shown.contains(raw), shown)
        }
        let sink = LogSink()
        let t = AttestSpyTransport(status: 400, body: ["error": "Bad request", "reason": "install"])
        let c = client(t, id, log: sink)
        let failed = await c.register(keyId: "a2V5", attestationObject: "YXR0", challenge: "Y2hs")
        t.status = 204; t.body = nil
        _ = await c.register(keyId: "a2V5", attestationObject: "YXR0", challenge: "Y2hs")
        t.throwsError = true
        _ = await c.register(keyId: "a2V5", attestationObject: "YXR0", challenge: "Y2hs")
        XCTAssertEqual(sink.entries, [.init(endpoint: .register, status: 400, reason: .install),
                                      .init(endpoint: .register, status: 204, reason: nil),
                                      .init(endpoint: .register, status: nil, reason: .transport)])
        var everything = sink.entries.map { "\($0)" }.joined()
        dump(sink.entries, to: &everything)
        dump(failed, to: &everything)
        everything += "\(failed)" + String(reflecting: failed)
        XCTAssertFalse(everything.contains(raw), "no install ID in any log entry or error")
        let source = try self.source("Attest/AttestClient.swift") + self.source("Attest/AttestInstallID.swift")
        for banned in ["print(", "NSLog", "os_log", "Logger(", "debugPrint"] { XCTAssertFalse(source.contains(banned), banned) }
    }

    // MARK: 400 install is a quiet failure, like the other attest errors

    func testFourHundredInstallIsAQuietFailureLikeTheOtherAttestErrors() async {
        let cases: [(Int, String?, AttestClient.Failure.Reason)] = [
            (400, "install", .install), (400, "network", .network), (400, "bad_request", .badRequest),
            (400, "challenge_expired", .challengeExpired), (401, "assertion", .assertion), (413, "too_large", .tooLarge),
            (429, "enroll", .enroll), (500, "misconfig", .misconfig), (503, "store", .store), (503, "disabled", .disabled),
            (401, "install", .unexpected), (400, "enroll", .unexpected), (400, nil, .unexpected), (418, "teapot", .unexpected),
            (200, nil, .unexpected),
        ]
        for (status, reason, expected) in cases {
            let t = AttestSpyTransport(status: status, body: reason.map { ["error": "x", "reason": $0, "requestId": "r"] })
            let r = await client(t).register(keyId: "a2V5", attestationObject: "YXR0", challenge: "Y2hs")
            let name = "\(status) \(reason ?? "-")"
            XCTAssertEqual(r.failureValue?.reason, expected, name)
            XCTAssertEqual(r.failureValue?.status, status, name)
            XCTAssertEqual(r.failureValue?.isQuiet, true, name)
            XCTAssertEqual(t.requests.count, 1, "\(name): one call, no automatic retry")
        }
        let install = await client(AttestSpyTransport(status: 400, body: ["reason": "install"]))
            .register(keyId: "k", attestationObject: "a", challenge: "c")
        XCTAssertNil(install.failureValue?.retryAfterSeconds, "400 install: no Retry-After")
        let enroll = await client(AttestSpyTransport(status: 429, body: ["reason": "enroll", "retryAfterSeconds": 60],
                                                     headers: ["Retry-After": "120"]))
            .register(keyId: "k", attestationObject: "a", challenge: "c")
        XCTAssertEqual(enroll.failureValue?.retryAfterSeconds, 120)
        let down = AttestSpyTransport(); down.throwsError = true
        let offline = await client(down).register(keyId: "k", attestationObject: "a", challenge: "c")
        XCTAssertEqual(offline.failureValue, AttestClient.Failure(reason: .transport, status: nil, retryAfterSeconds: nil))
    }

    func testTheClientOnlyTalksToThePinnedHostOverHTTPS() {
        let id = AttestInstallID(storage: InMemoryAttestInstallIDStorage())
        for bad in ["http://aerodj-tts.vercel.app", "https://evil.example", "https://aerodj-tts.vercel.app.evil.example"] {
            XCTAssertNil(AttestClient(baseURL: URL(string: bad)!, transport: AttestSpyTransport(), installID: id), bad)
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/AeroDJCore/" + path), encoding: .utf8)
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { return f }; return nil }
}
