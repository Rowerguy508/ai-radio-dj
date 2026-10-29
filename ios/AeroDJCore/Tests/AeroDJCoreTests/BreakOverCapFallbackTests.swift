import XCTest
@testable import AeroDJCore

/// Build 20 (no DJ break heard): every cue fit its own 12 s cap in a slower higher-tier voice,
/// but the whole break ran past the cadence cap and was skipped as `overBreakBudget` with no
/// retry. The preparer now re-renders the whole break once on the last (standard) route.
private struct PacedVoice: VoiceProvider {
    /// Seconds of audio per cue for this voice.
    let secondsPerCue: Double
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(voice.id.utf8), durationSeconds: secondsPerCue, billableUnits: 0, provider: "avspeech", cacheKey: nil)
    }
}

private struct FailingVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        throw URLError(.cannotDecodeContentData)
    }
}

private func route(_ voiceID: String, _ provider: any VoiceProvider) -> VoiceRoute {
    VoiceRoute(providerID: "avspeech", provider: provider, voice: VoiceProfile(id: voiceID, name: "Host"),
               timeout: .milliseconds(500), acceptsSSML: true)
}

private func renderer(_ routes: [VoiceRoute]) -> VoiceRenderer {
    VoiceRenderer(routes: routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                  revocations: NarrationRevocations())
}

/// Greeting plus transition, as every first break has.
private func twoCueBreak() -> DJBreak {
    let cues = (1...2).map { n in
        NarrationCue(id: UUID(), order: n, group: 1, kind: .transition, text: "Line \(n) for the next song.",
                     estimatedSeconds: 4, maxSeconds: 8, sourceItemID: nil, source: nil, provenance: nil)
    }
    return DJBreak(afterTrack: 0, cues: cues, attributions: [:])
}

final class BreakOverCapFallbackTests: XCTestCase {
    private func outcome(_ routes: [VoiceRoute], cap: Double = 12) async -> DJBreakOutcome {
        await DJBreakPreparer.render(twoCueBreak(), renderer: renderer(routes), userID: "u", stationID: "s", cap: cap)
    }

    func testBreakUnderCapKeepsTheBestVoice() async {
        guard case .ready(let b) = await outcome([route("premium", PacedVoice(secondsPerCue: 5)), route("standard", PacedVoice(secondsPerCue: 4))]) else {
            return XCTFail("a break under the cap must play")
        }
        XCTAssertEqual(Set(b.cues.compactMap(\.voiceID)), ["premium"])
    }

    func testBreakOverCapReRendersWholeBreakOnStandardVoice() async {
        // 2 x 7 s = 14 s in Premium (each under 12 s), 2 x 4 s = 8 s in the standard voice.
        guard case .ready(let b) = await outcome([route("premium", PacedVoice(secondsPerCue: 7)), route("standard", PacedVoice(secondsPerCue: 4))]) else {
            return XCTFail("over the cap in Premium must fall back, not skip")
        }
        XCTAssertEqual(b.cues.compactMap(\.voiceID), ["standard", "standard"], "one voice for the whole break")
        XCTAssertEqual(b.clips.map(\.audio.voiceID), ["standard", "standard"])
        XCTAssertEqual(b.measuredSeconds, 8, accuracy: 0.001)
    }

    func testStillOverCapOnStandardVoiceIsSkipped() async {
        let result = await outcome([route("premium", PacedVoice(secondsPerCue: 7)), route("standard", PacedVoice(secondsPerCue: 7))])
        XCTAssertEqual(result, .skipped(.overBreakBudget))
    }

    func testFailedReRenderReportsItsOwnReason() async {
        let result = await outcome([route("premium", PacedVoice(secondsPerCue: 7)), route("standard", FailingVoice())])
        XCTAssertEqual(result, .skipped(.renderFailed))
    }

    func testAlreadyOnStandardVoiceIsNotRenderedTwice() async {
        // Premium failed, so the first pass already used the standard voice: no second pass.
        let result = await outcome([route("premium", FailingVoice()), route("standard", PacedVoice(secondsPerCue: 7))])
        XCTAssertEqual(result, .skipped(.overBreakBudget))
    }

    func testSingleRouteOverCapIsSkipped() async {
        let result = await outcome([route("standard", PacedVoice(secondsPerCue: 7))])
        XCTAssertEqual(result, .skipped(.overBreakBudget))
    }

    func testLastRouteOnlyIsTheFinalRoute() {
        let r = renderer([route("premium", PacedVoice(secondsPerCue: 1)), route("standard", PacedVoice(secondsPerCue: 1))])
        XCTAssertEqual(r.lastRouteOnly?.routes.map(\.voice.id), ["standard"])
        XCTAssertNil(renderer([route("standard", PacedVoice(secondsPerCue: 1))]).lastRouteOnly)
    }
}

/// The app's fallback route is AVFoundation code, so Linux CI checks its source: the standard
/// route is exactly build 19's system default en-US voice, never a re-ranked standard voice.
final class StandardVoiceFallbackWiringTests: XCTestCase {
    func testStandardRouteIsExactlyTheSystemDefaultEnUSVoice() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AeroDJ/OnDeviceSpeechProvider.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "static func standardVoice() -> AVSpeechSynthesisVoice? {")).upperBound
        let end = try XCTUnwrap(text.range(of: "\n    }", range: start..<text.endIndex)).lowerBound
        let body = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(body, #"AVSpeechSynthesisVoice(language: "en-US")"#)
        XCTAssertTrue(text.contains("OnDeviceVoiceChoice.standardVoice(), standard.identifier != primary.voice.id"),
                      "onDeviceRoutes() appends the standard route")
    }
}
