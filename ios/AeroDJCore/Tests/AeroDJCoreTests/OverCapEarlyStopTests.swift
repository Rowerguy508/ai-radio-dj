import XCTest
@testable import AeroDJCore

/// Remaining #293 delta on integration: once required (non-optional, non-closing) clips on the
/// first pass already exceed `BreakCap.main`, later cues are not sent to a cloud or paid route
/// that would be charged and then discarded before the last-route retry. Optional lines still
/// reach `BreakCap.fitting` so they can be trimmed without abandoning a pass that can still play.
/// The #293 whole-break up-front on-device route is not recut: #432 lets attributed lines use
/// the cloud voice behind consent copy v3, per cue.
private final class OverCapCountingVoice: VoiceProvider, @unchecked Sendable {
    let provider: String
    let seconds: Double
    private let lock = NSLock()
    private var texts: [String] = []
    var received: [String] { lock.withLock { texts } }
    var calls: Int { received.count }

    init(provider: String, seconds: Double) {
        self.provider = provider
        self.seconds = seconds
    }

    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("\(provider):\(text)".utf8), durationSeconds: seconds,
                             billableUnits: text.count, provider: provider, cacheKey: nil)
    }
}

final class OverCapEarlyStopTests: XCTestCase {
    private let cloudVoice = VoiceProfile(id: "cloud-voice", name: "Cloud")
    private let deviceVoice = VoiceProfile(id: "standard", name: "Standard")

    private func line(_ text: String, order: Int) -> NarrationCue {
        NarrationCue(id: UUID(), order: order, group: 1, kind: .transition, text: text,
                     estimatedSeconds: 4, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
    }

    /// Presenter-attributed public transitions, so the default `.transitionsOnly` scope may use
    /// the cloud route. `optional` and `closing` are 0-based indices into `texts`.
    private func presenterBreak(_ texts: [String], optional: [Int] = [], closing: Int? = nil) -> DJBreak {
        let cues = texts.enumerated().map { line($0.element, order: $0.offset + 1) }
        var djBreak = DJBreak(afterTrack: 0, cues: cues,
                              attributions: Dictionary(uniqueKeysWithValues: cues.map { ($0.id, SpokenAttribution.presenter) }))
        if let closing { djBreak.talkOverCueID = cues[closing].id }
        djBreak.optionalCueIDs = optional.map { cues[$0].id }
        return djBreak
    }

    private func renderer(_ cloud: OverCapCountingVoice, _ device: OverCapCountingVoice) -> VoiceRenderer {
        VoiceRenderer(
            routes: [
                VoiceRoute(providerID: "cloud", provider: cloud, voice: cloudVoice,
                           microdollarsPerThousandCharacters: 30, leavesDevice: true),
                VoiceRoute(providerID: "device", provider: device, voice: deviceVoice)
            ],
            budget: VoiceBudget(dailyCapMicrodollars: 1_000_000),
            cache: InMemoryAudioCache(),
            revocations: NarrationRevocations()
        )
    }

    /// Build 20's over-cap fallback: each cloud clip fits its cue, the break does not. Once the
    /// required clips so far are over the main cap the pass can only be discarded, so no further
    /// cue is sent. The renders before that point were billed and stay charged.
    func testOverTheBreakCapStopsRequestingOnceRequiredClipsCannotFit() async {
        let cloud = OverCapCountingVoice(provider: "cloud", seconds: 5)
        let device = OverCapCountingVoice(provider: "device", seconds: 2)
        let djBreak = presenterBreak([
            "Good evening, this is the late show.",
            "That one never gets old.",
            "Next up, a familiar one."
        ])
        let outcome = await DJBreakPreparer.render(djBreak, renderer: renderer(cloud, device),
                                                   userID: "u", stationID: "s", cap: 8)
        guard case .ready(let ready) = outcome else {
            return XCTFail("over cap on the cloud pass must fall back, not skip: \(outcome)")
        }
        XCTAssertEqual(ready.clips.map(\.audio.providerID), ["device", "device", "device"])
        XCTAssertEqual(cloud.calls, 2, "5 + 5 s is over 8 s after cue 2: cue 3 never sent")
        XCTAssertEqual(device.calls, 3, "one on-device retry of the whole break")
    }

    /// An optional line over the main cap is trimmed by `BreakCap.fitting` and must not trip the
    /// early stop, or a first pass that can still play would be thrown away and retried.
    func testAnOptionalLineOverTheMainCapIsTrimmedNotAnEarlyStop() async {
        let cloud = OverCapCountingVoice(provider: "cloud", seconds: 5)
        let device = OverCapCountingVoice(provider: "device", seconds: 2)
        let djBreak = presenterBreak([
            "Good evening, this is the late show.",
            "A little more about that one.",
            "Next up, a familiar one."
        ], optional: [1], closing: 2)
        let cap = DJBreakPreparer.BreakCap(main: 8, closingCueID: djBreak.talkOverCueID, closing: 6,
                                           optional: djBreak.optionalCueIDs)
        let outcome = await DJBreakPreparer.render(djBreak, renderer: renderer(cloud, device),
                                                   userID: "u", stationID: "s", cap: cap)
        guard case .ready(let ready) = outcome else {
            return XCTFail("optional over the main cap must trim, not retry or skip: \(outcome)")
        }
        XCTAssertEqual(ready.cues.map(\.text), [
            "Good evening, this is the late show.",
            "Next up, a familiar one."
        ])
        XCTAssertEqual(ready.trimmedCueIDs, [djBreak.cues[1].id])
        XCTAssertEqual(ready.clips.map(\.audio.providerID), ["cloud", "cloud"], "the kept first pass stays on the cloud voice")
        XCTAssertEqual(cloud.calls, 3, "the optional line still renders so fitting can trim it")
        XCTAssertEqual(device.calls, 0, "no last-route retry")
    }

    /// A break that fits keeps the cloud voice on every attributed public line. Pins that this
    /// recut did not bring back #293's whole-break up-front on-device route.
    func testABreakUnderTheCapKeepsTheCloudVoiceOnEveryCue() async {
        let cloud = OverCapCountingVoice(provider: "cloud", seconds: 2)
        let device = OverCapCountingVoice(provider: "device", seconds: 2)
        let djBreak = presenterBreak([
            "Good evening, this is the late show.",
            "That one never gets old.",
            "Next up, a familiar one."
        ])
        let outcome = await DJBreakPreparer.render(djBreak, renderer: renderer(cloud, device),
                                                   userID: "u", stationID: "s", cap: 8)
        guard case .ready(let ready) = outcome else {
            return XCTFail("a break under the cap must play: \(outcome)")
        }
        XCTAssertEqual(ready.clips.map(\.audio.providerID), ["cloud", "cloud", "cloud"])
        XCTAssertEqual(cloud.calls, 3)
        XCTAssertEqual(device.calls, 0)
    }
}
