import XCTest
@testable import AeroDJCore

/// Mirror of #34's `DefaultBroadcastScheduler` at a0f879a (Claudio's file is not
/// on this branch and is not modified): one segment per boundary, `prefix`
/// drops the rest silently.
struct PrefixBroadcastScheduler34: BroadcastScheduler {
    func schedule(plan: BriefingPlan, trackCount: Int) async throws -> [InterludeSlot] {
        guard trackCount > 0, !plan.segments.isEmpty else { return [] }
        let usable = min(plan.segments.count, trackCount)
        let step = Double(trackCount) / Double(usable)
        return plan.segments.prefix(usable).enumerated().map { index, segment in
            InterludeSlot(segment: segment, afterTrackIndex: min(trackCount - 1, Int((Double(index) + 0.5) * step)))
        }
    }
}

/// Reference implementation proving the contract is satisfiable for any track
/// count: group 0 before the first track, later groups spread over boundaries
/// (merged when there are fewer boundaries), the closer after the last track.
/// A shape proposal for #34, not shipped code.
struct ReferenceGroupedScheduler: NarrationScheduling {
    func schedule(_ handoff: NarrationHandoff, trackCount: Int) async -> NarrationScheduleReport {
        let groups = handoff.groups.map { $0.first!.group }
        let later = groups.count - 1
        var spoken = 0
        return NarrationScheduleReport(entries: handoff.cues.map { cue in
            let rank = groups.firstIndex(of: cue.group)!
            let placement: NarrationPlacement = trackCount == 0 || rank == 0
                ? .beforeFirstTrack
                : .afterTrack(Int((Double(rank) * Double(trackCount) / Double(later)).rounded(.up)) - 1)
            guard spoken + cue.estimatedSeconds <= handoff.maxSpokenSeconds else {
                return NarrationScheduleEntry(cue: cue, outcome: .dropped(.overBudget))
            }
            spoken += cue.estimatedSeconds
            return NarrationScheduleEntry(cue: cue, outcome: .scheduled(placement))
        })
    }
}

private struct FailingScheduler: BroadcastScheduler {
    struct Boom: Error {}
    func schedule(plan: BriefingPlan, trackCount: Int) async throws -> [InterludeSlot] { throw Boom() }
}

private struct RewritingScheduler: BroadcastScheduler {
    func schedule(plan: BriefingPlan, trackCount: Int) async throws -> [InterludeSlot] {
        plan.segments.enumerated().map { index, s in
            InterludeSlot(segment: BriefingSegment(id: s.id, text: s.text + " Also, buy crypto.", sourceItemID: s.sourceItemID,
                                                   estimatedSpokenSeconds: s.estimatedSpokenSeconds),
                          afterTrackIndex: min(index, max(0, trackCount - 1)))
        }
    }
}

final class NarrationHandoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func script(items count: Int) -> BriefingScript {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let items = (0..<count).map { i in
            ContextItem(id: UUID(), source: .userShared, createdAt: now.addingTimeInterval(Double(-i)), title: "Item \(i)",
                        summary: "Detail number \(i).", sensitivity: .low, consent: .granted,
                        expiresAt: now.addingTimeInterval(3600), provenance: "test:\(i)")
        }
        return MorningBriefingEngine(calendar: cal, now: { [now] in now }).script(from: items)
    }

    func testHandoffIsBoundedSourcedAndGrouped() {
        let handoff = script(items: 3).handoff(maxSpokenSeconds: 150)
        XCTAssertEqual(handoff.cues.map(\.kind), [.opener, .followUp, .followUp, .followUp, .closer])
        XCTAssertEqual(handoff.cues.map(\.group), [0, 0, 1, 2, 3])
        XCTAssertEqual(handoff.cues.map(\.order), Array(0..<5))
        XCTAssertLessThanOrEqual(handoff.cues.reduce(0) { $0 + $1.estimatedSeconds }, handoff.maxSpokenSeconds)
        for cue in handoff.cues {
            XCTAssertGreaterThanOrEqual(cue.maxSeconds, cue.estimatedSeconds)
            XCTAssertLessThanOrEqual(cue.maxSeconds, handoff.maxSpokenSeconds)
            if cue.isContent { XCTAssertNotNil(cue.provenance); XCTAssertEqual(cue.source, .userShared) }
        }
        XCTAssertTrue(handoff.cues[1].accepts(renderedSeconds: Double(handoff.cues[1].maxSeconds)))
        XCTAssertFalse(handoff.cues[1].accepts(renderedSeconds: Double(handoff.cues[1].maxSeconds) + 0.5))
    }

    func testHandoffRoundTripsAsJSON() throws {
        let handoff = script(items: 2).handoff(maxSpokenSeconds: 150)
        XCTAssertEqual(try JSONDecoder().decode(NarrationHandoff.self, from: JSONEncoder().encode(handoff)), handoff)
    }

    /// Claude's #34/#49 P1, pinned: with 1-2 tracks #34 drops approved items
    /// silently. Through the adapter every cue gets an explicit outcome.
    func testAdapterMakes34sSilentDropsExplicit() async {
        let handoff = script(items: 3).handoff(maxSpokenSeconds: 150)
        for tracks in [0, 1, 2, 4] {
            let report = await BroadcastSchedulerAdapter(PrefixBroadcastScheduler34()).schedule(handoff, trackCount: tracks)
            XCTAssertEqual(report.entries.map(\.cue), handoff.cues, "every cue has exactly one outcome (\(tracks) tracks)")
            let placed = min(tracks, 5)
            XCTAssertEqual(report.entries.filter { if case .scheduled = $0.outcome { true } else { false } }.count, placed)
            for entry in report.unscheduledContent { XCTAssertEqual(entry.outcome, .deferred(.noTrackBoundary)) }
            XCTAssertEqual(report.outcome(for: handoff.cues.last!.id), .dropped(.notPlacedByScheduler))
        }
        let two = await BroadcastSchedulerAdapter(PrefixBroadcastScheduler34()).schedule(handoff, trackCount: 2)
        XCTAssertEqual(two.unscheduledContent.count, 2)
        XCTAssertTrue(NarrationContract.violations(of: two, for: handoff, trackCount: 2)
            .contains("opener must play before the first track"))
    }

    func testReferenceGroupedSchedulerSatisfiesContractForAnyTrackCount() async {
        for items in [0, 1, 3, 6] {
            let handoff = script(items: items).handoff(maxSpokenSeconds: 150)
            for tracks in [0, 1, 2, 3, 5, 8] {
                let report = await ReferenceGroupedScheduler().schedule(handoff, trackCount: tracks)
                XCTAssertEqual(NarrationContract.violations(of: report, for: handoff, trackCount: tracks), [],
                               "\(items) items, \(tracks) tracks")
                XCTAssertTrue(report.unscheduledContent.isEmpty, "\(items) items, \(tracks) tracks")
            }
        }
    }

    func testContractCatchesBadSchedules() {
        let handoff = script(items: 2).handoff(maxSpokenSeconds: 150)
        let c = handoff.cues
        let bad = NarrationScheduleReport(entries: [
            .init(cue: c[0], outcome: .scheduled(.afterTrack(0))),
            .init(cue: c[1], outcome: .scheduled(.afterTrack(1))),
            .init(cue: c[2], outcome: .scheduled(.afterTrack(0))),
            .init(cue: c[3], outcome: .scheduled(.afterTrack(5))),
        ], unexpectedSegmentIDs: [UUID()])
        let problems = NarrationContract.violations(of: bad, for: handoff, trackCount: 2)
        for expected in ["opener must play before the first track", "group 0 split across boundaries",
                         "cue 2 scheduled out of order", "cue 3 placed after nonexistent track 5",
                         "closer must play after the last track", "scheduler returned unknown segment ids"] {
            XCTAssertTrue(problems.contains(expected), expected)
        }
        let missing = NarrationScheduleReport(entries: Array(bad.entries.prefix(2)))
        XCTAssertTrue(NarrationContract.violations(of: missing, for: handoff, trackCount: 2)
            .contains("outcomes must cover every cue exactly once, in order"))
    }

    func testAdapterNeverSpeaksAlteredTextAndDefersOnFailure() async {
        let handoff = script(items: 2).handoff(maxSpokenSeconds: 150)
        let altered = await BroadcastSchedulerAdapter(RewritingScheduler()).schedule(handoff, trackCount: 8)
        XCTAssertTrue(altered.entries.allSatisfy { $0.outcome == .dropped(.alteredByScheduler) })
        XCTAssertTrue(altered.timeline.isEmpty)
        let failed = await BroadcastSchedulerAdapter(FailingScheduler()).schedule(handoff, trackCount: 3)
        XCTAssertEqual(failed.unscheduledContent.map(\.outcome), [.deferred(.schedulerFailed), .deferred(.schedulerFailed)])
    }

    func testOverBudgetIsReportedNotSilentlySpoken() async {
        let full = script(items: 3).handoff(maxSpokenSeconds: 150)
        let tight = NarrationHandoff(cues: full.cues, maxSpokenSeconds: full.cues[0].estimatedSeconds,
                                     experienceSeconds: full.experienceSeconds)
        let report = await BroadcastSchedulerAdapter(PrefixBroadcastScheduler34()).schedule(tight, trackCount: 8)
        XCTAssertEqual(report.entries.dropFirst().map(\.outcome).filter { $0 == .dropped(.overBudget) }.count, 4)
    }
}
