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
            // The empty buffer is authoritative: if didFinish comes first it only starts the grace period.
            XCTAssertEqual(completion.winner, .finalBuffer, "completes on the empty buffer in either order")
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

    // Atlas #77 (medium): didFinish may beat the last data buffer. A grace period keeps trailing buffers.
    func testBuffersAfterDidFinishWithinGraceAreKept() async throws {
        let clock = ManualGraceClock()
        let completion = SpeechRenderCompletion(didFinishGrace: .milliseconds(250), schedule: clock.schedule)
        var framesKept = 0
        let started = expectation(description: "started")
        let render = Task { try await completion.wait(start: { started.fulfill() }) }
        await fulfillment(of: [started], timeout: 1)
        framesKept += completion.isFinished ? 0 : 512           // buffer 1
        XCTAssertTrue(completion.signal(.didFinish))            // arrives early
        XCTAssertFalse(completion.isFinished, "still accepting buffers during the grace period")
        XCTAssertEqual(clock.pending, [.milliseconds(250)])
        framesKept += completion.isFinished ? 0 : 256           // trailing buffer after didFinish
        clock.fireAll()                                          // grace elapses with no empty buffer
        try await render.value
        XCTAssertEqual(framesKept, 768, "trailing buffer within the grace period is kept")
        XCTAssertEqual(completion.winner, .didFinish)
        XCTAssertEqual(completion.resumeCount, 1)
        XCTAssertTrue(completion.isFinished)
    }

    func testEmptyBufferDuringGraceCompletesImmediately() async throws {
        let clock = ManualGraceClock()
        let completion = SpeechRenderCompletion(didFinishGrace: .milliseconds(250), schedule: clock.schedule)
        let render = Task { try await completion.wait(start: {
            completion.signal(.didFinish)
            completion.signal(.finalBuffer)                     // before the grace timer fires
        }) }
        try await render.value
        XCTAssertEqual(completion.winner, .finalBuffer)
        clock.fireAll()                                          // late grace timer is a no-op
        XCTAssertEqual(completion.winner, .finalBuffer)
        XCTAssertEqual(completion.resumeCount, 1)
    }

    // Interrupted during the 250 ms grace after didFinish (grace timer never fires: injectable clock).
    // Mirrors SpeechRenderJob: render into a temp file, didFinish arrives, then the render is cancelled or times out.
    private struct GraceTempFileVoice: VoiceProvider {
        let temp: SpeechTempFiles
        let completion: SpeechRenderCompletion
        let inGrace: XCTestExpectation
        let unwound: XCTestExpectation
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            defer { unwound.fulfill() }   // runs after withFile has deleted the file
            return try await temp.withFile { url in
                try Data("partial".utf8).write(to: url)
                try await completion.wait(start: {
                    XCTAssertTrue(completion.signal(.didFinish), "didFinish starts the grace period")
                    inGrace.fulfill()
                })
                return VoiceArtifact(data: Data("pcm".utf8), durationSeconds: 1.5, billableUnits: 0, provider: "avspeech", cacheKey: nil)
            }
        }
    }

    private func graceFixture(timeout: Duration) -> (VoiceRenderer, SpeechRenderCompletion, ManualGraceClock, SpeechTempFiles,
                                                     XCTestExpectation, XCTestExpectation) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grace-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let temp = SpeechTempFiles(directory: root.appendingPathComponent("aerodj-speech", isDirectory: true), legacyDirectory: root)
        let clock = ManualGraceClock()
        let completion = SpeechRenderCompletion(didFinishGrace: .milliseconds(250), schedule: clock.schedule)
        let inGrace = expectation(description: "didFinish received, grace pending")
        let unwound = expectation(description: "render unwound")
        let provider = GraceTempFileVoice(temp: temp, completion: completion, inGrace: inGrace, unwound: unwound)
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "avspeech", provider: provider, voice: voice, timeout: timeout, acceptsSSML: true)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        return (renderer, completion, clock, temp, inGrace, unwound)
    }

    private func leftovers(_ temp: SpeechTempFiles) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: temp.directory.path)) ?? []).sorted()
    }

    func testCancelDuringDidFinishGraceDeletesTempFileAndSkipsBreak() async throws {
        let (renderer, completion, clock, temp, inGrace, unwound) = graceFixture(timeout: .seconds(20))
        let breakCue = cue()
        let render = Task { await renderer.render(breakCue, userID: "u", stationID: "s") }
        await fulfillment(of: [inGrace], timeout: 1)
        XCTAssertEqual(clock.pending, [.milliseconds(250)], "inside the grace window")
        XCTAssertFalse(completion.isFinished)
        XCTAssertEqual(leftovers(temp).count, 1, "partial render is on disk while in grace")

        render.cancel()
        let result = await render.value
        guard case .failure(let failure) = result else { return XCTFail("a cancelled render must not produce a clip") }
        XCTAssertEqual(failure.attempts.map(\.result), [.cancelled], "no other speech path is tried")
        XCTAssertEqual(DJBreakPreparer.skipReason(failure), .renderFailed, "the DJ break is skipped, never spoken live")
        await fulfillment(of: [unwound], timeout: 2)
        XCTAssertEqual(leftovers(temp), [], "temp file deleted")
        XCTAssertEqual(completion.winner, .cancelled)
        XCTAssertEqual(completion.winner?.rawValue, "cancelled", "the log line reports signal=cancelled")
        XCTAssertEqual(completion.resumeCount, 1)

        clock.fireAll()   // the grace timer firing late is a no-op
        XCTAssertEqual(completion.winner, .cancelled)
        XCTAssertEqual(completion.resumeCount, 1)
    }

    func testDeadlineDuringDidFinishGraceDeletesTempFileAndSkipsBreak() async throws {
        // Production deadline is 20 s; scaled down here. The grace timer is never fired, so only the deadline ends it.
        let (renderer, completion, clock, temp, inGrace, unwound) = graceFixture(timeout: .milliseconds(50))
        let result = await renderer.render(cue(), userID: "u", stationID: "s")
        await fulfillment(of: [inGrace, unwound], timeout: 2)
        guard case .failure(let failure) = result else { return XCTFail("deadline must fail the render") }
        XCTAssertEqual(failure.attempts.map(\.result), [.timedOut], "only the on-device route; no other speech path is tried")
        XCTAssertEqual(DJBreakPreparer.skipReason(failure), .timedOut, "the DJ break is skipped, never spoken live")
        XCTAssertEqual(leftovers(temp), [], "temp file deleted")
        XCTAssertEqual(completion.winner, .cancelled, "withTimeout cancels the job, so the log line reports signal=cancelled")
        XCTAssertEqual(completion.resumeCount, 1)
        clock.fireAll()
        XCTAssertEqual(completion.resumeCount, 1)
    }
}

/// Injectable grace clock: records requested delays and fires them on demand (no real sleeps).
final class ManualGraceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [(Duration, @Sendable () -> Void)] = []
    var pending: [Duration] { lock.withLock { timers.map(\.0) } }
    var schedule: SpeechRenderCompletion.GraceScheduler {
        { [self] delay, fire in lock.withLock { timers.append((delay, fire)) } }
    }
    func fireAll() {
        let due = lock.withLock { defer { timers.removeAll() }; return timers }
        for (_, fire) in due { fire() }
    }
}
