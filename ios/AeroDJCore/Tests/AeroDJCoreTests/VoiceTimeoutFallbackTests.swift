import XCTest
@testable import AeroDJCore

/// A paid-voice timeout must always fall back to the on-device voice. The timer used to
/// cancel the worker before resuming with `.timedOut`, so a provider that throws promptly on
/// cancellation could win the race with `CancellationError` and end as `renderFailed`.
final class VoiceTimeoutFallbackTests: XCTestCase {
    func testWithTimeoutAlwaysReportsTimedOutNotCancellation() async {
        for _ in 0..<300 {
            do {
                _ = try await VoiceRenderer.withTimeout(.milliseconds(1)) {
                    try await Task.sleep(for: .seconds(5)); return 0
                }
                XCTFail("expected a timeout")
            } catch {
                XCTAssertEqual(error as? VoiceRenderError, .timedOut)
            }
        }
    }

    func testPaidTimeoutFallsBackToDeviceVoiceEveryTime() async {
        let renderer = djRenderer(paid: DJFakeVoice(id: "cloud", delay: .seconds(5)), paidTimeout: .milliseconds(1))
        for i in 0..<100 {
            let cue = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "Up next, song \(i).",
                                   estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: .obsidian,
                                   provenance: "test:timeout")
            guard case .success(let clip) = await renderer.render(cue, userID: "u", stationID: "s") else {
                return XCTFail("iteration \(i): paid timeout must fall back, not fail")
            }
            XCTAssertEqual(clip.audio.providerID, "device")
        }
    }
}
