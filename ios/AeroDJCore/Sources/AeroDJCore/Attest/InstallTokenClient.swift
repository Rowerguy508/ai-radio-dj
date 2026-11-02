import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A 30-minute install token for the voice proxy (#378 §1.3). In memory only, never on disk.
/// Its descriptions are redacted, so interpolation, `print`, `dump` or a log line can't show it;
/// only the `/api/tts` request header reads `value`.
public struct InstallToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    let value: String
    /// Local expiry: request start + the server's `expiresIn`, so local clock skew only shortens it.
    public let expiresAt: Date
    public init(value: String, expiresAt: Date) { self.value = value; self.expiresAt = expiresAt }
    public var description: String { "InstallToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    /// The value for the `X-OnAirly-Install-Token` header.
    public var headerValue: String { value }
}

/// Requests and answers for the install-token mint (#378 §1.1 steps 3 and 4), against Sentinel's
/// server PR. Builds requests and parses answers only; `InstallTokenSource` drives it.
///
/// Contract (from #378; the token endpoint is not in the repo yet, see the PR's assumptions):
/// - `POST /api/attest/challenge` `{purpose:"tok", keyId}` + `X-OnAirly-Key: <keyId>` →
///   200 `{challenge, expiresIn:120}`. The key ID goes in the body (the existing handler's
///   `keyId` field binds it into the MAC) and in the header (#378's table); both are the same value.
/// - `POST /api/attest/token` `{challenge}` + `X-OnAirly-Key` + `X-OnAirly-Assertion` (standard
///   base64 of the assertion CBOR) → 200 `{token, expiresIn:1800}`.
/// - Assertion `clientData = "onairly-tok-v1\n" + challenge + "\n" + hex(sha256(rawBody))`;
///   the device signs `clientDataHash = SHA-256(clientData)`.
/// - Never sends `Authorization` (400 `mixed_auth`), the install ID, or any DJ text.
public struct InstallTokenClient: Sendable {
    public static let clientDataPrefix = "onairly-tok-v1"
    public static let keyHeader = "X-OnAirly-Key"
    public static let assertionHeader = "X-OnAirly-Assertion"
    /// Accepted `expiresIn` range: 60 s to 1 h (#378 keeps tokens inside 15 to 60 minutes).
    public static let expiresInRange: ClosedRange<Int> = 60...3600
    /// Short: a mint runs while a break is being prepared and must never hold it up for long.
    public static let requestTimeout: TimeInterval = 8

    /// A failed challenge or mint. No payload beyond the enum, status and Retry-After.
    public struct Failure: Error, Equatable, Sendable {
        public enum Reason: String, Sendable, CaseIterable {
            case badRequest = "bad_request", mixedAuth = "mixed_auth", challengeExpired = "challenge_expired"
            case tooLarge = "too_large", assertion, reattest, noEntitlement = "no_entitlement", rate
            case misconfig, store, disabled
            case transport, unexpected
        }
        public let reason: Reason
        public let status: Int?
        /// The raw `Retry-After` header (or `retryAfterSeconds` from the body), for `PaidVoiceBackoff`.
        public let retryAfter: String?
        public init(reason: Reason, status: Int?, retryAfter: String?) {
            self.reason = reason; self.status = status; self.retryAfter = retryAfter
        }
    }

    public let baseURL: URL
    private let transport: any HTTPTransport

    /// nil unless `baseURL` is HTTPS on a pinned host (the voice proxy's pin), with no userinfo.
    public init?(baseURL: URL, transport: any HTTPTransport, pinnedHosts: Set<String> = PremiumVoiceRoutes.allowedHosts) {
        guard baseURL.scheme?.lowercased() == "https", let host = baseURL.host,
              PremiumVoiceRoutes.isAllowed(host: host, pinned: pinnedHosts),
              baseURL.user == nil, baseURL.password == nil else { return nil }
        self.baseURL = baseURL
        self.transport = transport
    }

    // MARK: Requests (pure)

    func challengeRequest(keyId: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/attest/challenge"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(keyId, forHTTPHeaderField: Self.keyHeader)
        struct Body: Encodable { let purpose: String; let keyId: String }
        request.httpBody = try JSONEncoder().encode(Body(purpose: "tok", keyId: keyId))
        return request
    }

    /// The exact bytes POSTed to `/api/attest/token`. The assertion covers their SHA-256, so the
    /// request must send these bytes and no others. nil for a challenge outside base64url.
    public static func tokenBody(challenge: String) -> Data? {
        guard !challenge.isEmpty, challenge.utf8.count <= 128,
              challenge.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return Data("{\"challenge\":\"\(challenge)\"}".utf8)
    }

    /// `"onairly-tok-v1\n" + challenge + "\n" + hex(sha256(body))`.
    public static func assertionClientData(challenge: String, body: Data) -> Data {
        Data("\(clientDataPrefix)\n\(challenge)\n\(AttestHash.sha256Hex(body))".utf8)
    }

    /// What the device signs: SHA-256 of `assertionClientData`.
    public static func assertionClientDataHash(challenge: String, body: Data) -> Data {
        AttestHash.sha256(assertionClientData(challenge: challenge, body: body))
    }

    func tokenRequest(keyId: String, body: Data, assertion: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/attest/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(keyId, forHTTPHeaderField: Self.keyHeader)
        request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: Self.assertionHeader)
        request.httpBody = body
        return request
    }

    // MARK: Calls

    /// A `tok` challenge bound to `keyId`.
    public func challenge(keyId: String) async -> Result<String, Failure> {
        guard let request = try? challengeRequest(keyId: keyId) else {
            return .failure(Failure(reason: .unexpected, status: nil, retryAfter: nil))
        }
        switch await send(request) {
        case .failure(let failure): return .failure(failure)
        case .success(let (data, response)):
            guard response.statusCode == 200 else { return .failure(Self.failure(status: response.statusCode, data: data, response: response)) }
            guard let object = Self.jsonObject(data), let challenge = object["challenge"] as? String,
                  Self.tokenBody(challenge: challenge) != nil else {
                return .failure(Failure(reason: .unexpected, status: 200, retryAfter: nil))
            }
            return .success(challenge)
        }
    }

    /// Mints a token with an assertion over `body` (from `tokenBody(challenge:)`). `startedAt` is
    /// taken before the request, so the local expiry is never later than the server's.
    public func mint(keyId: String, body: Data, assertion: Data, startedAt: Date) async -> Result<InstallToken, Failure> {
        switch await send(tokenRequest(keyId: keyId, body: body, assertion: assertion)) {
        case .failure(let failure): return .failure(failure)
        case .success(let (data, response)):
            guard response.statusCode == 200 else { return .failure(Self.failure(status: response.statusCode, data: data, response: response)) }
            guard let token = Self.parseToken(data, startedAt: startedAt) else {
                return .failure(Failure(reason: .unexpected, status: 200, retryAfter: nil))
            }
            return .success(token)
        }
    }

    // MARK: Parsing (pure)

    /// `{token, expiresIn}`: a non-empty printable-ASCII token of at most 2 KiB (it becomes a header
    /// value, so no spaces or control characters) and `expiresIn` inside `expiresInRange`.
    static func parseToken(_ data: Data, startedAt: Date) -> InstallToken? {
        guard let object = jsonObject(data), let value = object["token"] as? String,
              !value.isEmpty, value.utf8.count <= 2048,
              value.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }),
              let expiresIn = (object["expiresIn"] as? NSNumber)?.intValue,
              expiresInRange.contains(expiresIn) else { return nil }
        return InstallToken(value: value, expiresAt: startedAt.addingTimeInterval(TimeInterval(expiresIn)))
    }

    /// A non-200 answer. The reason must be a known server reason AND match its status;
    /// anything else is `.unexpected` (which the source treats as a hard stop for this launch).
    static func failure(status: Int, data: Data, response: HTTPURLResponse) -> Failure {
        let object = jsonObject(data)
        let retry = response.value(forHTTPHeaderField: "Retry-After")
            ?? (object?["retryAfterSeconds"] as? NSNumber).map { String($0.intValue) }
        let expected: [Failure.Reason: Int] = [
            .badRequest: 400, .mixedAuth: 400, .challengeExpired: 400, .tooLarge: 413,
            .assertion: 401, .reattest: 401, .noEntitlement: 403, .rate: 429,
            .misconfig: 500, .store: 503, .disabled: 503,
        ]
        guard let raw = object?["reason"] as? String, let reason = Failure.Reason(rawValue: raw),
              expected[reason] == status else {
            return Failure(reason: .unexpected, status: status, retryAfter: retry)
        }
        return Failure(reason: reason, status: status, retryAfter: retry)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= 8192 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func send(_ request: URLRequest) async -> Result<(Data, HTTPURLResponse), Failure> {
        do { return .success(try await transport.send(request)) }
        catch { return .failure(Failure(reason: .transport, status: nil, retryAfter: nil)) }
    }
}
