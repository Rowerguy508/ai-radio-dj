import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// Break stitching (#365). Each line of a DJ break can go to the cloud voice with the neighbouring
// lines of that break as context. A neighbour is included only when `mayLeaveDevice` already
// allows that neighbour off the device (#176, the renderer's current scope). In-process fakes
// only: no network, no paid service. -Echo

private final class TimedContextSpy: VoiceProvider, @unchecked Sendable {
    let seconds: @Sendable (String) -> Double
    init(seconds: @escaping @Sendable (String) -> Double) { self.seconds = seconds }
    private let lock = NSLock()
    private var seen: [(text: String, context: RequestContext)] = []
    var calls: [(text: String, context: RequestContext)] { lock.withLock { seen } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { seen.append((text, context)) }
        let duration = seconds(text)
        return VoiceArtifact(data: Data("clip".utf8), durationSeconds: duration, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

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
        await log.add(request)
        return (Data([1, 2]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "audio/wav", "X-Audio-Duration": "1.5"])!)
    }
}

private actor BodyLog {
    var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
}

private struct FixedInstallToken: InstallTokenProviding {
    func installToken() async throws -> InstallToken {
        InstallToken(value: "install-token", expiresAt: Date().addingTimeInterval(3600))
    }
    func tokenRejected(_ token: InstallToken) async {}
    func keyRejected() async {}
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

    private func cloud(_ spy: ContextSpy, context: Bool = true, tags: Bool = false, ssml: Bool = false) -> VoiceRoute {
        VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice, acceptsSSML: ssml, leavesDevice: true,
                   sendsSpeechContext: context, supportsAudioTags: tags)
    }

    private func renderer(_ routes: [VoiceRoute], cache: any AudioCache = InMemoryAudioCache(),
                          revocations: NarrationRevocations = NarrationRevocations(),
                          scope: @escaping @Sendable () -> CloudVoiceScope = { .transitionsOnly }) -> VoiceRenderer {
        VoiceRenderer(routes: routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: cache,
                      revocations: revocations, cloudScope: scope)
    }

    private func proxy(_ upstream: ProxyVoiceProvider.Upstream, _ transport: BodyTransport,
                       install: Bool = false) throws -> ProxyVoiceProvider {
        let configuration: ProxyVoiceProvider.Configuration
        if install {
            configuration = try .init(endpoint: URL(string: "https://voice.aerodj.example/tts")!,
                                      allowedHosts: ["voice.aerodj.example"], upstream: upstream,
                                      installTokens: FixedInstallToken())
        } else {
            configuration = try .init(endpoint: URL(string: "https://voice.aerodj.example/tts")!,
                                      allowedHosts: ["voice.aerodj.example"], upstream: upstream,
                                      sessionToken: { "session" })
        }
        return ProxyVoiceProvider(configuration: configuration, transport: transport)
    }

    private func body(_ data: Data) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: data)
    }

    // MARK: Proxy request body

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
                                                    context: RequestContext(stationID: "s", isReusableGeneric: false,
                                                                            previousText: "A.", nextText: "B."))
        let requests = await t.log.requests
        let bodies = try requests.map { try body(XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(bodies[0]["previousText"], "Hey, good morning.")
        XCTAssertEqual(bodies[0]["nextText"], "It's nine-forty.")
        XCTAssertEqual(bodies[0]["text"], "Okay, here's the next one.")
        XCTAssertEqual(Set(bodies[1].keys), ["upstream", "voiceId", "text", "format", "stationId"], "no context: the old contract exactly")
        XCTAssertEqual(Set(bodies[2].keys), ["upstream", "voiceId", "text", "format", "stationId"], "blank context is omitted")
        XCTAssertEqual(Set(bodies[3].keys), ["upstream", "voiceId", "text", "format", "stationId"], "only ElevenLabs gets context")
    }

    func testNoContextRequestBodyIsByteIdenticalToTheFiveFieldBody() async throws {
        let t = BodyTransport()
        _ = try await proxy(.elevenlabs, t).synthesize("Hi.", voice: djVoice,
                                                      context: RequestContext(stationID: "s", isReusableGeneric: false))
        let recorded = await t.log.requests
        let sent = try XCTUnwrap(recorded.first?.httpBody)
        let fields = ProxyVoiceProvider.requestBody(text: "Hi.", voice: djVoice,
                                                    context: RequestContext(stationID: "s", isReusableGeneric: false),
                                                    upstream: .elevenlabs)
        // The pre-#365 body: the same five keys, encoded by the same JSONEncoder. Object key order
        // is not stable (Darwin never; Linux only when two dictionaries share a layout), so the
        // contract is the object, not the raw bytes.
        let five: [String: String] = [
            "upstream": "elevenlabs", "voiceId": djVoice.id, "text": "Hi.", "format": "text", "stationId": "s",
        ]
        XCTAssertEqual(fields, five, "no context is exactly the five fields the old body encoded")
        XCTAssertEqual(try body(sent), five)
        XCTAssertNil(try body(sent)["previousText"])
        XCTAssertNil(try body(sent)["nextText"])
    }

    func testProxyTrimsContextKeepingTheSideNearestTheLine() {
        let long = String(repeating: "a", count: 400)
        XCTAssertEqual(ProxyVoiceProvider.contextField(long + " END", keep: .end)?.hasSuffix(" END"), true)
        XCTAssertEqual(ProxyVoiceProvider.contextField("START " + long, keep: .start)?.hasPrefix("START "), true)
        XCTAssertLessThanOrEqual(ProxyVoiceProvider.contextField(long, keep: .end)?.count ?? 0, ProxyVoiceProvider.maxContextCharacters)
        XCTAssertEqual(ProxyVoiceProvider.maxContextCharacters, 300)
        let trimmed = ProxyVoiceProvider.contextField(String(repeating: " ", count: 10) + long, keep: .end)
        XCTAssertEqual(trimmed?.count, 300)
        XCTAssertFalse(trimmed?.hasPrefix(" ") ?? true)
        XCTAssertFalse(trimmed?.hasSuffix(" ") ?? true)
        XCTAssertNil(ProxyVoiceProvider.contextField(" \n", keep: .start))
        XCTAssertNil(ProxyVoiceProvider.contextField(nil, keep: .end))
    }

    func testContextFieldsDoNotChangeBearerOrInstallTokenAuth() async throws {
        let bearerLog = BodyTransport()
        _ = try await proxy(.elevenlabs, bearerLog).synthesize("Hi.", voice: djVoice,
                                                              context: RequestContext(stationID: "s", isReusableGeneric: false,
                                                                                      previousText: "Before.", nextText: "After."))
        let bearerRequests = await bearerLog.log.requests
        let bearer = try XCTUnwrap(bearerRequests.first)
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Authorization"), "Bearer session")
        XCTAssertNil(bearer.value(forHTTPHeaderField: ProxyVoiceProvider.installTokenHeader))
        XCTAssertEqual(try body(XCTUnwrap(bearer.httpBody))["previousText"], "Before.")

        let installLog = BodyTransport()
        _ = try await proxy(.elevenlabs, installLog, install: true).synthesize(
            "Hi.", voice: djVoice,
            context: RequestContext(stationID: "s", isReusableGeneric: false, previousText: "Before.", nextText: "After."))
        let installRequests = await installLog.log.requests
        let install = try XCTUnwrap(installRequests.first)
        XCTAssertEqual(install.value(forHTTPHeaderField: ProxyVoiceProvider.installTokenHeader), "install-token")
        XCTAssertNil(install.value(forHTTPHeaderField: "Authorization"), "install-token requests still never send a bearer")
        XCTAssertEqual(try body(XCTUnwrap(install.httpBody))["nextText"], "After.")
    }

    // MARK: Cache key

    func testNoContextCacheKeyIsByteIdentical() {
        let route = cloud(ContextSpy())
        let text = "That was Holocene."
        XCTAssertEqual(VoiceRenderer.cacheKey(text: text, route: route, context: .none),
                       VoiceRenderer.cacheKey(text: text, route: route))
        XCTAssertEqual(VoiceRenderer.cacheKey(text: text, route: route, context: SpeechNeighbours(previous: "", next: nil)),
                       VoiceRenderer.cacheKey(text: text, route: route))
        XCTAssertEqual(VoiceRenderer.spokenText(text, for: route), SpeechDelivery.speakable(text))
        let ssml = cloud(ContextSpy(), ssml: true)
        XCTAssertEqual(VoiceRenderer.spokenText("It's 9:00 PM.", for: ssml), SpeechDelivery.ssml("It's 9:00 PM."),
                       "bracket-free SSML is unchanged, so those cache keys stay put")
    }

    func testCacheKeyIncludesContext() async {
        let spy = ContextSpy()
        let route = cloud(spy)
        let r = renderer([route])
        let before = transition("Mm, nice.")
        let line = transition("That was Holocene.")
        let after = transition("Here's Skinny Love.")
        let cues = [before, line, after]
        let attrs: [UUID: SpokenAttribution] = [before.id: .presenter, line.id: .presenter, after.id: .presenter]
        guard case .success(let withContext) = await r.render(line, userID: "u", stationID: "s", attribution: .presenter,
                                                              breakCues: cues, breakAttributions: attrs) else {
            return XCTFail("render")
        }
        let spoken = SpeechNeighbours(previous: "Mm, nice.", next: "Here's Skinny Love.")
        XCTAssertEqual(spy.calls.first?.context.previousText, "Mm, nice.")
        XCTAssertEqual(spy.calls.first?.context.nextText, "Here's Skinny Love.")
        XCTAssertEqual(withContext.cacheKey, VoiceRenderer.cacheKey(text: "That was Holocene.", route: route, context: spoken))
        XCTAssertNotEqual(withContext.cacheKey, VoiceRenderer.cacheKey(text: "That was Holocene.", route: route),
                          "the same words in another break are a different take")
        guard case .success(let plain) = await r.render(line, userID: "u", stationID: "s", attribution: .presenter) else {
            return XCTFail("render")
        }
        XCTAssertEqual(plain.cacheKey, VoiceRenderer.cacheKey(text: "That was Holocene.", route: route))
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertNil(spy.calls[1].context.previousText)
        XCTAssertNil(spy.calls[1].context.nextText)
    }

    // MARK: Who may be context

    func testAnIneligibleNeighbourIsOmittedWithoutDroppingTheOtherSide() {
        let before = personal("From your calendar: dentist at 3.")
        let line = transition("That was Holocene.")
        let after = transition("Here's Skinny Love.")
        let cues = [before, line, after]
        let attrs: [UUID: SpokenAttribution] = [
            before.id: .personalContext(itemID: UUID(), source: .calendar, provenance: "test:item"),
            line.id: .presenter, after.id: .presenter,
        ]
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: cues, attributions: attrs),
                       SpeechNeighbours(previous: nil, next: "Here's Skinny Love."),
                       "only the neighbour that may leave goes along")
        XCTAssertEqual(VoiceRenderer.neighbours(of: before, in: cues, attributions: attrs).next, "That was Holocene.")
        XCTAssertEqual(VoiceRenderer.neighbours(of: transition("Not in the break."), in: cues, attributions: attrs), .none)
    }

    func testOnlyCuesThatMayLeaveCanSendOrReceiveContext() {
        let kinds: [BriefingScriptSegment.Kind] = [.opener, .upcomingEvent, .dueTask, .followUp, .note, .fallback, .closer, .transition]
        let after = transition("Here's the next one.")
        for kind in kinds {
            let cue = NarrationCue(id: UUID(), order: 0, group: 0, kind: kind, text: "Line for \(kind).",
                                   estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
            let line = transition("Middle.")
            let cues = [cue, line, after]
            let attrs: [UUID: SpokenAttribution] = [cue.id: .presenter, line.id: .presenter, after.id: .presenter]
            let may = VoiceRenderer.mayLeaveDevice(cue, attribution: .presenter)
            let neighbours = VoiceRenderer.neighbours(of: line, in: cues, attributions: attrs)
            if may {
                XCTAssertEqual(kind, .transition)
                XCTAssertEqual(neighbours.previous, cue.text)
            } else {
                XCTAssertNil(neighbours.previous, "\(kind) is not a #176 line, so it is not context")
            }
            XCTAssertEqual(neighbours.next, after.text)
        }
        let sourced = NarrationCue(id: UUID(), order: 0, group: 0, kind: .transition, text: "Your 3 p.m. is the dentist.",
                                   estimatedSeconds: 3, maxSeconds: 20, sourceItemID: UUID(), source: .calendar, provenance: "test:item")
        let line = transition("Middle.")
        XCTAssertFalse(VoiceRenderer.mayLeaveDevice(sourced, attribution: .presenter))
        XCTAssertNil(VoiceRenderer.neighbours(of: line, in: [sourced, line], attributions: [
            sourced.id: .presenter, line.id: .presenter,
        ]).previous, "a sourced line is local-only even when the attribution says presenter")
    }

    func testPersonalAndLocalOnlyCuesNeverSendOrReceiveContext() async {
        let before = transition("Mm, nice.")
        let line = transition("That was Holocene.")
        let after = transition("Here's Skinny Love.")
        let cues = [before, line, after]
        let catalog = SpokenAttribution.trackMetadata(trackIDs: ["t"], origin: .catalog)
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: cues, attributions: [
            before.id: .presenter, line.id: .presenter, after.id: catalog,
        ]), SpeechNeighbours(previous: "Mm, nice.", next: "Here's Skinny Love."))
        XCTAssertEqual(VoiceRenderer.neighbours(of: before, in: cues, attributions: [
            before.id: .presenter, line.id: .presenter,
        ]), SpeechNeighbours(previous: nil, next: "That was Holocene."))

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
                let neighbours = VoiceRenderer.neighbours(of: line, in: cues, attributions: a)
                if side == before.id {
                    XCTAssertNil(neighbours.previous, "\(attribution)")
                    XCTAssertEqual(neighbours.next, after.text)
                } else {
                    XCTAssertEqual(neighbours.previous, before.text)
                    XCTAssertNil(neighbours.next, "\(attribution)")
                }
            }
        }
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: [line, after], attributions: [line.id: .presenter]),
                       .none, "a missing attribution is local-only")

        let cloudSpy = ContextSpy()
        let deviceSpy = ContextSpy()
        let personalCue = personal("Dentist at 3.")
        let around = [transition("A."), personalCue, transition("B.")]
        let personalAttrs: [UUID: SpokenAttribution] = [
            around[0].id: .presenter,
            personalCue.id: .personalContext(itemID: UUID(), source: .calendar, provenance: "test:item"),
            around[2].id: .presenter,
        ]
        let r = renderer([cloud(cloudSpy), VoiceRoute(providerID: "device", provider: deviceSpy, voice: djVoice)])
        guard case .success = await r.render(personalCue, userID: "u", stationID: "s",
                                             attribution: personalAttrs[personalCue.id],
                                             breakCues: around, breakAttributions: personalAttrs) else {
            return XCTFail("the on-device voice still speaks the personal line")
        }
        XCTAssertTrue(cloudSpy.calls.isEmpty, "a personal cue never reaches the cloud voice")
        XCTAssertNil(deviceSpy.calls.first?.context.previousText, "and it sends no context to the on-device voice")
        XCTAssertNil(deviceSpy.calls.first?.context.nextText)
    }

    func testContextWidensOnlyThroughMayLeaveDeviceScope() async {
        let personalCue = personal("Dentist at 3.")
        let line = transition("That was Holocene.")
        let cues = [personalCue, line]
        let attrs: [UUID: SpokenAttribution] = [
            personalCue.id: .personalContext(itemID: UUID(), source: .calendar, provenance: "test:item"),
            line.id: .presenter,
        ]
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: cues, attributions: attrs, scope: .transitionsOnly), .none)
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: cues, attributions: attrs, scope: .noLines), .none)
        let unattributed = transition("No attribution.")
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: [unattributed, line], attributions: [line.id: .presenter], scope: .allLines),
                       .none, "a cue with no attribution still does not leave")
        XCTAssertEqual(VoiceRenderer.neighbours(of: line, in: cues, attributions: attrs, scope: .allLines),
                       SpeechNeighbours(previous: "Dentist at 3.", next: nil,
                                        sourceItemIDs: [personalCue.sourceItemID!], needsAllLinesTag: true),
                       "allLines widens context only because mayLeaveDevice does, and the item stays tagged")

        let strict = ContextSpy()
        _ = await renderer([cloud(strict)]).render(line, userID: "u", stationID: "s", attribution: .presenter,
                                                   breakCues: cues, breakAttributions: attrs)
        XCTAssertNil(strict.calls.first?.context.previousText, "the default scope is transitionsOnly")

        let wide = ContextSpy()
        _ = await renderer([cloud(wide)], scope: { .allLines }).render(
            line, userID: "u", stationID: "s", attribution: .presenter, breakCues: cues, breakAttributions: attrs)
        XCTAssertEqual(wide.calls.first?.context.previousText, "Dentist at 3.")

        let blocked = ContextSpy()
        let device = ContextSpy()
        _ = await renderer([cloud(blocked), VoiceRoute(providerID: "device", provider: device, voice: djVoice)],
                           scope: { .noLines }).render(line, userID: "u", stationID: "s", attribution: .presenter,
                                                       breakCues: [transition("A."), line, transition("B.")],
                                                       breakAttributions: [line.id: .presenter])
        XCTAssertTrue(blocked.calls.isEmpty)
        XCTAssertNil(device.calls.first?.context.previousText)
    }

    func testRouteWithoutSpeechContextAndOnDeviceRoutesSendNone() async {
        let spy = ContextSpy()
        let before = transition("A.")
        let line = transition("Hi.")
        let after = transition("B.")
        let cues = [before, line, after]
        let attrs: [UUID: SpokenAttribution] = [before.id: .presenter, line.id: .presenter, after.id: .presenter]
        _ = await renderer([cloud(spy, context: false)]).render(line, userID: "u", stationID: "s", attribution: .presenter,
                                                               breakCues: cues, breakAttributions: attrs)
        XCTAssertNil(spy.calls.first?.context.previousText)
        XCTAssertNil(spy.calls.first?.context.nextText)

        let local = VoiceRoute(providerID: "device", provider: ContextSpy(), voice: djVoice, sendsSpeechContext: true, supportsAudioTags: true)
        XCTAssertFalse(local.sendsSpeechContext, "on-device routes are forced off")
        XCTAssertTrue(local.supportsAudioTags, "the tag flag is stored, and off-device stripping is what reads it")
        XCTAssertFalse(local.leavesDevice)
        let onDevice = ContextSpy()
        _ = await renderer([VoiceRoute(providerID: "device", provider: onDevice, voice: djVoice, sendsSpeechContext: true)]).render(
            line, userID: "u", stationID: "s", attribution: .presenter, breakCues: cues, breakAttributions: attrs)
        XCTAssertNil(onDevice.calls.first?.context.previousText)
        XCTAssertEqual(onDevice.calls.first?.text, "Hi.")
    }

    // MARK: Brackets

    func testBracketsAreStrippedOnOffDeviceRoutes() {
        XCTAssertEqual(SpeechDelivery.speakable("That was Song [Live] from Band.", keepingAudioTags: false),
                       "That was Song Live from Band.")
        XCTAssertEqual(SpeechDelivery.speakable("That was Song [Live].", keepingAudioTags: false), "That was Song Live .")
        XCTAssertEqual(SpeechDelivery.speakable("[whispers] hi", keepingAudioTags: true), "whispers hi")
        XCTAssertEqual(SpeechDelivery.speakable("[warmly] Hey there.", keepingAudioTags: false), "warmly Hey there.")
        XCTAssertEqual(SpeechDelivery.speakable("[ Warmly ] Hey.", keepingAudioTags: true), "[warmly] Hey.")
        XCTAssertEqual(SpeechDelivery.speakable("a ] [warmly] [ b", keepingAudioTags: true), "a [warmly] b")
        XCTAssertEqual(SpeechDelivery.speakable("It's 9:00 PM.", keepingAudioTags: false), SpeechDelivery.speakable("It's 9:00 PM."),
                       "text without brackets is exactly speakable")
        let device = VoiceRoute(providerID: "device", provider: ContextSpy(), voice: djVoice)
        XCTAssertEqual(VoiceRenderer.spokenText("Song [Live].", for: device), SpeechDelivery.speakable("Song [Live]."),
                       "on-device text is not rewritten")
        XCTAssertFalse(device.supportsAudioTags)
        XCTAssertFalse(device.sendsSpeechContext)
    }

    func testRendererStripsBracketsForOffDeviceRoutesAndKeepsTagsOnlyWhenEnabled() async {
        let plainSpy = ContextSpy(), tagSpy = ContextSpy()
        _ = await renderer([cloud(plainSpy)]).render(transition("[warmly] That was Song [Live]."), userID: "u", stationID: "s",
                                                     attribution: .presenter)
        _ = await renderer([cloud(tagSpy, tags: true)]).render(transition("[warmly] That was Song [Live]."), userID: "u",
                                                               stationID: "s", attribution: .presenter)
        XCTAssertEqual(plainSpy.calls.first?.text, "warmly That was Song Live .")
        XCTAssertEqual(tagSpy.calls.first?.text, "[warmly] That was Song Live .")
        XCTAssertFalse(cloud(plainSpy).supportsAudioTags)
    }

    func testContextIsPlainBracketFreeText() async {
        let spy = ContextSpy()
        let previous = transition("[warmly] Song [Live] at 9:00 PM.")
        let line = transition("Hi.")
        _ = await renderer([cloud(spy, tags: true)]).render(
            line, userID: "u", stationID: "s", attribution: .presenter,
            breakCues: [previous, line], breakAttributions: [previous.id: .presenter, line.id: .presenter])
        XCTAssertEqual(spy.calls.first?.context.previousText, "warmly Song Live at 9 p.m.")
        XCTAssertFalse(spy.calls.first?.context.previousText?.contains("[") ?? true)
        XCTAssertFalse(spy.calls.first?.context.previousText?.contains("]") ?? true)
    }

    // MARK: The ElevenLabs routes

    func testElevenLabsRoutesSendContextButNoAudioTags() throws {
        let onDevice = [VoiceRoute(providerID: "device", provider: ContextSpy(), voice: djVoice, sendsSpeechContext: true)]
        let c = PremiumVoiceRoutes.compose(
            onDevice: onDevice, paidProvidersEnabled: true, access: .allowed,
            selectedVoiceID: "x70vRnQBMBu4FAYhjJbO",
            credentials: PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "t"))
        XCTAssertEqual(c.routes.first?.providerID, "elevenlabs")
        XCTAssertEqual(c.routes.first?.sendsSpeechContext, true)
        XCTAssertEqual(c.routes.first?.supportsAudioTags, false)
        XCTAssertEqual(c.routes.last?.sendsSpeechContext, false, "the on-device fallback stays off")
        XCTAssertEqual(c.routes.first?.isPaid, false, "this does not price the route")

        let attested = PremiumVoiceRoutes.composeAttested(
            onDevice: onDevice, route: .installToken, voiceID: PremiumVoiceCatalog.voices[0].id,
            tokens: FixedInstallToken(), backoff: nil)
        XCTAssertEqual(attested.routes.first?.sendsSpeechContext, true)
        XCTAssertEqual(attested.routes.first?.supportsAudioTags, false)
        XCTAssertEqual(attested.routes.first?.leavesDevice, true)
        XCTAssertFalse(attested.routes.first?.isPaid ?? true)

        let off = PremiumVoiceRoutes.compose(
            onDevice: onDevice, paidProvidersEnabled: false, access: .allowed,
            selectedVoiceID: "x70vRnQBMBu4FAYhjJbO",
            credentials: PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "t"))
        XCTAssertEqual(off.routes.map(\.providerID), ["device"], "paid voice stays off when the gate is off")
    }

    func testRequestContextDecodesOldPayloads() throws {
        let old = Data(#"{"stationID":"s","isReusableGeneric":false}"#.utf8)
        let decoded = try JSONDecoder().decode(RequestContext.self, from: old)
        XCTAssertEqual(decoded, RequestContext(stationID: "s", isReusableGeneric: false))
        XCTAssertNil(decoded.previousText)
        XCTAssertNil(decoded.nextText)
        let encoded = try JSONEncoder().encode(RequestContext(stationID: "s", isReusableGeneric: false))
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["stationID", "isReusableGeneric"], "nil context is omitted when the struct is encoded")
    }

    // MARK: Purge covers neighbour context (Sentinel B1)

    func testPendingRevokeOfANeighbourBlocksItsTextAsContext() async {
        let item = UUID()
        let calendar = NarrationCue(id: UUID(), order: 0, group: 0, kind: .upcomingEvent, text: "Dentist at 3.",
                                    estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .calendar, provenance: "test:item")
        let line = transition("That was Holocene.")
        let cues = [calendar, line]
        let attrs: [UUID: SpokenAttribution] = [
            calendar.id: .personalContext(itemID: item, source: .calendar, provenance: "test:item"),
            line.id: .presenter,
        ]
        let revocations = NarrationRevocations()
        revocations.revoke([item])
        let spy = ContextSpy()
        let refused = await renderer([cloud(spy)], revocations: revocations, scope: { .allLines }).render(
            line, userID: "u", stationID: "s", attribution: .presenter, breakCues: cues, breakAttributions: attrs)
        guard case .failure = refused else { return XCTFail("a pending purge of the neighbour must refuse the render") }
        XCTAssertTrue(spy.calls.isEmpty, "the neighbour's text must not leave while its purge is pending")

        revocations.purgeCompleted([item])
        let cache = InMemoryAudioCache()
        let again = ContextSpy()
        guard case .success(let clip) = await renderer([cloud(again)], cache: cache, revocations: revocations, scope: { .allLines }).render(
            line, userID: "u", stationID: "s", attribution: .presenter, breakCues: cues, breakAttributions: attrs) else {
            return XCTFail("once the purge finishes, the line renders")
        }
        XCTAssertEqual(again.calls.first?.context.previousText, "Dentist at 3.")
        XCTAssertTrue(clip.audio.sourceItemIDs.contains(item))
        XCTAssertTrue(clip.audio.sourceItemIDs.contains(VoiceRenderer.allLinesClipTag))
        await cache.purge(sourceItemIDs: [item])
        let left = await cache.count
        XCTAssertEqual(left, 0, "a later purge of the neighbour finds the clip")
    }

    func testPendingRevokeAllBlocksNeighbourContext() async {
        let item = UUID()
        let calendar = NarrationCue(id: UUID(), order: 0, group: 0, kind: .upcomingEvent, text: "Dentist at 3.",
                                    estimatedSeconds: 3, maxSeconds: 20, sourceItemID: item, source: .calendar, provenance: "test:item")
        let line = transition("That was Holocene.")
        let cues = [calendar, line]
        let attrs: [UUID: SpokenAttribution] = [
            calendar.id: .personalContext(itemID: item, source: .calendar, provenance: "test:item"),
            line.id: .presenter,
        ]
        let revocations = NarrationRevocations()
        revocations.revokeAll()
        let spy = ContextSpy()
        let refused = await renderer([cloud(spy)], revocations: revocations, scope: { .allLines }).render(
            line, userID: "u", stationID: "s", attribution: .presenter, breakCues: cues, breakAttributions: attrs)
        guard case .failure = refused else { return XCTFail("a purge-all in flight must refuse context that quotes a personal line") }
        XCTAssertTrue(spy.calls.isEmpty)

        revocations.purgeAllCompleted()
        let again = ContextSpy()
        guard case .success = await renderer([cloud(again)], revocations: revocations, scope: { .allLines }).render(
            line, userID: "u", stationID: "s", attribution: .presenter, breakCues: cues, breakAttributions: attrs) else {
            return XCTFail("after the purge-all finishes, the line renders")
        }
        XCTAssertEqual(again.calls.first?.context.previousText, "Dentist at 3.")
    }

    // MARK: Time check (#347)

    func testHeldBackTimeCheckIsNotContextForLinesRenderedEarly() {
        let time = transition("It's 9:40.")
        let closing = transition("Up next, Song 1 by Artist 1.")
        let full = [time, closing]
        let attrs: [UUID: SpokenAttribution] = [
            time.id: .presenter, closing.id: .trackMetadata(trackIDs: ["t1"], origin: .catalog),
        ]
        let rest = full.filter { $0.id != time.id }
        XCTAssertEqual(VoiceRenderer.neighbours(of: closing, in: rest, attributions: attrs), .none,
                       "the early render drops the time check, so this minute's reading is not part of the cache key")
        XCTAssertEqual(VoiceRenderer.neighbours(of: time, in: full, attributions: attrs),
                       SpeechNeighbours(previous: nil, next: "Up next, Song 1 by Artist 1."))
    }

    func testTimeCheckIsRenderedAloneWithItsPlannedNeighboursAsContext() async {
        let clock = LockedClock(Self.date(9, 40))
        let spy = ContextSpy()
        let route = VoiceRoute(providerID: "cloud", provider: spy, voice: VoiceProfile(id: "cloud-voice", name: "Host"),
                               leavesDevice: true, sendsSpeechContext: true, supportsAudioTags: false)
        let p = DJBreakPreparer(renderer: renderer([route]), userID: "u", stationID: "s", talkOverEnabled: { true },
                                now: { clock.now }, sleepUntil: { _ in clock.now = Self.date(9, 52) })
        let planned = Self.timeCheckBreak()
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let aired = await eventually { await Self.ready(p)?.cues.count == 2 }
        XCTAssertTrue(aired)
        let calls = spy.calls
        XCTAssertEqual(calls.count, 2, "the closing line first, then the time check alone: \(calls.map(\.text))")
        XCTAssertEqual(calls[0].text, "Up next, Song 1 by Artist 1.")
        XCTAssertNil(calls[0].context.previousText, "the held-back time check is not context for the lines rendered early")
        XCTAssertNil(calls[0].context.nextText)
        XCTAssertFalse(calls[1].text.contains("9:40"), "the plan-time reading is not what is spoken: \(calls[1].text)")
        XCTAssertTrue(calls[1].text.contains("9:55"))
        XCTAssertNil(calls[1].context.previousText)
        XCTAssertEqual(calls[1].context.nextText, "Up next, Song 1 by Artist 1.", "the late line still hears its planned neighbour")
        await p.cancelAll()
    }

    /// A line the cap trims, and the held-back time check, are not neighbours of the lines that air.
    func testATrimmedOrHeldBackCueIsNotSentAsANeighbour() async {
        let clock = LockedClock(Self.date(9, 40))
        let spy = TimedContextSpy { text in
            if text.hasPrefix("Grey morning") { return 9 }
            if text.hasPrefix("Up next") { return 3 }
            return 1
        }
        let route = VoiceRoute(providerID: "cloud", provider: spy, voice: VoiceProfile(id: "cloud-voice", name: "Host"),
                               leavesDevice: true, sendsSpeechContext: true, supportsAudioTags: false)
        let p = DJBreakPreparer(renderer: renderer([route]), userID: "u", stationID: "s", talkOverEnabled: { true },
                                now: { clock.now }, sleepUntil: { _ in clock.now = Self.date(9, 52) })
        let color = NarrationCue(id: UUID(), order: 1, group: -1, kind: .transition, text: "Grey morning secret line.",
                                 estimatedSeconds: 9, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
        let base = Self.timeCheckBreak()
        var attributions = base.attributions
        attributions[color.id] = .presenter
        var planned = DJBreak(afterTrack: base.afterTrack, cues: [color] + base.cues, attributions: attributions)
        planned.talkOverCueID = base.talkOverCueID
        planned.shape = base.shape
        planned.timeCheck = base.timeCheck
        planned.optionalCueIDs = [color.id]
        await p.prepare(planned, deadline: .seconds(60), onDeviceOnly: false)
        let aired = await eventually { await Self.ready(p)?.cues.count == 2 }
        XCTAssertTrue(aired)
        let ready = await Self.ready(p)
        XCTAssertEqual(ready?.trimmedCueIDs, [color.id], "the long optional line is what the cap drops")
        XCTAssertFalse(ready?.cues.contains { $0.id == color.id } ?? true)
        let dropped = ["Grey morning secret line.", "It's 9:40.", "9:40"]
        for call in spy.calls {
            for secret in dropped {
                XCTAssertFalse(call.context.previousText?.contains(secret) ?? false, "previous carried \(secret): \(call)")
                XCTAssertFalse(call.context.nextText?.contains(secret) ?? false, "next carried \(secret): \(call)")
            }
        }
        let time = spy.calls.first { $0.text.contains("9:55") }
        XCTAssertEqual(time?.context.nextText, "Up next, Song 1 by Artist 1.", "the line that airs next is the neighbour")
        XCTAssertNil(time?.context.previousText)
        let closing = spy.calls.first { $0.text.hasPrefix("Up next") }
        XCTAssertNil(closing?.context.previousText, "the trimmed line and the held-back time check are not before it")
        XCTAssertNil(closing?.context.nextText)
        await p.cancelAll()
    }

    private static var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private static func date(_ hour: Int, _ minute: Int) -> Date {
        eastern.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: hour, minute: minute))!
    }

    private static func timeCheckBreak() -> DJBreak {
        let time = NarrationCue(id: UUID(), order: 1, group: -1, kind: .transition, text: "It's 9:40.",
                                estimatedSeconds: 1, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        let closing = NarrationCue(id: UUID(), order: 2, group: -1, kind: .transition, text: "Up next, Song 1 by Artist 1.",
                                   estimatedSeconds: 2, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        var b = DJBreak(afterTrack: 0, cues: [time, closing],
                        attributions: [time.id: .presenter, closing.id: .trackMetadata(trackIDs: ["t1"], origin: .catalog)])
        b.talkOverCueID = closing.id
        b.shape = .timeCheckIntro
        b.timeCheck = DJPlannedTimeCheck(cueID: time.id, plannedAt: date(9, 40),
                                         templates: [.on: "It's {time}.", .comingUp: "Almost {time}.", .justAfter: "Just after {time}."],
                                         calendar: eastern, style: .twelveHour)
        return b
    }

    private static func ready(_ p: DJBreakPreparer) async -> PreparedDJBreak? {
        if case .ready(let b)? = await p.testResult(afterTrack: 0) { return b }
        return nil
    }

    private func eventually(_ seconds: Double = 5, _ check: @escaping @Sendable () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await check()
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ now: Date) { value = now }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
