import XCTest
@testable import AeroDJCore

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func item(
    summary: String = "Team standup at 9am.",
    sensitivity: Sensitivity = .low,
    consent: ConsentState = .granted,
    eventAt: Date? = nil,
    expiresAt: Date? = nil
) -> ContextItem {
    ContextItem(
        source: .calendar, createdAt: fixedNow, eventAt: eventAt, title: "Item", summary: summary,
        sensitivity: sensitivity, consent: consent, expiresAt: expiresAt, provenance: "calendar://test"
    )
}

private func words(_ count: Int) -> String {
    Array(repeating: "word", count: count).joined(separator: " ")
}

final class ContextItemTests: XCTestCase {
    func testGrantedUnblockedUnexpiredIsNarratable() {
        XCTAssertTrue(item().isNarratable(at: fixedNow))
        XCTAssertTrue(item(expiresAt: fixedNow.addingTimeInterval(1)).isNarratable(at: fixedNow))
    }

    func testConsentOtherThanGrantedIsNotNarratable() {
        for consent in [ConsentState.notRequested, .denied, .revoked] {
            XCTAssertFalse(item(consent: consent).isNarratable(at: fixedNow), "\(consent)")
        }
    }

    func testBlockedIsNotNarratableEvenWithConsent() {
        XCTAssertFalse(item(sensitivity: .blocked, consent: .granted).isNarratable(at: fixedNow))
    }

    func testExpiryBoundaryIsExclusive() {
        XCTAssertFalse(item(expiresAt: fixedNow).isNarratable(at: fixedNow))
        XCTAssertFalse(item(expiresAt: fixedNow.addingTimeInterval(-1)).isNarratable(at: fixedNow))
    }
}

final class BriefingPlannerTests: XCTestCase {
    private let planner = DefaultBriefingPlanner(now: { fixedNow })

    func testOnlyNarratableItemsIncluded() async throws {
        let granted = item()
        let denied = item(summary: "Do not read this.", sensitivity: .high, consent: .denied)
        let plan = try await planner.plan(from: [granted, denied], targetSpokenSeconds: 60)
        XCTAssertEqual(plan.segments.map(\.sourceItemID), [granted.id])
    }

    func testExpiredItemExcludedUsingInjectedClock() async throws {
        let expired = item(expiresAt: fixedNow)
        let plan = try await planner.plan(from: [expired], targetSpokenSeconds: 60)
        XCTAssertTrue(plan.segments.isEmpty)
    }

    func testSpokenBudgetFitsExactCount() async throws {
        // 30 words at 150 wpm = 12 s each; a 30 s budget fits exactly two.
        let items = (0..<10).map { _ in item(summary: words(30)) }
        let plan = try await planner.plan(from: items, targetSpokenSeconds: 30)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.estimatedTotalSpokenSeconds, 24)
    }

    func testOversizeItemIsSkippedNotTerminal() async throws {
        // Earliest item needs 32 s and cannot fit; later short items must still play.
        let long = item(summary: words(80), eventAt: fixedNow)
        let short1 = item(summary: words(5), eventAt: fixedNow.addingTimeInterval(60))
        let short2 = item(summary: words(5), eventAt: fixedNow.addingTimeInterval(120))
        let plan = try await planner.plan(from: [long, short1, short2], targetSpokenSeconds: 30)
        XCTAssertEqual(plan.segments.map(\.sourceItemID), [short1.id, short2.id])
    }

    func testSegmentsOrderedByEventTime() async throws {
        let later = item(eventAt: fixedNow.addingTimeInterval(3600))
        let earlier = item(eventAt: fixedNow.addingTimeInterval(60))
        let plan = try await planner.plan(from: [later, earlier], targetSpokenSeconds: 60)
        XCTAssertEqual(plan.segments.map(\.sourceItemID), [earlier.id, later.id])
    }

    func testWordCountTreatsNewlinesAndTabsAsSeparators() {
        XCTAssertEqual(DefaultBriefingPlanner.estimatedSpokenSeconds(for: "one\ntwo\tthree  four five"), 2)
        XCTAssertEqual(DefaultBriefingPlanner.estimatedSpokenSeconds(for: words(25)), 10)
    }

    func testNoFabricationEmptyInput() async throws {
        let plan = try await planner.plan(from: [], targetSpokenSeconds: 60)
        XCTAssertTrue(plan.segments.isEmpty)
    }
}

final class UsageMeterTests: XCTestCase {
    func testRecordsAndSummarizesPerUser() async throws {
        let meter = InMemoryUsageMeter()
        try await meter.record(UsageRecord(
            userID: "u1", provider: "cartesia", characters: 100,
            generatedSeconds: 8, estimatedBillableUnits: 10, observedCost: 0.01
        ))
        try await meter.record(UsageRecord(
            userID: "u1", provider: "cartesia", characters: 50,
            generatedSeconds: 4, estimatedBillableUnits: 5, observedCost: nil
        ))
        try await meter.record(UsageRecord(
            userID: "u2", provider: "cartesia", characters: 999,
            generatedSeconds: 60, estimatedBillableUnits: 99, observedCost: nil
        ))
        let summary = try await meter.currentUsage(for: "u1")
        XCTAssertEqual(summary.generatedSeconds, 12)
        XCTAssertEqual(summary.estimatedBillableUnits, 15)
        XCTAssertEqual(summary.callCount, 2)
    }

    func testUnknownUserHasZeroUsage() async throws {
        let summary = try await InMemoryUsageMeter().currentUsage(for: "nobody")
        XCTAssertEqual(summary.callCount, 0)
        XCTAssertEqual(summary.generatedSeconds, 0)
    }
}

final class SharedInboxItemTests: XCTestCase {
    func testWhitespaceOnlyContentIsRejected() {
        XCTAssertNil(SharedInboxItem(kind: .text, content: " \n\t ", now: fixedNow))
    }

    func testExpiryUsesRetentionAndBoundaryIsExpired() throws {
        let shared = try XCTUnwrap(SharedInboxItem(kind: .url, content: "https://example.com", now: fixedNow, retention: 60))
        XCTAssertEqual(shared.source, .userShared)
        XCTAssertFalse(shared.isExpired(at: fixedNow.addingTimeInterval(59)))
        XCTAssertTrue(shared.isExpired(at: fixedNow.addingTimeInterval(60)))
    }

    func testOversizeContentIsTruncatedAndFlagged() throws {
        let long = String(repeating: "a", count: SharedInboxItem.maxContentBytes + 10)
        let shared = try XCTUnwrap(SharedInboxItem(kind: .text, content: long, now: fixedNow))
        XCTAssertEqual(shared.content.utf8.count, SharedInboxItem.maxContentBytes)
        XCTAssertTrue(shared.isTruncated)
    }

    func testTruncationNeverSplitsMultibyteCharacters() {
        // "é" is 2 bytes in UTF-8, so 5 bytes holds two of them, not two and a half.
        XCTAssertEqual(SharedInboxItem.truncated("ééé", maxBytes: 5), "éé")
        XCTAssertEqual(SharedInboxItem.truncated("👍🏽ok", maxBytes: 4), "")
    }

    func testShortContentIsKeptWhole() throws {
        let shared = try XCTUnwrap(SharedInboxItem(kind: .text, content: "  Lunch moved to 1pm  ", now: fixedNow))
        XCTAssertEqual(shared.content, "Lunch moved to 1pm")
        XCTAssertFalse(shared.isTruncated)
    }
}
