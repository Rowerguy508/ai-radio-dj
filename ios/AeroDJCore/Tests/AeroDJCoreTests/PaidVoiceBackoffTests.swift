import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

private struct LocalVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data([1, 2, 3]), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private struct ScriptedResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var error: URLError? = nil
    static let ok = ScriptedResponse(status: 200, headers: ["Content-Type": "audio/wav", "X-Audio-Duration": "3.0"])
}

/// Returns the next scripted response; the last one repeats. Counts every request.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ScriptedResponse]
    private(set) var calls = 0
    init(_ script: [ScriptedResponse]) { self.script = script }
    var callCount: Int { lock.withLock { calls } }
    func set(_ next: [ScriptedResponse]) { lock.withLock { script = next } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response: ScriptedResponse = lock.withLock {
            calls += 1
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        if let error = response.error { throw error }
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil,
                                              headerFields: response.headers)!)
    }
}

private final class MemoryBackoffStore: PaidVoiceBackoffStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PaidVoiceBackoff.State?
    private(set) var saves = 0
    func load() -> PaidVoiceBackoff.State? { lock.withLock { state } }
    func save(_ state: PaidVoiceBackoff.State) { lock.withLock { self.state = state; saves += 1 } }
    var saveCount: Int { lock.withLock { saves } }
}

final class PaidVoiceBackoffTests: XCTestCase {
    private let sawyer = "8dEUmyPMdDdK91vboYih"
    private let creds = PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!,
                                                token: "owner-test-token")
    /// 2027-01-15 08:00:00 UTC: 16 h before the next UTC midnight.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func renderer(_ transport: ScriptedTransport, _ backoff: PaidVoiceBackoff?) -> VoiceRenderer {
        let device = [VoiceRoute(providerID: "device", provider: LocalVoice(), voice: VoiceProfile(id: "host", name: "Host"))]
        let c = PremiumVoiceRoutes.compose(onDevice: device, paidProvidersEnabled: true, selectedVoiceID: sawyer,
                                           credentials: creds, transport: transport, backoff: backoff)
        XCTAssertEqual(c.routes.count, 2)
        return VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
    }

    /// A distinct line each time, so the audio cache never answers for the proxy.
    private func render(_ r: VoiceRenderer, _ n: Int) async -> String? {
        let cue = NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: "That was Song \(n).",
                               estimatedSeconds: 2, maxSeconds: 12, sourceItemID: nil, source: nil, provenance: nil)
        guard case .success(let clip) = await r.render(cue, userID: "u", stationID: "s", attribution: .presenter) else {
            return nil
        }
        return clip.audio.providerID
    }

    // MARK: 429

    func test429WithRetryAfterSecondsSuspendsThenResumesAfterExpiry() async {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        let transport = ScriptedTransport([ScriptedResponse(status: 429, headers: ["Retry-After": "120"]), .ok])
        let r = renderer(transport, backoff)

        let first = await render(r, 1)
        XCTAssertEqual(first, "device", "429 falls back to the on-device voice")
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(backoff.suspendedUntil(), t0.addingTimeInterval(120))
        XCTAssertEqual(backoff.snapshot.reason, .rateLimited)

        clock.advance(119)
        let suspended = await render(r, 2)
        XCTAssertEqual(suspended, "device")
        XCTAssertEqual(transport.callCount, 1, "no proxy call while suspended")

        clock.advance(1)
        XCTAssertNil(backoff.suspendedUntil())
        let resumed = await render(r, 3)
        XCTAssertEqual(resumed, "elevenlabs")
        XCTAssertEqual(transport.callCount, 2)
        XCTAssertEqual(backoff.snapshot, PaidVoiceBackoff.State(), "a 200 clears the state")
    }

    func test429WithRetryAfterHTTPDate() {
        let wait = PaidVoiceBackoff.rateLimitWait(retryAfter: "Fri, 15 Jan 2027 08:10:00 GMT", now: t0)
        XCTAssertEqual(wait, 600, accuracy: 0.001)
    }

    func test429WithoutHeaderWaitsUntilNextUTCMidnight() async {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        let transport = ScriptedTransport([ScriptedResponse(status: 429)])
        let r = renderer(transport, backoff)
        _ = await render(r, 1)
        let midnight = Date(timeIntervalSince1970: 1_800_057_600)  // 2027-01-16 00:00 UTC
        XCTAssertEqual(backoff.suspendedUntil(), midnight)

        clock.advance(16 * 3600 - 1)
        _ = await render(r, 2)
        XCTAssertEqual(transport.callCount, 1)
        clock.advance(1)
        XCTAssertNil(backoff.suspendedUntil())
    }

    func testRateLimitWaitIsClampedAndUnparseableMeansMidnight() {
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: "5", now: t0), 60)
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: "0", now: t0), 60)
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: "999999", now: t0), 86_400)
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: "Thu, 14 Jan 2027 08:00:00 GMT", now: t0), 60,
                       "a date in the past still waits the minimum")
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: "soon", now: t0), 16 * 3600)
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: nil, now: t0), 16 * 3600)
        // One second before UTC midnight: the 60 s floor applies.
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: nil, now: Date(timeIntervalSince1970: 1_800_057_599)), 60)
    }

    // MARK: Zero proxy calls while suspended

    func testSuspendedPathMakesZeroProxyCallsAndReadsNoToken() async throws {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        backoff.recordRateLimited(retryAfter: "3600")
        let transport = ScriptedTransport([.ok])
        let r = renderer(transport, backoff)
        for n in 1...5 {
            let provider = await render(r, n)
            XCTAssertEqual(provider, "device")
        }
        XCTAssertEqual(transport.callCount, 0)

        final class TokenReads: @unchecked Sendable { var count = 0 }
        let reads = TokenReads()
        let config = try ProxyVoiceProvider.Configuration(endpoint: creds.endpoint, allowedHosts: ["aerodj-tts.vercel.app"],
                                                          upstream: .elevenlabs, sessionToken: { reads.count += 1; return "t" })
        let provider = ProxyVoiceProvider(configuration: config, transport: transport, backoff: backoff)
        do {
            _ = try await provider.synthesize("Hi", voice: VoiceProfile(id: sawyer, name: "S"),
                                              context: RequestContext(stationID: "s", isReusableGeneric: false))
            XCTFail("suspended provider must throw")
        } catch {
            XCTAssertEqual(error as? VoiceRenderError, .suspended)
        }
        XCTAssertEqual(reads.count, 0)
        XCTAssertEqual(transport.callCount, 0)
    }

    // MARK: Persistence

    func testSuspensionPersistsAcrossReinit() {
        let clock = TestClock(t0)
        let store = MemoryBackoffStore()
        PaidVoiceBackoff(store: store, now: { clock.now }).recordRateLimited(retryAfter: "600")
        let relaunched = PaidVoiceBackoff(store: store, now: { clock.now })
        XCTAssertEqual(relaunched.suspendedUntil(), t0.addingTimeInterval(600))
        clock.advance(600)
        XCTAssertNil(PaidVoiceBackoff(store: store, now: { clock.now }).suspendedUntil())
    }

    func testUserDefaultsStoreRoundTrips() {
        let name = "PaidVoiceBackoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = TestClock(t0)
        let store = UserDefaultsPaidVoiceBackoffStore(defaults: defaults)
        XCTAssertNil(store.load())
        PaidVoiceBackoff(store: store, now: { clock.now }).recordServerFailure()
        let relaunched = PaidVoiceBackoff(store: UserDefaultsPaidVoiceBackoffStore(defaults: defaults), now: { clock.now })
        XCTAssertEqual(relaunched.snapshot, PaidVoiceBackoff.State(suspendedUntil: t0.addingTimeInterval(30),
                                                                     reason: .serverError, consecutiveFailures: 1))
    }

    // MARK: 5xx

    func test5xxBackoffDoublesAndResetsOnSuccess() async {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        let transport = ScriptedTransport([ScriptedResponse(status: 503)])
        let r = renderer(transport, backoff)

        var expected: [TimeInterval] = []
        var waits: [TimeInterval] = []
        for n in 1...7 {
            let provider = await render(r, n)
            XCTAssertEqual(provider, "device")
            let until = try? XCTUnwrap(backoff.suspendedUntil())
            let wait = until.map { $0.timeIntervalSince(clock.now) } ?? -1
            waits.append(wait)
            expected.append(min(30 * pow(2, Double(n - 1)), 900))
            // Still suspended one second before expiry: no call.
            clock.advance(wait - 1)
            _ = await render(r, 100 + n)
            XCTAssertEqual(transport.callCount, n)
            clock.advance(1)
        }
        XCTAssertEqual(waits, expected)
        XCTAssertEqual(expected.last, 900, "capped at 15 min")

        transport.set([.ok])
        let ok = await render(r, 50)
        XCTAssertEqual(ok, "elevenlabs")
        XCTAssertEqual(backoff.snapshot.consecutiveFailures, 0)
        transport.set([ScriptedResponse(status: 500)])
        _ = await render(r, 51)
        XCTAssertEqual(backoff.suspendedUntil(), clock.now.addingTimeInterval(30), "reset to the 30 s base")
    }

    func testTransportErrorBacksOffButCancellationDoesNot() async {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        let transport = ScriptedTransport([ScriptedResponse(status: 0, error: URLError(.notConnectedToInternet))])
        _ = await render(renderer(transport, backoff), 1)
        XCTAssertEqual(backoff.snapshot.consecutiveFailures, 1)
        XCTAssertEqual(backoff.suspendedUntil(), t0.addingTimeInterval(30))

        let other = PaidVoiceBackoff(now: { clock.now })
        let cancelled = ScriptedTransport([ScriptedResponse(status: 0, error: URLError(.cancelled))])
        let r = renderer(cancelled, other)
        let cue = NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: "That was Song 2.",
                               estimatedSeconds: 2, maxSeconds: 12, sourceItemID: nil, source: nil, provenance: nil)
        let task = Task { _ = await r.render(cue, userID: "u", stationID: "s", attribution: .presenter) }
        task.cancel()
        await task.value
        XCTAssertEqual(other.snapshot, PaidVoiceBackoff.State(), "caller cancellation is not a proxy failure")
    }

    func testServerFailureNeverShortensA429Suspension() {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        backoff.recordRateLimited(retryAfter: nil)
        backoff.recordServerFailure()
        XCTAssertEqual(backoff.suspendedUntil(), Date(timeIntervalSince1970: 1_800_057_600))
        XCTAssertEqual(backoff.snapshot.reason, .rateLimited)
    }

    // MARK: No behavior change without a 429

    func test200DoesNotSuspendAndWritesNothing() async {
        let clock = TestClock(t0)
        let store = MemoryBackoffStore()
        let backoff = PaidVoiceBackoff(store: store, now: { clock.now })
        let transport = ScriptedTransport([.ok])
        let r = renderer(transport, backoff)
        for n in 1...3 {
            let provider = await render(r, n)
            XCTAssertEqual(provider, "elevenlabs")
        }
        XCTAssertEqual(transport.callCount, 3)
        XCTAssertNil(backoff.suspendedUntil())
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(backoff.statusLine(), "Premium backoff: none")
    }

    func testNoBackoffKeepsCallingAfter429() async {
        let transport = ScriptedTransport([ScriptedResponse(status: 429, headers: ["Retry-After": "120"])])
        let r = renderer(transport, nil)
        for n in 1...3 { _ = await render(r, n) }
        XCTAssertEqual(transport.callCount, 3, "without a backoff the provider behaves exactly as before")
    }

    func testOther4xxDoesNotSuspend() async {
        let backoff = PaidVoiceBackoff(now: { [t0] in t0 })
        let transport = ScriptedTransport([ScriptedResponse(status: 401)])
        _ = await render(renderer(transport, backoff), 1)
        XCTAssertNil(backoff.suspendedUntil())
    }

    func testStatusLineShowsReasonAndResumeTimeOnly() {
        let backoff = PaidVoiceBackoff(now: { [t0] in t0 })
        backoff.recordRateLimited(retryAfter: "120")
        XCTAssertEqual(backoff.statusLine(), "Premium backoff: rateLimited until 2027-01-15T08:02:00Z")
    }
}
