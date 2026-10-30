import XCTest
@testable import AeroDJCore

/// Sentinel's #258 nits on SubscriptionModel.refreshStatus(), tested through ProStatusRefresher
/// (the model delegates to it): N1 expiry refresh, N3 token guard, N4 foreground refresh. -Nova
@MainActor
final class ProStatusRefresherTests: XCTestCase {
    private let monthly = ProSubscriptionConfig.monthlyProductID
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Answers each StoreKit-shaped read in order; `hold()` makes the next read wait for `release`.
    @MainActor final class Reads {
        var answers: [ProEntitlementState] = []
        var calls = 0
        var held: [(ProEntitlementState) -> Void] = []
        var holdNext = 0
        var events: [String] = []

        func read() async -> ProStatusRead {
            calls += 1
            events.append("refresh")
            let state: ProEntitlementState
            if holdNext > 0 {
                holdNext -= 1
                state = await withCheckedContinuation { c in held.append { c.resume(returning: $0) } }
            } else {
                state = answers.isEmpty ? .free : answers.removeFirst()
            }
            return ProStatusRead(state: state, status: ProSubscriptionStatus(state: state))
        }
    }

    private func make(_ clock: ExpiryTestClock) -> (ProStatusRefresher, ProEntitlementCache, ManualExpiryTimers, Reads) {
        let reads = Reads(), timers = ManualExpiryTimers()
        let cache = ProEntitlementCache(now: { clock.now })
        let tracker = ProAccessChangeTracker(notify: { reads.events.append("paidVoiceAccessChanged") },
                                             schedule: timers.scheduler, now: { clock.now })
        let refresher = ProStatusRefresher(cache: cache, tracker: tracker, now: { clock.now }, read: { await reads.read() })
        return (refresher, cache, timers, reads)
    }

    private func notifications(_ reads: Reads) -> Int { reads.events.filter { $0 == "paidVoiceAccessChanged" }.count }

    // MARK: N1

    func testTheExpiryTimerRefreshesThenNotifiesExactlyOnceAtExpiry() async {
        let clock = ExpiryTestClock(start)
        let (refresher, cache, timers, reads) = make(clock)
        let expiry = start.addingTimeInterval(3600)
        reads.answers = [.pro(productID: monthly, expiresAt: expiry), .expired(productID: monthly, expiredAt: expiry)]
        await refresher.refresh()
        XCTAssertEqual(reads.events, ["refresh", "paidVoiceAccessChanged"], "Free to Pro")
        XCTAssertEqual(timers.pending.map(\.date), [expiry], "one timer, at expiresAt")

        reads.events = []
        clock.advance(3600)
        guard let timer = timers.pending.first else { return XCTFail("expiry timer armed") }
        timer.cancelled = true
        await timer.fire()
        XCTAssertEqual(reads.events, ["refresh", "paidVoiceAccessChanged"], "refreshStatus(), then one notification")
        XCTAssertEqual(cache.snapshot(), .expired(productID: monthly, expiredAt: expiry))
        XCTAssertTrue(timers.pending.isEmpty, "a lapsed Pro arms nothing")

        await timer.fire()
        clock.advance(86_400)
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(notifications(reads), 1, "exactly once")
    }

    func testAnEarlyWakeUpNeitherRefreshesNorNotifies() async {
        let clock = ExpiryTestClock(start)
        let (refresher, _, timers, reads) = make(clock)
        let expiry = start.addingTimeInterval(3600)
        reads.answers = [.pro(productID: monthly, expiresAt: expiry)]
        await refresher.refresh()
        reads.events = []
        clock.advance(1800)
        guard let early = timers.pending.first else { return XCTFail("expiry timer armed") }
        early.cancelled = true
        await early.fire()
        XCTAssertEqual(reads.events, [])
        XCTAssertEqual(timers.pending.map(\.date), [expiry], "re-armed for the same date")
    }

    func testARenewalSeenAtExpiryStillNotifiesOnceAndReArms() async {
        let clock = ExpiryTestClock(start)
        let (refresher, cache, timers, reads) = make(clock)
        let expiry = start.addingTimeInterval(3600), renewed = expiry.addingTimeInterval(30 * 86_400)
        reads.answers = [.pro(productID: monthly, expiresAt: expiry), .pro(productID: monthly, expiresAt: renewed)]
        await refresher.refresh()
        reads.events = []
        clock.advance(3600)
        guard let timer = timers.pending.first else { return XCTFail("expiry timer armed") }
        await timer.fire()
        XCTAssertEqual(reads.events, ["refresh", "paidVoiceAccessChanged"], "the session re-checks and keeps paid voice")
        XCTAssertEqual(cache.snapshot(), .pro(productID: monthly, expiresAt: renewed))
        XCTAssertEqual(timers.pending.filter { !$0.cancelled }.map(\.date), [renewed])
    }

    // MARK: N3

    func testAnOlderOverlappingRefreshThatResolvesLastCannotWriteAStalePro() async {
        let clock = ExpiryTestClock(start)
        let (refresher, cache, _, reads) = make(clock)
        reads.holdNext = 1
        let older = Task { await refresher.refresh() }
        while reads.held.isEmpty { await Task.yield() }          // the older read is waiting on StoreKit
        reads.answers = [.revoked(productID: monthly, revokedAt: start)]
        let newer = await refresher.refresh()                    // a refund arrives and is read first
        XCTAssertTrue(newer)
        XCTAssertEqual(cache.snapshot(), .revoked(productID: monthly, revokedAt: start))

        reads.held.removeFirst()(.pro(productID: monthly, expiresAt: start.addingTimeInterval(86_400)))
        let olderWrote = await older.value
        XCTAssertFalse(olderWrote, "the older refresh is superseded")
        XCTAssertEqual(cache.snapshot(), .revoked(productID: monthly, revokedAt: start), "no stale .pro")
        XCTAssertEqual(notifications(reads), 0, "never reported Pro")
    }

    func testSequentialRefreshesAllWrite() async {
        let clock = ExpiryTestClock(start)
        let (refresher, cache, _, reads) = make(clock)
        reads.answers = [.pro(productID: monthly, expiresAt: start.addingTimeInterval(60)), .free]
        let first = await refresher.refresh()
        let second = await refresher.refresh()
        XCTAssertTrue(first && second)
        XCTAssertEqual(cache.snapshot(), .free)
        XCTAssertEqual(notifications(reads), 2)
    }

    // MARK: N4

    func testComingToTheForegroundRefreshes() async {
        let clock = ExpiryTestClock(start)
        let (refresher, cache, _, reads) = make(clock)
        reads.answers = [.pro(productID: monthly, expiresAt: start.addingTimeInterval(86_400)),
                         .revoked(productID: monthly, revokedAt: start)]
        await refresher.refresh()
        await refresher.sceneBecameActive()   // refunded while the app was in the background
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(cache.snapshot(), .revoked(productID: monthly, revokedAt: start))
        XCTAssertEqual(notifications(reads), 2, "Pro, then the refund")
    }

    func testTheAppRefreshesWhenTheSceneBecomesActive() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("ios/AeroDJ/Purchases/Subscriptions+App.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("@Environment(\\.scenePhase) private var scenePhase"))
        XCTAssertTrue(source.contains("if phase == .active { Task { await model.sceneBecameActive() } }"))
        XCTAssertTrue(source.contains("func sceneBecameActive() async { await refresher.sceneBecameActive() }"))
    }
}
