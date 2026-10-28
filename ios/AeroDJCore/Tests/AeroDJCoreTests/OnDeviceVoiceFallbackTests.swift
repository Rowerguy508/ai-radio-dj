import XCTest
@testable import AeroDJCore

/// The on-device fallback: best voice first, then a standard voice, through
/// `VoiceRenderer`'s ordinary route chain (`VoiceRoute.onDeviceRoutes()` in the app).
private struct ScriptedVoice: VoiceProvider {
    enum Behavior: Sendable { case ok, fails, silent, slow, long }
    let behavior: Behavior

    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        switch behavior {
        case .fails: throw URLError(.cannotDecodeContentData)
        case .silent: return VoiceArtifact(data: Data(), durationSeconds: 0, billableUnits: 0, provider: "avspeech", cacheKey: nil)
        case .slow: try await Task.sleep(for: .seconds(5))
        case .long: return VoiceArtifact(data: Data([1]), durationSeconds: 30, billableUnits: 0, provider: "avspeech", cacheKey: nil)
        case .ok: break
        }
        return VoiceArtifact(data: Data(voice.id.utf8), durationSeconds: 4, billableUnits: 0, provider: "avspeech", cacheKey: nil)
    }
}

private func route(_ voiceID: String, _ behavior: ScriptedVoice.Behavior) -> VoiceRoute {
    VoiceRoute(providerID: "avspeech", provider: ScriptedVoice(behavior: behavior), voice: VoiceProfile(id: voiceID, name: "Host"),
               timeout: .milliseconds(200), acceptsSSML: true)
}

private func cue() -> NarrationCue {
    NarrationCue(id: UUID(), order: 1, group: 1, kind: .followUp, text: "Coming up at 9 AM: Standup.", estimatedSeconds: 4,
                 maxSeconds: 12, sourceItemID: UUID(), source: .calendar, provenance: "test")
}

final class OnDeviceVoiceFallbackTests: XCTestCase {
    private func voiceUsed(_ primary: ScriptedVoice.Behavior, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let renderer = VoiceRenderer(routes: [route("premium", primary), route("standard", .ok)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let clip = try await renderer.render(cue(), userID: "u", stationID: "s").get()
        return clip.audio.voiceID
    }

    func testHealthyBestVoiceIsUsed() async throws {
        let used = try await voiceUsed(.ok)
        XCTAssertEqual(used, "premium")
    }

    func testFailedRenderFallsBackToStandardVoice() async throws {
        let used = try await voiceUsed(.fails)
        XCTAssertEqual(used, "standard")
    }

    func testSilentRenderFallsBackToStandardVoice() async throws {
        let used = try await voiceUsed(.silent)
        XCTAssertEqual(used, "standard")
    }

    func testTimedOutRenderFallsBackToStandardVoice() async throws {
        let used = try await voiceUsed(.slow)
        XCTAssertEqual(used, "standard")
    }

    func testOverCapRenderFallsBackInsteadOfSkipping() async throws {
        let used = try await voiceUsed(.long)
        XCTAssertEqual(used, "standard")
    }

    func testBothVoicesFailingStillSkipsTheBreak() async {
        let renderer = VoiceRenderer(routes: [route("premium", .fails), route("standard", .silent)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let result = await renderer.render(cue(), userID: "u", stationID: "s")
        guard case .failure(let failure) = result else { return XCTFail("no audio may come back") }
        XCTAssertEqual(failure.reason, .renderFailed)
        XCTAssertEqual(failure.attempts.count, 2)
    }
}

private final class TestClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }

final class VoiceHealthLedgerTests: XCTestCase {
    func testFailureMakesVoiceSuspectUntilHoldOffPasses() {
        let clock = TestClock()
        let ledger = VoiceHealthLedger(holdOff: 600, now: { clock.now })
        XCTAssertFalse(ledger.isSuspect("premium"))
        ledger.recordFailure("premium")
        XCTAssertTrue(ledger.isSuspect("premium"))
        XCTAssertFalse(ledger.isSuspect("standard"), "per voice.id")
        clock.now += 599
        XCTAssertTrue(ledger.isSuspect("premium"))
        clock.now += 1
        XCTAssertFalse(ledger.isSuspect("premium"), "a downloading voice gets another try later")
    }

    func testSuccessClearsSuspicion() {
        let ledger = VoiceHealthLedger()
        ledger.recordFailure("premium")
        ledger.recordSuccess("premium")
        XCTAssertFalse(ledger.isSuspect("premium"))
    }
}
