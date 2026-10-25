import XCTest
@testable import AeroDJCore

final class CostLimitedVoiceProviderTests: XCTestCase {
    private func context(_ station: String = "s1") -> RequestContext {
        RequestContext(stationID: station, isReusableGeneric: false)
    }

    func testHardBudgetStop() async throws {
        // Cap 10s; deterministic 2s per call -> 5 calls allowed, 6th blocked.
        let meter = InMemoryUsageMeter()
        let inner = MockVoiceProvider(artifactDurationSeconds: 2.0)
        let provider = CostLimitedVoiceProvider(inner: inner, meter: meter, dailyCapSeconds: 10)
        for _ in 0..<5 {
            _ = try await provider.synthesize("hi there", voice: VoiceProfile(id: "v", name: "v"), context: context())
        }
        do {
            _ = try await provider.synthesize("hi there", voice: VoiceProfile(id: "v", name: "v"), context: context())
            XCTFail("expected budget exceeded")
        } catch let VoiceError.dailyBudgetExceeded(limit, used) {
            XCTAssertEqual(limit, 10)
            XCTAssertEqual(used, 10)
        }
    }

    func testMeteringRecordsUsage() async throws {
        let meter = InMemoryUsageMeter()
        let inner = MockVoiceProvider(artifactDurationSeconds: 3.0)
        let provider = CostLimitedVoiceProvider(inner: inner, meter: meter, dailyCapSeconds: 100)
        _ = try await provider.synthesize("hello world", voice: VoiceProfile(id: "v", name: "v"), context: context())
        let summary = try await meter.currentUsage(for: "s1")
        XCTAssertEqual(summary.generatedSeconds, 3.0)
        XCTAssertEqual(summary.callsToday, 1)
    }

    func testProviderFailureBubbles() async throws {
        enum Fake: Error { case boom }
        let inner = MockVoiceProvider(failWith: Fake.boom)
        let provider = CostLimitedVoiceProvider(inner: inner, meter: InMemoryUsageMeter(), dailyCapSeconds: 100)
        do {
            _ = try await provider.synthesize("x", voice: VoiceProfile(id: "v", name: "v"), context: context())
            XCTFail("expected failure")
        } catch let VoiceError.providerFailed(msg) {
            XCTAssertFalse(msg.isEmpty)
        }
    }

    func testPerUserIsolation() async throws {
        let meter = InMemoryUsageMeter()
        let inner = MockVoiceProvider(artifactDurationSeconds: 50)
        let provider = CostLimitedVoiceProvider(inner: inner, meter: meter, dailyCapSeconds: 60)
        // User A hits cap.
        _ = try await provider.synthesize("a", voice: VoiceProfile(id: "v", name: "v"), context: context("A"))
        do {
            _ = try await provider.synthesize("a", voice: VoiceProfile(id: "v", name: "v"), context: context("A"))
            XCTFail()
        } catch is VoiceError {}
        // User B is unaffected (separate meter key).
        _ = try await provider.synthesize("b", voice: VoiceProfile(id: "v", name: "v"), context: context("B"))
    }
}