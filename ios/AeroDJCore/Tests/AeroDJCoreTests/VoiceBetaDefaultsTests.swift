import XCTest
@testable import AeroDJCore

// P2(e): paid voice stays at $0 and cached narration never outlives 7 days. -Fry
final class VoiceBetaDefaultsTests: XCTestCase {
    func testPaidVoiceDefaultsToZeroDollarsAndRefusesAnyPaidReservation() async {
        XCTAssertEqual(VoiceBetaDefaults.paidDailyCapMicrodollars, 0)
        let budget = VoiceBudget(dailyCapMicrodollars: VoiceBetaDefaults.paidDailyCapMicrodollars)
        let one = await budget.reserve(userID: "u", microdollars: 1)
        XCTAssertNil(one, "not even one microdollar of paid voice")
    }

    func testAudioCacheRetentionIsAtMostSevenDays() async throws {
        XCTAssertEqual(AudioCacheRetention.maximum, 7 * 24 * 3600)
        XCTAssertEqual(InMemoryAudioCache().maxAge, 7 * 24 * 3600, "default is the maximum")
        XCTAssertEqual(InMemoryAudioCache(maxAge: 30 * 24 * 3600).maxAge, 7 * 24 * 3600, "longer requests are clamped")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(FileAudioCache(directory: dir).maxAge, 7 * 24 * 3600)

        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let cache = InMemoryAudioCache(maxAge: 30 * 24 * 3600, now: { clock.now })
        await cache.store(CachedAudio(data: Data("x".utf8), seconds: 1, providerID: "device", voiceID: "host"), for: "k")
        clock.now += 7 * 24 * 3600
        let atLimit = await cache.audio(for: "k")
        XCTAssertNotNil(atLimit, "kept for 7 days")
        clock.now += 1
        let past = await cache.audio(for: "k")
        XCTAssertNil(past, "gone one second after 7 days")
    }
}
