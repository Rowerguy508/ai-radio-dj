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

        /// Throws `insecureEndpoint` unless `endpoint` is HTTPS on an allowed host.
        public init(endpoint: URL, allowedHosts: Set<String>, upstream: Upstream, maxResponseBytes: Int = 5_000_000,
                    sessionToken: @escaping @Sendable () async throws -> String) throws {
            guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host?.lowercased(),
                  allowedHosts.contains(host), endpoint.user == nil, endpoint.password == nil else {
                throw VoiceRenderError.insecureEndpoint
            }
            self.endpoint = endpoint
            self.upstream = upstream
            self.maxResponseBytes = maxResponseBytes
            self.sessionToken = sessionToken
        }
    }

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
        request.setValue("Bearer \(try await configuration.sessionToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode([
            "upstream": configuration.upstream.rawValue, "voiceId": voice.id, "text": text,
            "format": text.hasPrefix("<speak>") ? "ssml" : "text", "stationId": context.stationID,
        ])
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            // Caller cancellation or our own timeout (which cancels this task) is not a proxy failure.
            if !(error is CancellationError) && !Task.isCancelled { backoff?.recordServerFailure() }
            throw error
        }
        if response.statusCode != 200, let backoff {
            Self.record(status: response.statusCode, body: data,
                        retryAfter: response.value(forHTTPHeaderField: "Retry-After"), in: backoff)
        }
        guard response.statusCode == 200 else { throw VoiceRenderError.invalidResponse("status \(response.statusCode)") }
        // From here on the 200 may already be billed: any validation failure pauses briefly
        // (`recordInvalidAudio`) so a non-audio 200 isn't paid for again on every break.
        guard let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(), type.hasPrefix("audio/") else {
            backoff?.recordInvalidAudio()
            throw VoiceRenderError.invalidResponse("content type")
        }
        guard !data.isEmpty, data.count <= configuration.maxResponseBytes else {
            backoff?.recordInvalidAudio()
            throw VoiceRenderError.invalidResponse("size")
        }
        guard let header = response.value(forHTTPHeaderField: "X-Audio-Duration"), let seconds = Double(header),
              seconds.isFinite, seconds > 0, seconds <= 600 else {
            backoff?.recordInvalidAudio()
            throw VoiceRenderError.invalidResponse("duration")
        }
        backoff?.recordSuccess()
        let billed = response.value(forHTTPHeaderField: "X-Billed-Characters").flatMap(Int.init) ?? text.count
        return VoiceArtifact(data: data, durationSeconds: seconds, billableUnits: billed,
                             provider: configuration.upstream.rawValue, cacheKey: nil)
    }

    /// Maps a non-200 proxy answer to the backoff (#233 §4.4 rev 2). See `PaidVoiceBackoff` for the policy.
    static func record(status: Int, body: Data, retryAfter: String?, in backoff: PaidVoiceBackoff) {
        let reason = PaidVoiceBackoff.ProxyErrorReason.parse(body)
        switch status {
        case 401: backoff.recordUnauthorized()
        case 403 where reason == .noEntitlement: backoff.recordNoEntitlement()
        case 403 where reason == .installLimit: backoff.recordInstallLimit()
        // Do not retry that request; the next cue may use the paid route again.
        case 400 where reason == .badRequest, 413: break
        case 429: backoff.recordRateLimited(retryAfter: retryAfter, reason: reason)
        // 503, and every other 5xx is "treat as 503 unknown" (Retry-After, else exponential).
        case 500...599: backoff.recordServiceUnavailable(retryAfter: retryAfter, reason: reason)
        // 400 `mixed_auth`, 405, and any other 4xx (missing or unknown reason): a client bug.
        case 400...499: backoff.recordClientError()
        default: break
        }
    }
}
