import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// #154 gates (Sentinel): the over-cap fallback view never picks a paid or off-device route, and a
// station with a library seed is spoken on-device only, never through the ElevenLabs proxy.

private actor Calls {
    var count = 0
    func bump() { count += 1 }
}

private struct RecordingTransport: HTTPTransport {
    let calls = Calls()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await calls.bump()
        let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "3.0", "X-Billed-Characters": "20"]
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

private struct DeviceVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(voice.id.utf8), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

final class LibrarySeedVoiceGateTests: XCTestCase {
    private let juniper = "aMSt68OGf4xUZAnLpTU8"
    private let pinned: Set<String> = ["aerodj-tts.vercel.app"]
    private let creds = PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!,
                                                token: "owner-test-token")

    private func device(_ ids: [String] = ["premium", "standard"]) -> [VoiceRoute] {
        ids.map { VoiceRoute(providerID: "avspeech", provider: DeviceVoice(), voice: VoiceProfile(id: $0, name: "Host")) }
    }

    private func renderer(_ routes: [VoiceRoute]) -> VoiceRenderer {
        VoiceRenderer(routes: routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                      revocations: NarrationRevocations())
    }

    private func composed(onDevice: [VoiceRoute], transport: RecordingTransport) -> VoiceRenderer {
        let c = PremiumVoiceRoutes.compose(onDevice: onDevice, paidProvidersEnabled: true, selectedVoiceID: juniper,
                                           credentials: creds, pinnedHosts: pinned, transport: transport)
        return renderer(c.routes)
    }

    private func oneCueBreak() -> DJBreak {
        let cue = NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: "Up next from your library.",
                               estimatedSeconds: 2, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
        return DJBreak(afterTrack: 0, cues: [cue], attributions: [cue.id: .presenter])
    }

    // MARK: lastRouteOnly is never a paid or off-device route

    func testElevenLabsRouteIsMarkedAsLeavingTheDevice() {
        let r = composed(onDevice: device(), transport: RecordingTransport())
        XCTAssertEqual(r.routes.map(\.providerID), ["elevenlabs", "avspeech", "avspeech"])
        XCTAssertEqual(r.routes.first?.leavesDevice, true)
        XCTAssertEqual(r.routes.dropFirst().map(\.leavesDevice), [false, false])
    }

    func testLastRouteOnlyIsNeverPaidOrOffDevice() {
        let transport = RecordingTransport()
        let cloud = composed(onDevice: [], transport: transport).routes
        XCTAssertEqual(cloud.map(\.providerID), ["elevenlabs"])
        let paid = VoiceRoute(providerID: "paid", provider: DeviceVoice(), voice: VoiceProfile(id: "p", name: "P"),
                              microdollarsPerThousandCharacters: 30_000)
        let shapes: [[VoiceRoute]] = [
            composed(onDevice: device(), transport: transport).routes,
            composed(onDevice: device(["standard"]), transport: transport).routes,
            cloud,
            device() + cloud,   // a cloud route last must not become the fallback
            device() + [paid],  // nor a paid one
            [paid] + device(),
        ]
        for routes in shapes {
            if let only = renderer(routes).lastRouteOnly {
                XCTAssertEqual(only.routes.count, 1)
                XCTAssertTrue(only.routes.allSatisfy { !$0.isPaid && !$0.leavesDevice }, "\(routes.map(\.providerID))")
            }
        }
        XCTAssertNil(renderer(device() + cloud).lastRouteOnly)
        XCTAssertNil(renderer(device() + [paid]).lastRouteOnly)
        XCTAssertEqual(renderer(composed(onDevice: device(), transport: transport).routes).lastRouteOnly?.routes.map(\.voice.id), ["standard"])
    }

    func testOnDeviceOnlyDropsCloudAndPaidRoutesInOrder() {
        let r = composed(onDevice: device(), transport: RecordingTransport())
        XCTAssertEqual(r.onDeviceOnly?.routes.map(\.voice.id), ["premium", "standard"])
        XCTAssertNil(composed(onDevice: [], transport: RecordingTransport()).onDeviceOnly)
    }

    // MARK: Library-seed gate

    func testLibrarySeedMakesTheStationOnDeviceOnly() {
        let library = StationSeed(kind: .playlist, catalogID: "p.lib1", name: "Road Trip", source: .library)
        let catalog = StationSeed(kind: .artist, catalogID: "123", name: "Artist", source: .catalog)
        XCTAssertTrue(DJBreakSession.speaksOnDeviceOnly(StationConfiguration(seeds: [catalog, library])))
        XCTAssertFalse(DJBreakSession.speaksOnDeviceOnly(StationConfiguration(seeds: [catalog])))
        XCTAssertFalse(DJBreakSession.speaksOnDeviceOnly(StationConfiguration()))
    }

    private func prepared(_ r: VoiceRenderer, onDeviceOnly: Bool) async -> DJBreakOutcome {
        let preparer = DJBreakPreparer(renderer: r, userID: "u", stationID: "s")
        let done = AsyncStream<Void>.makeStream()
        await preparer.observe { event in
            switch event {
            case .prepared, .skipped: done.continuation.yield()
            case .preparing: break
            }
        }
        await preparer.prepare(oneCueBreak(), deadline: .seconds(5), onDeviceOnly: onDeviceOnly)
        for await _ in done.stream { break }
        return await preparer.takeBreak(afterTrack: 0)
    }

    func testLibraryStationBreakNeverCallsTheProxy() async {
        let transport = RecordingTransport()
        guard case .ready(let b) = await prepared(composed(onDevice: device(), transport: transport), onDeviceOnly: true) else {
            return XCTFail("an on-device route is available, so the break plays")
        }
        XCTAssertEqual(b.clips.map(\.audio.providerID), ["avspeech"])
        let calls = await transport.calls.count
        XCTAssertEqual(calls, 0, "library-seed break text never reaches the proxy")
    }

    func testLibraryStationWithOnlyACloudRouteSkipsInsteadOfSending() async {
        let transport = RecordingTransport()
        let outcome = await prepared(composed(onDevice: [], transport: transport), onDeviceOnly: true)
        XCTAssertEqual(outcome, .skipped(.renderFailed))
        let calls = await transport.calls.count
        XCTAssertEqual(calls, 0)
    }

    func testCatalogStationStillUsesTheSelectedCloudVoice() async {
        let transport = RecordingTransport()
        guard case .ready(let b) = await prepared(composed(onDevice: device(), transport: transport), onDeviceOnly: false) else {
            return XCTFail("catalog station renders normally")
        }
        XCTAssertEqual(b.clips.map(\.audio.providerID), ["elevenlabs"])
        let calls = await transport.calls.count
        XCTAssertEqual(calls, 1)
    }

    /// The session passes the gate from the active station (app wiring checked from source).
    func testSessionPassesTheLibraryGateToThePreparer() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AeroDJCore/DJ/DJBreakSession.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("preparer.prepare(djBreak, deadline: deadline, onDeviceOnly: Self.speaksOnDeviceOnly(station.active))"))
        XCTAssertEqual(text.components(separatedBy: "preparer.prepare(").count - 1, 1, "one prepare call site")
    }
}
