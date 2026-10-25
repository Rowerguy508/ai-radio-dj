import XCTest
@testable import AeroDJCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor CallLog {
    var texts: [String] = []
    func add(_ t: String) { texts.append(t) }
}

/// Deterministic fake voice: duration = words * secondsPerWord.
private struct FakeVoice: VoiceProvider {
    var id = "fake"
    var secondsPerWord = 0.4
    var delay: Duration = .zero
    var ignoresCancellation = false
    var error: Error?
    var emptyAudio = false
    let log = CallLog()

    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        await log.add(text)
        if delay > .zero {
            if ignoresCancellation {
                let deadline = ContinuousClock.now + delay
                while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            } else {
                try await Task.sleep(for: delay)
            }
        }
        if let error { throw error }
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: emptyAudio ? Data() : Data("\(id):\(text)".utf8), durationSeconds: Double(words) * secondsPerWord,
                             billableUnits: text.count, provider: id, cacheKey: nil)
    }
}

private final class MutableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private let voice = VoiceProfile(id: "host", name: "Host")
private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

private func cue(_ text: String, max: Int = 30, order: Int = 1, kind: BriefingScriptSegment.Kind = .followUp) -> NarrationCue {
    NarrationCue(id: UUID(), order: order, group: order, kind: kind, text: text, estimatedSeconds: 4, maxSeconds: max,
                 sourceItemID: kind == .followUp ? UUID() : nil, source: kind == .followUp ? .calendar : nil,
                 provenance: kind == .followUp ? "test" : nil)
}

private func paid(_ v: FakeVoice, perK: Int = 30_000, timeout: Duration = .seconds(2)) -> VoiceRoute {
    VoiceRoute(providerID: "paid", provider: v, voice: voice, microdollarsPerThousandCharacters: perK, timeout: timeout, acceptsSSML: true)
}

private func free(_ v: FakeVoice) -> VoiceRoute {
    VoiceRoute(providerID: "avspeech", provider: v, voice: voice)
}

final class SpeechDeliveryTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Digest.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(String(repeating: "a", count: 1000)).count, 64)
    }

    func testTimesAreSpokenTheRadioWay() {
        XCTAssertEqual(SpeechDelivery.speakable("Coming up at 9:30 AM: Design review. 9:30 AM to 10:30 AM. From your calendar."),
                       "Coming up at 9:30 a.m.: Design review. 9:30 a.m. to 10:30 a.m. From your calendar.")
        XCTAssertEqual(SpeechDelivery.speakable("Coming up at 12 PM: Lunch. 12 PM to 1:00 PM."), "Coming up at noon: Lunch. noon to 1 p.m.")
        XCTAssertEqual(SpeechDelivery.speakable("Starts 12:00 AM, ends 9:00 AM"), "Starts midnight, ends 9 a.m.")
        XCTAssertEqual(SpeechDelivery.speakable("Flight IB 3166 boards at gate 12"), "Flight IB 3166 boards at gate 12")
    }

    func testSSMLAddsPausesEscapesAndRoundTrips() {
        let text = "Coming up at 9 AM: Q&A with Dr. Lee. 9 AM to 10 AM. From your calendar."
        let ssml = SpeechDelivery.ssml(text)
        XCTAssertTrue(ssml.hasPrefix("<speak>") && ssml.hasSuffix("</speak>"))
        XCTAssertTrue(ssml.contains("a.m.:<break time=\"150ms\"/>"))
        XCTAssertTrue(ssml.contains("Q&amp;A"))
        XCTAssertFalse(ssml.contains("Dr.<break"), "no pause after an abbreviation")
        XCTAssertEqual(ssml.components(separatedBy: "300ms").count - 1, 2)
        XCTAssertEqual(SpeechDelivery.plainText(fromSSML: ssml), SpeechDelivery.speakable(text))
    }
}

final class VoiceRenderingTests: XCTestCase {
    func testCostCapIsPerUserPerDayAndFallsBackToOnDevice() async {
        let clock = MutableClock(t0)
        let budget = VoiceBudget(dailyCapMicrodollars: 2_000, calendar: utc, now: { clock.now })
        let cloud = FakeVoice(id: "cloud"), device = FakeVoice(id: "device")
        let renderer = VoiceRenderer(routes: [paid(cloud), free(device)], budget: budget, cache: InMemoryAudioCache())
        // ~45 chars of SSML+text at 30,000 µ$/1k chars ≈ 1,500-2,000 µ$: one paid call fits the cap.
        let first = await renderer.render(cue("Coming up at 9 AM: Standup."), userID: "ana", stationID: "s1")
        XCTAssertEqual(try first.get().audio.providerID, "paid")
        let second = await renderer.render(cue("Coming up at 10 AM: Review."), userID: "ana", stationID: "s2")
        XCTAssertEqual(try second.get().audio.providerID, "avspeech", "hard stop -> on-device, across stations")
        XCTAssertEqual(try second.get().attempts.first?.result, .overCostCap)
        let other = await renderer.render(cue("Coming up at 10 AM: Review."), userID: "ben", stationID: "s1")
        XCTAssertEqual(try other.get().audio.providerID, "paid", "caps are per user")
        clock.now = t0.addingTimeInterval(16 * 3600)       // next UTC day
        let tomorrow = await renderer.render(cue("Coming up at 11 AM: Sync."), userID: "ana", stationID: "s1")
        XCTAssertEqual(try tomorrow.get().audio.providerID, "paid", "cap resets at midnight")
        let spent = await budget.committed(userID: "ana")
        XCTAssertLessThanOrEqual(spent, 2_000)
    }

    func testConcurrentReservationsNeverExceedCapAndSpendPersists() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("budget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000, calendar: utc, file: file, now: { t0 })
        let granted = await withTaskGroup(of: VoiceBudget.Reservation?.self) { group in
            for _ in 0..<20 { group.addTask { await budget.reserve(userID: "ana", microdollars: 300) } }
            var out: [VoiceBudget.Reservation] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        XCTAssertEqual(granted.count, 3)
        for r in granted { await budget.commit(r, microdollars: 300) }
        let relaunched = VoiceBudget(dailyCapMicrodollars: 1_000, calendar: utc, file: file, now: { t0 })
        let spent = await relaunched.committed(userID: "ana")
        XCTAssertEqual(spent, 900)
        let overSize = await relaunched.reserve(userID: "ana", microdollars: 101)
        XCTAssertNil(overSize, "a single oversize call is refused up front")
    }

    func testTimeoutFallsBackEvenIfProviderIgnoresCancellationAndChargesReservation() async throws {
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000, calendar: utc, now: { t0 })
        let slow = FakeVoice(id: "slow", delay: .seconds(3), ignoresCancellation: true)
        let renderer = VoiceRenderer(routes: [paid(slow, timeout: .milliseconds(100)), free(FakeVoice(id: "device"))],
                                     budget: budget, cache: InMemoryAudioCache())
        let started = ContinuousClock.now
        let clip = try await renderer.render(cue("Coming up at 9 AM: Standup."), userID: "ana", stationID: "s").get()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(clip.attempts.map(\.result), [.timedOut, .rendered])
        let spent = await budget.committed(userID: "ana")
        XCTAssertGreaterThan(spent, 0, "a timed-out paid call may still bill; it counts against the cap")
    }

    func testFailureChainIncludingUnimplementedDessa() async throws {
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000, calendar: utc, now: { t0 })
        let dessa = VoiceRoute(providerID: DessaVoiceProvider.providerID, provider: DessaVoiceProvider(), voice: voice,
                               microdollarsPerThousandCharacters: 10_000)
        let broken = FakeVoice(id: "broken", error: URLError(.notConnectedToInternet))
        let empty = FakeVoice(id: "empty", emptyAudio: true)
        let renderer = VoiceRenderer(routes: [dessa, paid(broken), free(empty), free(FakeVoice(id: "device"))],
                                     budget: budget, cache: InMemoryAudioCache())
        let clip = try await renderer.render(cue("Due today: Pay rent."), userID: "ana", stationID: "s").get()
        XCTAssertEqual(clip.attempts.count, 4)
        XCTAssertEqual(clip.attempts[0].result, .failed(String(describing: VoiceRenderError.notImplemented("Dessa adapter is not implemented yet"))))
        XCTAssertEqual(clip.attempts[2].result, .invalidAudio)
        XCTAssertEqual(clip.attempts[3].result, .rendered)
        let spent = await budget.committed(userID: "ana")
        XCTAssertEqual(spent, 0, "failed calls release their reservation")
    }

    func testCacheKeyedByTextVoiceAndProvider() async throws {
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000, calendar: utc, now: { t0 })
        let cloud = FakeVoice(id: "cloud")
        let cache = InMemoryAudioCache()
        let renderer = VoiceRenderer(routes: [paid(cloud)], budget: budget, cache: cache)
        let a = try await renderer.render(cue("Due today: Pay rent."), userID: "ana", stationID: "s").get()
        let b = try await renderer.render(cue("Due today: Pay rent."), userID: "ana", stationID: "s").get()
        XCTAssertEqual(b.attempts.map(\.result), [.cacheHit])
        XCTAssertEqual(a.cacheKey, b.cacheKey)
        let calls = await cloud.log.texts.count
        XCTAssertEqual(calls, 1)
        let spentOnce = await budget.committed(userID: "ana")
        let otherVoice = VoiceRoute(providerID: "paid", provider: cloud, voice: VoiceProfile(id: "other", name: "O"),
                                    microdollarsPerThousandCharacters: 30_000, acceptsSSML: true)
        let c = try await VoiceRenderer(routes: [otherVoice], budget: budget, cache: cache)
            .render(cue("Due today: Pay rent."), userID: "ana", stationID: "s").get()
        XCTAssertNotEqual(c.cacheKey, a.cacheKey)
        XCTAssertNotEqual(VoiceRenderer.cacheKey(text: "x", route: paid(cloud)), VoiceRenderer.cacheKey(text: "y", route: paid(cloud)))
        let spentTwice = await budget.committed(userID: "ana")
        XCTAssertEqual(spentTwice, spentOnce * 2, "cache hits cost nothing")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileCache = FileAudioCache(directory: dir)
        await fileCache.store(a.audio, for: a.cacheKey)
        let reloaded = await FileAudioCache(directory: dir).audio(for: a.cacheKey)
        XCTAssertEqual(reloaded, a.audio)
    }

    func testRenderedDurationFeedsSchedulerAndOverlongClipsAreExplicit() async throws {
        let budget = VoiceBudget(dailyCapMicrodollars: 1_000_000, calendar: utc, now: { t0 })
        let slowTalker = FakeVoice(id: "cloud", secondsPerWord: 3)      // too long for every cue's bound
        let device = FakeVoice(id: "device", secondsPerWord: 0.5)
        let renderer = VoiceRenderer(routes: [paid(slowTalker), free(device)], budget: budget, cache: InMemoryAudioCache())
        let opener = cue("Good morning.", max: 6, order: 0, kind: .opener)
        let item = cue("Coming up at 9:30 AM: Design review. 9:30 AM to 10:30 AM. From your calendar.", max: 12)
        let tooLong = cue(String(repeating: "word ", count: 40) + "end.", max: 10, order: 2)
        let closer = cue("That's your briefing.", max: 6, order: 3, kind: .closer)
        let handoff = NarrationHandoff(cues: [opener, item, tooLong, closer], maxSpokenSeconds: 150, experienceSeconds: 300)

        let rendered = await renderer.render(handoff, userID: "ana", stationID: "s")
        XCTAssertEqual(rendered.handoff.cues.map(\.id), [opener.id, item.id, closer.id])
        let r = try XCTUnwrap(rendered.handoff.cues.first { $0.id == item.id })
        XCTAssertEqual(r.renderedSeconds, 7.5, "measured (15 spoken words x 0.5 s) replaces the 4 s estimate")
        XCTAssertEqual(r.plannedSeconds, 7.5)
        XCTAssertEqual(r.providerID, "avspeech")
        XCTAssertEqual(r.voiceID, "host")
        XCTAssertNotNil(r.audioCacheKey)
        XCTAssertEqual(rendered.failures[tooLong.id]?.reason, .overDuration)

        let scheduled = await ReferenceGroupedScheduler().schedule(rendered.handoff, trackCount: 2)
        let report = rendered.report(merging: scheduled)
        XCTAssertEqual(report.entries.map(\.cue.id), handoff.cues.map(\.id), "every original cue keeps one outcome")
        XCTAssertEqual(report.outcome(for: tooLong.id), .dropped(.overDuration))
        XCTAssertEqual(NarrationContract.violations(of: scheduled, for: rendered.handoff, trackCount: 2), [])
    }
}

private struct FakeTransport: HTTPTransport {
    let status: Int
    let headers: [String: String]
    let body: Data
    let seen = RequestLog()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await seen.add(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private actor RequestLog {
    var requests: [URLRequest] = []
    func add(_ r: URLRequest) { requests.append(r) }
}

final class ProxyVoiceProviderTests: XCTestCase {
    private func config(_ url: String) throws -> ProxyVoiceProvider.Configuration {
        try .init(endpoint: URL(string: url)!, allowedHosts: ["voice.aerodj.example"], upstream: .cartesia,
                  sessionToken: { "user-session-123" })
    }

    func testRejectsInsecureOrUnknownEndpoints() {
        for url in ["http://voice.aerodj.example/tts", "https://evil.example/tts", "https://u:p@voice.aerodj.example/tts"] {
            XCTAssertThrowsError(try config(url), url) { XCTAssertEqual($0 as? VoiceRenderError, .insecureEndpoint) }
        }
        XCTAssertNoThrow(try config("https://voice.aerodj.example/tts"))
    }

    func testSendsSessionTokenNeverProviderKeyAndValidatesResponse() async throws {
        let ok = FakeTransport(status: 200, headers: ["Content-Type": "audio/wav", "X-Audio-Duration": "3.2"], body: Data([1, 2, 3]))
        let provider = ProxyVoiceProvider(configuration: try config("https://voice.aerodj.example/tts"), transport: ok)
        let artifact = try await provider.synthesize("<speak>Hi</speak>", voice: voice,
                                                     context: RequestContext(stationID: "s", isReusableGeneric: false))
        XCTAssertEqual(artifact.durationSeconds, 3.2)
        XCTAssertEqual(artifact.provider, "cartesia")
        let requests = await ok.seen.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-session-123")
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(Set(body.keys), ["upstream", "voiceId", "text", "format", "stationId"])
        XCTAssertEqual(body["format"], "ssml")

        for (status, headers, data) in [
            (500, ["Content-Type": "audio/wav", "X-Audio-Duration": "1"], Data([1])),
            (200, ["Content-Type": "text/html", "X-Audio-Duration": "1"], Data([1])),
            (200, ["Content-Type": "audio/wav"], Data([1])),
            (200, ["Content-Type": "audio/wav", "X-Audio-Duration": "nan"], Data([1])),
            (200, ["Content-Type": "audio/wav", "X-Audio-Duration": "1"], Data()),
        ] {
            let bad = ProxyVoiceProvider(configuration: try config("https://voice.aerodj.example/tts"),
                                         transport: FakeTransport(status: status, headers: headers, body: data))
            do {
                _ = try await bad.synthesize("Hi", voice: voice, context: RequestContext(stationID: "s", isReusableGeneric: false))
                XCTFail("accepted \(status) \(headers)")
            } catch {
                guard case VoiceRenderError.invalidResponse = error else { return XCTFail("\(error)") }
            }
        }
    }
}
