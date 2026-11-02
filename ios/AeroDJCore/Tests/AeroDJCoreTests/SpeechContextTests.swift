import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// Intonation plan (owner-approved 2026-11-02): each line of a break goes to the cloud voice with
// its neighbouring lines as stitching context, never a personal neighbour; brackets never reach a
// voice as text; audio tags stay off by default. In-process fakes only: no network, no paid service.

private final class ContextSpy: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(text: String, context: RequestContext)] = []
    var calls: [(text: String, context: RequestContext)] { lock.withLock { seen } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { seen.append((text, context)) }
        return VoiceArtifact(data: Data("clip".utf8), durationSeconds: 1, billableUnits: text.count, provider: "cloud", cacheKey: nil)
    }
}

private struct BodyTransport: HTTPTransport {
    let log = BodyLog()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await log.add(request.httpBody ?? Data())
        return (Data([1, 2]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "audio/wav", "X-Audio-Duration": "1.5"])!)
    }
}

private actor BodyLog {
    var bodies: [[String: String]] = []
    func add(_ data: Data) { bodies.append((try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]) }
}

final class SpeechContextTests: XCTestCase {
    private func transition(_ text: String) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                     estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
    }

    private func personal(_ text: String) -> NarrationCue {
        NarrationCue(id: UUID(), order: 1, group: 0, kind: .upcomingEvent, text: text, estimatedSeconds: 3, maxSeconds: 20,
                     sourceItemID: UUID(), source: .calendar, provenance: "test:item")
    }

    private func cloud(_ spy: ContextSpy, context: Bool = true, tags: Bool = false) -> VoiceRoute {
        VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice, leavesDevice: true,
                   sendsSpeechContext: context, supportsAudioTags: tags)
    }

    private func renderer(_ routes: [VoiceRoute], cache: any AudioCache = InMemoryAudioCache()) -> VoiceRenderer {
        VoiceRenderer(routes: routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache, revocations: NarrationRevocations())
    }

    // MARK: Proxy request body

    private func proxy(_ upstream: ProxyVoiceProvider.Upstream, _ transport: BodyTransport) throws -> ProxyVoiceProvider {
        ProxyVoiceProvider(configuration: try .init(endpoint: URL(string: "https://voice.aerodj.example/tts")!,
                                                    allowedHosts: ["voice.aerodj.example"], upstream: upstream,
                                                    sessionToken: { "session" }), transport: transport)
    }

    func testProxySendsContextOnlyWhenPresentAndOnlyToElevenLabs() async throws {
        let t = BodyTransport()
        let eleven = try proxy(.elevenlabs, t)
        _ = try await eleven.synthesize("Okay, here's the next one.", voice: djVoice,
                                        context: RequestContext(stationID: "s", isReusableGeneric: false,
                                                                previousText: "Hey, good morning.", nextText: "It's nine-forty."))
        _ = try await eleven.synthesize("Hi.", voice: djVoice, context: RequestContext(stationID: "s", isReusableGeneric: false))
        _ = try await eleven.synthesize("Hi.", voice: djVoice,
                                        context: RequestContext(stationID: "s", isReusableGeneric: false, previousText: "  ", nextText: nil))
        _ = try await proxy(.cartesia, t).synthesize("Hi.", voice: djVoice,
                                                    context: RequestContext(stationID: "s", isReusableGeneric: false, previousText: "A.", nextText: "B."))
        let bodies = await t.log.bodies
        XCTAssertEqual(bodies[0]["previousText"], "Hey, good morning.")
        XCTAssertEqual(bodies[0]["nextText"], "It's nine-forty.")
        XCTAssertEqual(Set(bodies[1].keys), ["upstream", "voiceId", "text", "format", "stationId"], "no context: the old contract exactly")
        XCTAssertEqual(Set(bodies[2].keys), ["upstream", "voiceId", "text", "format", "stationId"], "blank context is omitted")
        XCTAssertEqual(Set(bodies[3].keys), ["upstream", "voiceId", "text", "format", "stationId"], "only ElevenLabs gets context")
    }

    func testProxyTrimsContextKeepingTheSideNearestTheLine() {
        let long = String(repeating: "a", count: 400)
        XCTAssertEqual(ProxyVoiceProvider.context(long + " END", keep: .end)?.hasSuffix(" END"), true)
        XCTAssertEqual(ProxyVoiceProvider.context("START " + long, keep: .start)?.hasPrefix("START "), true)
        XCTAssertLessThanOrEqual(ProxyVoiceProvider.context(long, keep: .end)?.count ?? 0, ProxyVoiceProvider.maxContextCharacters)
        XCTAssertNil(ProxyVoiceProvider.context(" \n", keep: .start))
    }

    // MARK: Renderer

    func testRendererPassesNeighboursToAContextRouteAndKeysTheCacheOnThem() async {
        let spy = ContextSpy()
        let route = cloud(spy)
        let r = renderer([route])
        let line = transition("That was Holocene.")
        let around = SpeechNeighbours(previous: "Mm, nice.", next: "Here's Skinny Love.")
        guard case .success(let withContext) = await r.render(line, userID: "u", stationID: "s", attribution: .presenter,
                                                              neighbours: around) else { return XCTFail("render") }
        XCTAssertEqual(spy.calls.first?.context.previousText, "Mm, nice.")
        XCTAssertEqual(spy.calls.first?.context.nextText, "Here's Skinny Love.")
        XCTAssertEqual(withContext.cacheKey, VoiceRenderer.cacheKey(text: "That was Holocene.", route: route, context: around))
        XCTAssertNotEqual(withContext.cacheKey, VoiceRenderer.cacheKey(text: "That was Holocene.", route: route),
                          "the same words in another break are a different take")
        // Same words, no neighbours: a fresh render under the old key, not the contextual clip.
        guard case .success(let plain) = await r.render(line, userID: "u", stationID: "s", attribution: .presenter) else {
            return XCTFail("render")
        }
        XCTAssertEqual(plain.cacheKey, VoiceRenderer.cacheKey(text: "That was Holocene.", route: route))
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertNil(spy.calls[1].context.previousText)
    }

    func testNoContextKeyIsUnchangedSoExistingClipsStillHit() {
        let route = cloud(ContextSpy())
        XCTAssertEqual(VoiceRenderer.cacheKey(text: "Hi.", route: route, context: .none), VoiceRenderer.cacheKey(text: "Hi.", route: route))
        XCTAssertEqual(VoiceRenderer.cacheKey(text: "Hi.", route: route, context: SpeechNeighbours(previous: "", next: nil)),
                       VoiceRenderer.cacheKey(text: "Hi.", route: route))
    }

    func testRouteWithoutContextFlagGetsNone() async {
        let spy = ContextSpy()
        let r = renderer([cloud(spy, context: false)])
        _ = await r.render(transition("Hi."), userID: "u", stationID: "s", attribution: .presenter,
                           neighbours: SpeechNeighbours(previous: "A.", next: "B."))
        XCTAssertNil(spy.calls.first?.context.previousText)
        XCTAssertNil(spy.calls.first?.context.nextText)
    }

    func testContextNeedsARouteThatLeavesTheDevice() {
        let local = VoiceRoute(providerID: "device", provider: ContextSpy(), voice: djVoice, sendsSpeechContext: true)
        XCTAssertFalse(local.sendsSpeechContext)
        XCTAssertFalse(local.supportsAudioTags, "tags are off by default")
    }

    func testAPersonalNeighbourNeverRidesAlongAsContext() {
        let before = personal("From your calendar: dentist at 3.")
        let line = transition("That was Holocene.")
        let after = transition("Here's Skinny Love.")
        let cues = [before, line, after]
        let attributions: [UUID: SpokenAttribution] = [before.id: .personalContext(itemID: UUID(), source: .calendar, provenance: "test:item"), line.id: .presenter, after.id: .presenter]
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: cues, attributions: attributions), .none,
                       "a local-only neighbour means no context at all: not a redacted line, not just the other side")
        // Missing attribution on a neighbour is local-only too (fail closed).
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: [line, after], attributions: [line.id: .presenter]), .none)
        XCTAssertEqual(VoiceRenderer.neighbours(of: transition("Not in the break."), in: cues, attributions: attributions), .none)
    }

    func testContextOnlyWhenEveryNeighbourMayLeaveTheDevice() {
        let before = transition("Mm, nice.")
        let line = transition("That was Holocene.")
        let after = transition("Here's Skinny Love.")
        let cues = [before, line, after]
        let catalog = SpokenAttribution.trackMetadata(trackIDs: ["t"], origin: .catalog)
        // Both neighbours eligible: both are sent.
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: cues,
                                                attributions: [before.id: .presenter, line.id: .presenter, after.id: catalog]),
                       SpeechNeighbours(previous: "Mm, nice.", next: "Here's Skinny Love."))
        // An edge line with one eligible neighbour still gets that one.
        XCTAssertEqual(VoiceRenderer.neighbours(of: before, in: cues, attributions: [before.id: .presenter, line.id: .presenter]),
                       SpeechNeighbours(previous: nil, next: "That was Holocene."))
        // Every local-only attribution on either side drops all context.
        let localOnly: [SpokenAttribution] = [
            .personalContext(itemID: UUID(), source: .calendar, provenance: "test:item"),
            .stationName,
            .trackMetadata(trackIDs: ["t"], origin: .library),
            .trackMetadata(trackIDs: ["t"], origin: .unknown),
        ]
        for attribution in localOnly {
            for side in [before.id, after.id] {
                var a: [UUID: SpokenAttribution] = [before.id: .presenter, line.id: .presenter, after.id: .presenter]
                a[side] = attribution
                XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: cues, attributions: a), .none, "\(attribution)")
            }
        }
        // A sourced (briefing) neighbour is local-only even when attributed as the presenter.
        let briefing = personal("Your 3 p.m. is the dentist.")
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: [briefing, line, after],
                                                attributions: [briefing.id: .presenter, line.id: .presenter, after.id: .presenter]),
                       .none)
    }

    func testALocalOnlyNeighbourSendsNoContextToTheCloudVoice() async {
        let spy = ContextSpy()
        let r = renderer([cloud(spy)])
        let before = personal("Dentist at 3.")
        let line = transition("That was Holocene.")
        let after = transition("Here's Skinny Love.")
        let neighbours = VoiceRenderer.neighbours(of: line, in: [before, line, after],
                                                  attributions: [before.id: .personalContext(itemID: UUID(), source: .calendar, provenance: "test:item"),
                                                                 line.id: .presenter, after.id: .presenter])
        guard case .success(let clip) = await r.render(line, userID: "u", stationID: "s", attribution: .presenter,
                                                       neighbours: neighbours) else { return XCTFail("render") }
        XCTAssertEqual(spy.calls.count, 1, "the eligible line itself still renders in the cloud")
        XCTAssertNil(spy.calls.first?.context.previousText)
        XCTAssertNil(spy.calls.first?.context.nextText)
        XCTAssertEqual(clip.cacheKey, VoiceRenderer.cacheKey(text: "That was Holocene.", route: cloud(spy)), "no-context key")
    }

    func testALocalOnlyCueSendsNoContextAnywhere() async {
        let spy = ContextSpy()
        let device = ContextSpy()
        let r = renderer([cloud(spy), VoiceRoute(providerID: "device", provider: device, voice: djVoice)])
        _ = await r.render(personal("Dentist at 3."), userID: "u", stationID: "s", attribution: .personalContext(itemID: UUID(), source: .calendar, provenance: "test:item"),
                           neighbours: SpeechNeighbours(previous: "A.", next: "B."))
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertNil(device.calls.first?.context.previousText, "the on-device voice never gets context")
    }

    // MARK: Brackets and tags

    func testBracketsNeverReachACloudVoiceAsText() {
        XCTAssertEqual(SpeechDelivery.speakable("That was Song [Live] from Band.", keepingAudioTags: false), "That was Song Live from Band.")
        XCTAssertEqual(SpeechDelivery.speakable("[whispers] hi", keepingAudioTags: true), "whispers hi")
        XCTAssertEqual(SpeechDelivery.speakable("[warmly] Hey there.", keepingAudioTags: false), "Hey there.")
        XCTAssertEqual(SpeechDelivery.speakable("[ Warmly ] Hey.", keepingAudioTags: true), "[warmly] Hey.")
        XCTAssertEqual(SpeechDelivery.speakable("a ] [warmly] [ b", keepingAudioTags: true), "a [warmly] b")
        XCTAssertEqual(SpeechDelivery.speakable("It's 9:00 PM.", keepingAudioTags: false), SpeechDelivery.speakable("It's 9:00 PM."),
                       "text without brackets is exactly speakable, so cache keys do not move")
    }

    func testRendererStripsBracketsForCloudRoutesAndKeepsTagsOnlyWhenTheRouteReadsThem() async {
        let plainSpy = ContextSpy(), tagSpy = ContextSpy()
        _ = await renderer([cloud(plainSpy)]).render(transition("[warmly] That was Song [Live]."), userID: "u", stationID: "s",
                                                     attribution: .presenter)
        _ = await renderer([cloud(tagSpy, tags: true)]).render(transition("[warmly] That was Song [Live]."), userID: "u",
                                                               stationID: "s", attribution: .presenter)
        XCTAssertEqual(plainSpy.calls.first?.text, "That was Song Live .")
        XCTAssertEqual(tagSpy.calls.first?.text, "[warmly] That was Song Live .")
    }

    func testContextIsPlainBracketFreeText() async {
        let spy = ContextSpy()
        _ = await renderer([cloud(spy, tags: true)]).render(transition("Hi."), userID: "u", stationID: "s", attribution: .presenter,
                                                            neighbours: SpeechNeighbours(previous: "[warmly] Song [Live] at 9:00 PM.", next: nil))
        XCTAssertEqual(spy.calls.first?.context.previousText, "Song Live at 9 p.m.")
    }

    // MARK: The ElevenLabs route

    func testElevenLabsRouteSendsContextButNoTags() {
        let c = PremiumVoiceRoutes.compose(
            onDevice: [VoiceRoute(providerID: "device", provider: ContextSpy(), voice: djVoice)], paidProvidersEnabled: true, access: .allowed,
            selectedVoiceID: "x70vRnQBMBu4FAYhjJbO",
            credentials: PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "t"),
            pinnedHosts: ["aerodj-tts.vercel.app"])
        XCTAssertEqual(c.routes.first?.providerID, "elevenlabs")
        XCTAssertEqual(c.routes.first?.sendsSpeechContext, true)
        XCTAssertEqual(c.routes.first?.supportsAudioTags, false, "audio tags stay off by default")
        XCTAssertEqual(c.routes.last?.sendsSpeechContext, false)
    }

    func testRequestContextDecodesOldPayloads() throws {
        let old = Data(#"{"stationID":"s","isReusableGeneric":false}"#.utf8)
        let decoded = try JSONDecoder().decode(RequestContext.self, from: old)
        XCTAssertEqual(decoded, RequestContext(stationID: "s", isReusableGeneric: false))
    }
}
