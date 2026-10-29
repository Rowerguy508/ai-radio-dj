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
}
