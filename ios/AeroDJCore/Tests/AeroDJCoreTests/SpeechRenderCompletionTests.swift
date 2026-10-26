import XCTest
@testable import AeroDJCore

/// Mirrors `SpeechRenderJob` (iOS): the synthesizer is started inside `wait(start:)`
/// and reports `signals` in order. No signals = iOS never reports completion.
private struct ScriptedOnDeviceVoice: VoiceProvider {
    let completion: SpeechRenderCompletion
    let signals: [SpeechRenderCompletion.Signal]

    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        try await completion.wait(start: {
            for signal in signals { completion.signal(signal) }
        })
        return VoiceArtifact(data: Data("pcm".utf8), durationSeconds: 1.5, billableUnits: 0, provider: "avspeech", cacheKey: nil)
    }
}

final class SpeechRenderCompletionTests: XCTestCase {
    private let voice = VoiceProfile(id: "host", name: "Host")

    private func onDeviceOnly(_ provider: ScriptedOnDeviceVoice, timeout: Duration) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "avspeech", provider: provider, voice: voice, timeout: timeout, acceptsSSML: true)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
    }

    private func cue() -> NarrationCue {
        NarrationCue(id: UUID(), order: 1, group: 1, kind: .transition, text: "That was Song 1.", estimatedSeconds: 2, maxSeconds: 12,
                     sourceItemID: nil, source: nil, provenance: nil)
    }

    // (1) iOS reports didFinish but never sends the empty final buffer.
    func testDidFinishWithoutFinalBufferCompletesPromptly() async throws {
        let completion = SpeechRenderCompletion()
        let renderer = onDeviceOnly(ScriptedOnDeviceVoice(completion: completion, signals: [.didFinish]), timeout: .seconds(20))
        let started = ContinuousClock.now
        let clip = try await renderer.render(cue(), userID: "u", stationID: "s").get()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "does not wait out the 20 s deadline")
        XCTAssertEqual(clip.attempts.map(\.result), [.rendered])
        XCTAssertEqual(completion.winner, .didFinish)
        XCTAssertEqual(completion.resumeCount, 1)
    }

    // (2) Both signals arrive: the render resumes exactly once.
    func testFinalBufferThenDidFinishCompletesExactlyOnce() async throws {
        for order in [[SpeechRenderCompletion.Signal.finalBuffer, .didFinish], [.didFinish, .finalBuffer]] {
            let completion = SpeechRenderCompletion()
            let renderer = onDeviceOnly(ScriptedOnDeviceVoice(completion: completion, signals: order), timeout: .seconds(20))
            let clip = try await renderer.render(cue(), userID: "u", stationID: "s").get()
            XCTAssertEqual(clip.attempts.map(\.result), [.rendered])
            XCTAssertEqual(completion.winner, order[0], "the first signal wins")
            XCTAssertEqual(completion.resumeCount, 1, "resumed once for \(order)")
            XCTAssertFalse(completion.signal(.didFinish), "later signals are ignored")
            XCTAssertFalse(completion.signal(.failed, error: URLError(.unknown)))
            XCTAssertEqual(completion.resumeCount, 1)
        }
    }

    // (3) Neither signal arrives: the deadline fails the render and the DJ break is skipped.
    func testNoSignalHitsDeadlineAndSkipsWithoutLiveSpeech() async throws {
        let completion = SpeechRenderCompletion()
        // Production backstop is 20 s; scaled down here. The test itself never sleeps.
        let renderer = onDeviceOnly(ScriptedOnDeviceVoice(completion: completion, signals: []), timeout: .milliseconds(50))
        let result = await renderer.render(cue(), userID: "u", stationID: "s")
        guard case .failure(let failure) = result else { return XCTFail("a render with no completion signal must fail") }
        XCTAssertEqual(failure.attempts.map(\.result), [.timedOut], "only the on-device route; no other speech path is tried")
        XCTAssertEqual(DJBreakPreparer.skipReason(failure), .timedOut, "the DJ break is skipped, never spoken live")
    }

    func testCancellationResumesOnceAndLaterSignalsAreIgnored() async {
        let completion = SpeechRenderCompletion()
        let started = expectation(description: "synthesizer started")
        let task = Task { try await completion.wait(start: { started.fulfill() }) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(completion.signal(.didFinish))
        XCTAssertEqual(completion.winner, .cancelled)
        XCTAssertEqual(completion.resumeCount, 1)
    }

    func testSignalBeforeWaitIsDeliveredWithoutStarting() async throws {
        let completion = SpeechRenderCompletion()
        completion.signal(.cancelled, error: CancellationError())
        var startedSynthesizer = false
        do {
            try await completion.wait(start: { startedSynthesizer = true })
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(startedSynthesizer)
        XCTAssertEqual(completion.resumeCount, 1)
    }
}
