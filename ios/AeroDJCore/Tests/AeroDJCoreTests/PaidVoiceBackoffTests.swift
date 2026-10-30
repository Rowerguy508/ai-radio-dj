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
    var body: Data = Data([9, 9])
    /// A proxy error body (`{ error, requestId, reason }`, #233 §4.4).
    static func proxyError(_ status: Int, reason: String, retryAfter: String? = nil) -> ScriptedResponse {
        var headers = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        let json = #"{"error":"Too many requests","requestId":"r1","reason":"\#(reason)"}"#
        return ScriptedResponse(status: status, headers: headers, body: Data(json.utf8))
    }
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
        return (response.body, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil,
                                              headerFields: response.headers)!)
    }
}

/// Suspends in `send` until the calling task is cancelled, then throws like URLSession does.
/// Lets a test cancel deterministically while the request is in flight.
private final class HangingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var cancelled = false
    var callCount: Int { lock.withLock { calls } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { calls += 1 }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if cancelled { return true }
                    waiter = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Never>? = lock.withLock {
                cancelled = true
                defer { waiter = nil }
                return waiter
            }
            c?.resume()
        }
        throw URLError(.cancelled)
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
        let hanging = HangingTransport()
        let device = [VoiceRoute(providerID: "device", provider: LocalVoice(), voice: VoiceProfile(id: "host", name: "Host"))]
        let c = PremiumVoiceRoutes.compose(onDevice: device, paidProvidersEnabled: true, selectedVoiceID: sawyer,
                                           credentials: creds, transport: hanging, backoff: other)
        guard let proxy = c.routes.first(where: { $0.providerID != "device" }) else { return XCTFail("no proxy route") }
        // Drive the provider directly: the renderer returns on cancellation without waiting for the
        // provider's catch block, so awaiting it could assert before the backoff is (wrongly) touched.
        let task = Task {
            try await proxy.provider.synthesize("That was Song 2.", voice: proxy.voice,
                                                context: RequestContext(stationID: "s", isReusableGeneric: false))
        }
        // Cancel only once the request is in flight, so the cancellation guard is always exercised.
        while hanging.callCount == 0 { await Task.yield() }
        task.cancel()
        _ = await task.result  // the provider's catch block has run by now
        XCTAssertEqual(hanging.callCount, 1)
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
        let transport = ScriptedTransport([ScriptedResponse(status: 403)])
        _ = await render(renderer(transport, backoff), 1)
        XCTAssertNil(backoff.suspendedUntil())
    }

    func testStatusLineShowsReasonAndResumeTimeOnly() {
        let backoff = PaidVoiceBackoff(now: { [t0] in t0 })
        backoff.recordRateLimited(retryAfter: "120")
        XCTAssertEqual(backoff.statusLine(), "Premium backoff: rateLimited until 2027-01-15T08:02:00Z")
    }

    // MARK: #233 §4.4 contract

    func testReasonParsingIsAllowlistedAndBounded() {
        typealias R = PaidVoiceBackoff.ProxyErrorReason
        XCTAssertEqual(R.parse(Data(#"{"reason":"install_daily"}"#.utf8)), .installDaily)
        XCTAssertEqual(R.parse(Data(#"{"reason":"global_daily"}"#.utf8)), .globalDaily)
        XCTAssertEqual(R.parse(Data(#"{"reason":"rate"}"#.utf8)), .rate)
        XCTAssertEqual(R.parse(Data(#"{"reason":"disabled"}"#.utf8)), .disabled)
        XCTAssertNil(R.parse(Data(#"{"reason":"something_new"}"#.utf8)))
        XCTAssertNil(R.parse(Data(#"{"reason":3}"#.utf8)))
        XCTAssertNil(R.parse(Data("not json".utf8)))
        XCTAssertNil(R.parse(Data()))
        let padded = #"{"reason":"rate","pad":""# + String(repeating: "x", count: 5000) + #""}"#
        XCTAssertNil(R.parse(Data(padded.utf8)), "bodies over 4 KB are not parsed")
    }

    func test429InstallDailyWithoutHeaderWaitsUntilUTCMidnightAndPersists() async {
        let clock = TestClock(t0)
        let store = MemoryBackoffStore()
        let backoff = PaidVoiceBackoff(store: store, now: { clock.now })
        let transport = ScriptedTransport([.proxyError(429, reason: "install_daily")])
        let r = renderer(transport, backoff)
        let provider = await render(r, 1)
        XCTAssertEqual(provider, "device")
        XCTAssertEqual(backoff.suspendedUntil(), Date(timeIntervalSince1970: 1_800_057_600))
        XCTAssertEqual(backoff.snapshot.reason, .dailyCap)
        let relaunched = PaidVoiceBackoff(store: store, now: { clock.now })
        XCTAssertEqual(relaunched.suspendedUntil(), Date(timeIntervalSince1970: 1_800_057_600), "persisted across launches")
    }

    func test429GlobalDailyHonorsRetryAfterOverLocalMidnight() async {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        let transport = ScriptedTransport([.proxyError(429, reason: "global_daily", retryAfter: "7200")])
        _ = await render(renderer(transport, backoff), 1)
        XCTAssertEqual(backoff.suspendedUntil(), t0.addingTimeInterval(7200), "the server's Retry-After wins")
        XCTAssertEqual(backoff.snapshot.reason, .dailyCap)
    }

    func test429RateUsesRetryAfterAndNotMidnight() async {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        let transport = ScriptedTransport([.proxyError(429, reason: "rate", retryAfter: "90"), .ok])
        let r = renderer(transport, backoff)
        _ = await render(r, 1)
        XCTAssertEqual(backoff.suspendedUntil(), t0.addingTimeInterval(90))
        XCTAssertEqual(backoff.snapshot.reason, .rateLimited)
        clock.advance(90)
        let resumed = await render(r, 2)
        XCTAssertEqual(resumed, "elevenlabs")
        XCTAssertEqual(transport.callCount, 2)
    }

    func test429RateWithoutHeaderWaitsTheShortFloorNotMidnight() {
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: nil, reason: .rate, now: t0), 60)
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: "5", reason: .rate, now: t0), 60, "never sooner than 60 s")
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: nil, reason: .installDaily, now: t0), 16 * 3600)
        XCTAssertEqual(PaidVoiceBackoff.rateLimitWait(retryAfter: nil, reason: nil, now: t0), 16 * 3600,
                       "an unknown or missing reason is treated as the daily cap")
    }

    func test503DisabledHonorsRetryAfterAndPersists() async {
        let clock = TestClock(t0)
        let store = MemoryBackoffStore()
        let backoff = PaidVoiceBackoff(store: store, now: { clock.now })
        let transport = ScriptedTransport([.proxyError(503, reason: "disabled", retryAfter: "3600")])
        let r = renderer(transport, backoff)
        _ = await render(r, 1)
        XCTAssertEqual(backoff.suspendedUntil(), t0.addingTimeInterval(3600))
        XCTAssertEqual(backoff.snapshot.reason, .disabled)
        clock.advance(3599)
        _ = await render(r, 2)
        XCTAssertEqual(transport.callCount, 1, "kill switch: no proxy call while suspended")
        XCTAssertEqual(PaidVoiceBackoff(store: store, now: { clock.now }).snapshot.reason, .disabled)
    }

    func test503DisabledWithoutHeaderWaitsOneHour() async {
        let backoff = PaidVoiceBackoff(now: { [t0] in t0 })
        let transport = ScriptedTransport([.proxyError(503, reason: "disabled")])
        _ = await render(renderer(transport, backoff), 1)
        XCTAssertEqual(backoff.suspendedUntil(), t0.addingTimeInterval(3600))
    }

    func test503StoreHonorsRetryAfterElseExponential() async {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        let transport = ScriptedTransport([.proxyError(503, reason: "store", retryAfter: "60")])
        _ = await render(renderer(transport, backoff), 1)
        XCTAssertEqual(backoff.suspendedUntil(), t0.addingTimeInterval(60))
        XCTAssertEqual(backoff.snapshot.reason, .serverError)
        XCTAssertEqual(PaidVoiceBackoff.serviceUnavailableWait(retryAfter: nil, reason: .store, consecutiveFailures: 3, now: t0), 120)
        XCTAssertEqual(PaidVoiceBackoff.serviceUnavailableWait(retryAfter: "1", reason: .store, consecutiveFailures: 1, now: t0), 30,
                       "a Retry-After is floored at 30 s")
        XCTAssertEqual(PaidVoiceBackoff.serviceUnavailableWait(retryAfter: "999999", reason: .disabled, consecutiveFailures: 1, now: t0),
                       86_400, "and capped at 24 h")
    }

    func test503NeverShortensADailyCapSuspension() {
        let backoff = PaidVoiceBackoff(now: { [t0] in t0 })
        backoff.recordRateLimited(retryAfter: nil, reason: .installDaily)
        backoff.recordServiceUnavailable(retryAfter: "60", reason: .store)
        XCTAssertEqual(backoff.suspendedUntil(), Date(timeIntervalSince1970: 1_800_057_600))
        XCTAssertEqual(backoff.snapshot.reason, .dailyCap)
    }

    func test401StopsPaidCallsForThisLaunchWithoutLoopingOrPersisting() async {
        let clock = TestClock(t0)
        let store = MemoryBackoffStore()
        let backoff = PaidVoiceBackoff(store: store, now: { clock.now })
        let transport = ScriptedTransport([.proxyError(401, reason: "reattest"), .ok])
        let r = renderer(transport, backoff)
        for n in 1...5 {
            let provider = await render(r, n)
            XCTAssertEqual(provider, "device")
            clock.advance(48 * 3600)
        }
        XCTAssertEqual(transport.callCount, 1, "one 401, then no proxy call on any later break")
        XCTAssertTrue(backoff.isStoppedForThisLaunch)
        XCTAssertEqual(backoff.statusLine(), "Premium backoff: unauthorized until next launch")
        XCTAssertEqual(store.saveCount, 0, "a 401 is not persisted")
        let nextLaunch = PaidVoiceBackoff(store: store, now: { clock.now })
        XCTAssertNil(nextLaunch.suspendedUntil(), "the next launch tries again")
    }

    func test401WithoutReasonAlsoStops() async {
        let backoff = PaidVoiceBackoff(now: { [t0] in t0 })
        let transport = ScriptedTransport([ScriptedResponse(status: 401)])
        let r = renderer(transport, backoff)
        _ = await render(r, 1)
        _ = await render(r, 2)
        XCTAssertEqual(transport.callCount, 1)
    }

    func testAttestFailureStopsForThisLaunchWithoutAnyCall() async {
        let backoff = PaidVoiceBackoff(now: { [t0] in t0 })
        backoff.recordAttestFailure()
        let transport = ScriptedTransport([.ok])
        let provider = await render(renderer(transport, backoff), 1)
        XCTAssertEqual(provider, "device")
        XCTAssertEqual(transport.callCount, 0)
    }

    // MARK: recordSuccess only after the audio is validated (Echo, 2508ef3)

    func test200ThatIsNotAudioDoesNotClearASuspensionState() async {
        let clock = TestClock(t0)
        let backoff = PaidVoiceBackoff(now: { clock.now })
        let transport = ScriptedTransport([ScriptedResponse(status: 500)])
        let r = renderer(transport, backoff)
        _ = await render(r, 1)
        XCTAssertEqual(backoff.snapshot.consecutiveFailures, 1)
        clock.advance(30)
        transport.set([ScriptedResponse(status: 200, headers: ["Content-Type": "text/html", "X-Audio-Duration": "3.0"])])
        let html = await render(r, 2)
        XCTAssertEqual(html, "device")
        XCTAssertEqual(backoff.snapshot.consecutiveFailures, 1, "a 200 that isn't audio is not a success")
        transport.set([ScriptedResponse(status: 200, headers: ["Content-Type": "audio/wav"])])
        _ = await render(r, 3)
        XCTAssertEqual(backoff.snapshot.consecutiveFailures, 1, "a 200 without a duration is not a success")
        transport.set([.ok])
        let ok = await render(r, 4)
        XCTAssertEqual(ok, "elevenlabs")
        XCTAssertEqual(backoff.snapshot, PaidVoiceBackoff.State(), "valid audio clears it")
    }

    func testPersistedStateFromTheFirstVersionStillDecodes() throws {
        let old = #"{"suspendedUntil":1800000000,"reason":"rateLimited","consecutiveFailures":0}"#
        let state = try JSONDecoder().decode(PaidVoiceBackoff.State.self, from: Data(old.utf8))
        XCTAssertEqual(state.reason, .rateLimited)
    }
}
