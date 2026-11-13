import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP seam so the proxy client is testable without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceRenderError.invalidResponse("not HTTP") }
        return (data, http)
    }
}

/// Paid cloud voices (Cartesia, ElevenLabs) through AeroDJ's own backend.
///
/// The app never holds a provider API key. It sends the user's *session*
/// token to a known HTTPS host; the backend authenticates the user, enforces
/// the per-user daily cap server-side, calls the provider with its own key,
/// measures the audio, and returns it with `X-Audio-Duration`.
///
/// **Not enabled anywhere by default.** No backend route is deployed; turning
/// this on adds a paid operating cost and needs an owner decision.
public struct ProxyVoiceProvider: VoiceProvider {
    public enum Upstream: String, Codable, Sendable { case cartesia, elevenlabs }

    public struct Configuration: Sendable {
        public let endpoint: URL
        public let upstream: Upstream
        public let maxResponseBytes: Int
        public let sessionToken: @Sendable () async throws -> String
        /// Set only for the App Attest tester route (#378): requests carry `X-OnAirly-Install-Token`
        /// and never `Authorization`, and `sessionToken` is not read. Nil keeps the owner-token path.
        public let installTokens: (any InstallTokenProviding)?

        /// Throws `insecureEndpoint` unless `endpoint` is HTTPS on an allowed host.
        public init(endpoint: URL, allowedHosts: Set<String>, upstream: Upstream, maxResponseBytes: Int = 5_000_000,
                    sessionToken: @escaping @Sendable () async throws -> String) throws {
            try self.init(endpoint: endpoint, allowedHosts: allowedHosts, upstream: upstream,
                          maxResponseBytes: maxResponseBytes, sessionToken: sessionToken, installTokens: nil)
        }

        /// The attested tester route (#378): same host pin, install token instead of a session token.
        public init(endpoint: URL, allowedHosts: Set<String>, upstream: Upstream, maxResponseBytes: Int = 5_000_000,
                    installTokens: any InstallTokenProviding) throws {
            try self.init(endpoint: endpoint, allowedHosts: allowedHosts, upstream: upstream,
                          maxResponseBytes: maxResponseBytes,
                          sessionToken: { throw VoiceRenderError.insecureEndpoint }, installTokens: installTokens)
        }

        private init(endpoint: URL, allowedHosts: Set<String>, upstream: Upstream, maxResponseBytes: Int,
                     sessionToken: @escaping @Sendable () async throws -> String,
                     installTokens: (any InstallTokenProviding)?) throws {
            guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host?.lowercased(),
                  allowedHosts.contains(host), endpoint.user == nil, endpoint.password == nil else {
                throw VoiceRenderError.insecureEndpoint
            }
            self.endpoint = endpoint
            self.upstream = upstream
            self.maxResponseBytes = maxResponseBytes
            self.sessionToken = sessionToken
            self.installTokens = installTokens
        }
    }

    /// The tester route's credential header (#378 §1.1 step 5).
    public static let installTokenHeader = "X-OnAirly-Install-Token"

    public let configuration: Configuration
    private let transport: any HTTPTransport
    /// Optional 429 / 5xx backoff. Nil keeps the old behavior: every call goes to the proxy.
    public let backoff: PaidVoiceBackoff?

    public init(configuration: Configuration, transport: any HTTPTransport = URLSessionTransport(),
                backoff: PaidVoiceBackoff? = nil) {
        self.configuration = configuration
        self.transport = transport
        self.backoff = backoff
    }

    public func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        // Suspended after a 429 or 5xx: fail before the token read or any network call, so
        // `VoiceRenderer` goes straight to the next (on-device) route.
        if backoff?.suspendedUntil() != nil { throw VoiceRenderError.suspended }
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var installToken: InstallToken?
        if let installTokens = configuration.installTokens {
            // Tester route: the install token only. Never both credentials (400 `mixed_auth`).
            let token = try await installTokens.installToken()
            installToken = token
            request.setValue(token.headerValue, forHTTPHeaderField: Self.installTokenHeader)
        } else {
            request.setValue("Bearer \(try await configuration.sessionToken())", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode([
            "upstream": configuration.upstream.rawValue, "voiceId": voice.id, "text": text,
            "format": text.hasPrefix("<speak>") ? "ssml" : "text", "stationId": context.stationID,
        ])
        var (data, response) = try await send(request)
        let tokenExpired = response.statusCode == 401 && installToken != nil
            && PaidVoiceBackoff.ProxyErrorReason.parse(data) == .tokenExpired
        if tokenExpired, let installTokens = configuration.installTokens, let installToken {
            // #380: `token_expired` covers every install-token failure. Re-mint once for this cue;
            // a freshly minted token refused again stops the route for the launch (below), so
            // there is never a mint loop.
            await installTokens.tokenRejected(installToken)
            let fresh = try await installTokens.installToken()
            request.setValue(fresh.headerValue, forHTTPHeaderField: Self.installTokenHeader)
            (data, response) = try await send(request)
        }
        if let installTokens = configuration.installTokens {
            await recordInstallAnswer(response, data: data, installTokens: installTokens)
        } else {
            recordOwnerAnswer(response, data: data)
        }
        guard response.statusCode == 200 else { throw VoiceRenderError.invalidResponse("status \(response.statusCode)") }
        guard let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(), type.hasPrefix("audio/") else {
            throw VoiceRenderError.invalidResponse("content type")
        }
        guard !data.isEmpty, data.count <= configuration.maxResponseBytes else { throw VoiceRenderError.invalidResponse("size") }
        guard let header = response.value(forHTTPHeaderField: "X-Audio-Duration"), let seconds = Double(header),
              seconds.isFinite, seconds > 0, seconds <= 600 else {
            throw VoiceRenderError.invalidResponse("duration")
        }
        backoff?.recordSuccess()
        let billed = response.value(forHTTPHeaderField: "X-Billed-Characters").flatMap(Int.init) ?? text.count
        return VoiceArtifact(data: data, durationSeconds: seconds, billableUnits: billed,
                             provider: configuration.upstream.rawValue, cacheKey: nil)
    }

    /// The owner (Bearer) path's answer handling, unchanged from before #378.
    private func recordOwnerAnswer(_ response: HTTPURLResponse, data: Data) {
        switch response.statusCode {
        case 200: break  // counted as a success only once the audio below is validated
        case 401: backoff?.recordUnauthorized()
        case 429:
            backoff?.recordRateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                                       reason: PaidVoiceBackoff.ProxyErrorReason.parse(data))
        case 503:
            backoff?.recordServiceUnavailable(retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                                              reason: PaidVoiceBackoff.ProxyErrorReason.parse(data))
        case 500...599: backoff?.recordServerFailure()
        default: break
        }
    }

    /// The install-token path (#380 contract). Every refusal sends the cue on-device and none
    /// can hot-loop: 429 and 503 honor Retry-After (daily caps: next UTC midnight); 401
    /// (including a re-minted token refused again), 403 and `mixed_auth` stop the route for the
    /// launch; 401 `reattest` hands the key back to the token source (register again at most
    /// once per launch, then it stops); other 4xx (400, 413) and 5xx (500 `misconfig`) back off.
    private func recordInstallAnswer(_ response: HTTPURLResponse, data: Data,
                                     installTokens: any InstallTokenProviding) async {
        let reason = PaidVoiceBackoff.ProxyErrorReason.parse(data)
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        switch response.statusCode {
        case 200: break  // counted as a success only once the audio below is validated
        case 401 where reason == .reattest: await installTokens.keyRejected()
        case 401, 403: backoff?.recordUnauthorized()
        case 400 where reason == .mixedAuth: backoff?.recordUnauthorized()
        case 429: backoff?.recordRateLimited(retryAfter: retryAfter, reason: reason)
        case 503: backoff?.recordServiceUnavailable(retryAfter: retryAfter, reason: reason)
        default: backoff?.recordServerFailure()
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            // Caller cancellation or our own timeout (which cancels this task) is not a proxy failure.
            if !(error is CancellationError) && !Task.isCancelled { backoff?.recordServerFailure() }
            throw error
        }
    }
}
