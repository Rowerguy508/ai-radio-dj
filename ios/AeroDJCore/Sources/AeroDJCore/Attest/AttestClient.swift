import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal App Attest client for the aerodj-tts attest endpoints (#256 server, #270 install
/// cap; -Fry). It only builds the two requests and maps their answers. Talking to
/// `DCAppAttestService` (key, attestation) is the caller's job (PR 5); nothing calls this
/// in the app yet, and attestation is off on the server.
///
/// `installId` goes on POST /api/attest/register only. The challenge request never carries
/// it (the server rejects unknown fields there with 400 `bad_request`).
/// Every failure is quiet: the caller keeps the on-device voice and shows nothing. Logs carry
/// enums and status codes only, never the install ID, key ID, challenge, attestation or body.
public struct AttestClient: Sendable {
    public enum Endpoint: String, Sendable { case challenge, register }

    /// A failed attest call. All are quiet (no alert, on-device voice); `retryAfterSeconds` is the
    /// server's hint where it sent one.
    public struct Failure: Error, Equatable, Sendable {
        public enum Reason: String, Sendable, CaseIterable {
            // Server reasons (register-handler.ts / challenge-handler.ts).
            case badRequest = "bad_request", tooLarge = "too_large", misconfig, store, disabled, assertion
            case challengeExpired = "challenge_expired", network, install, enroll
            // Local.
            case noInstallID = "no_install_id", transport, unexpected
        }
        public let reason: Reason
        public let status: Int?
        public let retryAfterSeconds: Int?
        /// Every attest failure is quiet: no user-facing error, the paid route just stays off.
        public var isQuiet: Bool { true }
    }

    /// One log line: enums and a status code only.
    public struct LogEntry: Equatable, Sendable {
        public let endpoint: Endpoint
        public let status: Int?
        public let reason: Failure.Reason?
    }

    public let baseURL: URL
    private let transport: any HTTPTransport
    private let installID: AttestInstallID
    private let log: @Sendable (LogEntry) -> Void

    /// nil unless `baseURL` is HTTPS on a pinned host (the same pin as the voice proxy).
    public init?(baseURL: URL, transport: any HTTPTransport, installID: AttestInstallID,
                 pinnedHosts: Set<String> = PremiumVoiceRoutes.allowedHosts,
                 log: @escaping @Sendable (LogEntry) -> Void = { _ in }) {
        guard baseURL.scheme == "https", let host = baseURL.host,
              PremiumVoiceRoutes.isAllowed(host: host, pinned: pinnedHosts) else { return nil }
        self.baseURL = baseURL
        self.transport = transport
        self.installID = installID
        self.log = log
    }

    // MARK: Requests

    private struct ChallengeBody: Encodable { let purpose: String; let keyId: String? }
    private struct RegisterBody: Encodable { let keyId: String; let attestationObject: String; let challenge: String
                                             let installId: String }

    private func post(_ path: String, _ body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// POST /api/attest/challenge `{ purpose: "attest", keyId? }`. No install ID.
    func challengeRequest(keyId: String? = nil) throws -> URLRequest {
        try post("api/attest/challenge", ChallengeBody(purpose: "attest", keyId: keyId))
    }

    /// POST /api/attest/register `{ keyId, attestationObject, challenge, installId }`.
    func registerRequest(keyId: String, attestationObject: String, challenge: String,
                         installID: AttestInstallIdentifier) throws -> URLRequest {
        try post("api/attest/register", RegisterBody(keyId: keyId, attestationObject: attestationObject,
                                                     challenge: challenge, installId: installID.rawValue))
    }

    // MARK: Calls

    /// A fresh `attest` challenge, or a quiet failure.
    public func challenge(keyId: String? = nil) async -> Result<String, Failure> {
        guard let request = try? challengeRequest(keyId: keyId) else {
            return .failure(fail(.challenge, Failure(reason: .unexpected, status: nil, retryAfterSeconds: nil)))
        }
        switch await send(request) {
        case .failure(let f): return .failure(fail(.challenge, f))
        case .success(let (data, response)):
            guard response.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let challenge = object["challenge"] as? String, !challenge.isEmpty else {
                return .failure(fail(.challenge, Self.failure(status: response.statusCode, data: data, response: response)))
            }
            log(LogEntry(endpoint: .challenge, status: 200, reason: nil))
            return .success(challenge)
        }
    }

    /// Registers the attested key with this install's ID. 204 → success; anything else,
    /// including 400 `install`, is a quiet failure. Without an install ID nothing is sent.
    public func register(keyId: String, attestationObject: String, challenge: String) async -> Result<Void, Failure> {
        guard let id = installID.current() else {
            return .failure(fail(.register, Failure(reason: .noInstallID, status: nil, retryAfterSeconds: nil)))
        }
        guard let request = try? registerRequest(keyId: keyId, attestationObject: attestationObject,
                                                 challenge: challenge, installID: id) else {
            return .failure(fail(.register, Failure(reason: .unexpected, status: nil, retryAfterSeconds: nil)))
        }
        switch await send(request) {
        case .failure(let f): return .failure(fail(.register, f))
        case .success(let (data, response)):
            guard response.statusCode == 204 else {
                return .failure(fail(.register, Self.failure(status: response.statusCode, data: data, response: response)))
            }
            log(LogEntry(endpoint: .register, status: 204, reason: nil))
            return .success(())
        }
    }

    private func send(_ request: URLRequest) async -> Result<(Data, HTTPURLResponse), Failure> {
        do { return .success(try await transport.send(request)) }
        catch { return .failure(Failure(reason: .transport, status: nil, retryAfterSeconds: nil)) }
    }

    private func fail(_ endpoint: Endpoint, _ failure: Failure) -> Failure {
        log(LogEntry(endpoint: endpoint, status: failure.status, reason: failure.reason))
        return failure
    }

    /// Maps a non-success answer. The reason must be a known server reason AND match its
    /// status (400 `install`, 429 `enroll`, ...); anything else is `.unexpected`.
    static func failure(status: Int, data: Data, response: HTTPURLResponse) -> Failure {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let retry = (response.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
            ?? (object?["retryAfterSeconds"] as? Int)
        let expected: [Failure.Reason: Int] = [.badRequest: 400, .challengeExpired: 400, .network: 400, .install: 400,
                                                .assertion: 401, .tooLarge: 413, .enroll: 429, .misconfig: 500,
                                                .store: 503, .disabled: 503]
        guard let raw = object?["reason"] as? String, let reason = Failure.Reason(rawValue: raw),
              expected[reason] == status else {
            return Failure(reason: .unexpected, status: status, retryAfterSeconds: retry)
        }
        return Failure(reason: reason, status: status, retryAfterSeconds: retry)
    }
}
