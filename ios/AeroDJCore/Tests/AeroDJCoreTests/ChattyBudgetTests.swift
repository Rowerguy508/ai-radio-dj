import XCTest
@testable import AeroDJCore

/// Chatty asks for a break after every song. On a paid route the daily VoiceBudget still
/// stops it: once the cap is reached, every later break is skipped as costCap, never rendered.
final class ChattyBudgetTests: XCTestCase {
    func testChattyOnPaidRouteStopsAtVoiceBudget() async throws {
        let cadence = StationConfiguration(commentary: .chatty).cadence()
        var writer = DJScriptWriter(cadence: cadence, seed: 3)
        let breaks = writer.plan(tracks: djTracks(12), briefing: nil, hour: 9).breaks
        XCTAssertEqual(breaks.map(\.afterTrack), Array(0..<11))

        // Paid only, no free fallback: 30 µ$ per character, cap fits a couple of breaks.
        let preparer = DJBreakPreparer(renderer: djRenderer(paid: DJFakeVoice(id: "cloud"), free: nil,
                                                            capMicrodollars: 10_000),
                                       userID: "u", stationID: "s")
        var outcomes: [DJBreakOutcome] = []
        for djBreak in breaks {
            let done = expectation(description: "break \(djBreak.afterTrack)")
            done.assertForOverFulfill = false
            let k = djBreak.afterTrack
            await preparer.observe { event in
                switch event {
                case .prepared(let t, _, _) where t == k, .skipped(let t, _) where t == k: done.fulfill()
                default: break
                }
            }
            await preparer.prepare(djBreak, deadline: .seconds(10), onDeviceOnly: false)
            await fulfillment(of: [done], timeout: 10)
            outcomes.append(await preparer.takeBreak(afterTrack: k))
        }
        let firstCap = try XCTUnwrap(outcomes.firstIndex(of: .skipped(.costCap)), "the cap must stop Chatty")
        XCTAssertGreaterThan(firstCap, 0, "the first break fits the cap")
        for outcome in outcomes[firstCap...] {
            XCTAssertEqual(outcome, .skipped(.costCap), "nothing renders after the cap is reached")
        }
    }
}
