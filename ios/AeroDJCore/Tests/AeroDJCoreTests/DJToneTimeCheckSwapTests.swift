import Foundation
import XCTest
@testable import AeroDJCore

// `setTone` rebuilds the time-check pools too (-Fry): after #354 each tone has its own
// time-check bank, so a personality change mid-session must not keep speaking the old tone's
// time checks on the next plan.
final class DJToneTimeCheckSwapTests: XCTestCase {
    private let dense = DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1)
    private let heavy = DJBreakShapeConfig(weights: [.timeCheckIntro: 1000, .comingUpOnly: 1], timeCheckMinSpacingSeconds: 0)

    private var clock: DJPlanClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9, minute: 40))!
        return DJPlanClock(now: now, calendar: calendar, style: .twelveHour)
    }

    private func timeCheckTemplates(_ plan: DJSessionPlan) -> [[DJTimeCheckRelation: String]] {
        plan.breaks.compactMap { $0.timeCheck?.templates }
    }

    func testATimeCheckPoolFollowsTheToneChange() {
        for target in DJPersonality.allCases where target != .warm {
            let tone = EditorialTone.forPersonality(target)
            let warmBank = Set(EditorialTone.warm.allTimeCheckLines)
            let targetBank = Set(tone.allTimeCheckLines)
            for seed in UInt64(0)..<10 {
                var writer = DJScriptWriter(cadence: dense, seed: seed, tone: .warm, shapes: heavy)
                let before = timeCheckTemplates(writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock))
                XCTAssertFalse(before.isEmpty, "\(target) seed \(seed): warm plan has time checks")
                for t in before { XCTAssertTrue(Set(t.values).isSubset(of: warmBank), "warm first: \(t)") }

                writer.setTone(tone)
                let after = timeCheckTemplates(writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock))
                XCTAssertFalse(after.isEmpty, "\(target) seed \(seed): time checks after the change")
                for t in after {
                    XCTAssertTrue(Set(t.values).isSubset(of: targetBank), "\(target) seed \(seed): old tone's time check \(t)")
                    XCTAssertEqual(Set(t.keys), Set(DJTimeCheckRelation.allCases), "\(target): every relation")
                }
            }
        }
    }

    /// A `DJBreakShapeConfig.timeChecks` override still wins after a tone change.
    func testAnOverrideSurvivesTheToneChange() {
        let custom = DJTimeCheckPhrases(on: ["Custom {time}."], comingUp: ["Custom near {time}."], justAfter: ["Custom past {time}."])
        let config = DJBreakShapeConfig(weights: [.timeCheckIntro: 1000, .comingUpOnly: 1], timeCheckMinSpacingSeconds: 0,
                                        timeChecks: custom)
        var writer = DJScriptWriter(cadence: dense, seed: 1, tone: .warm, shapes: config)
        writer.setTone(.forPersonality(.upbeat))
        let after = timeCheckTemplates(writer.plan(tracks: djTracks(30), briefing: nil, hour: 9, clock: clock))
        XCTAssertFalse(after.isEmpty)
        for t in after { XCTAssertEqual(t, [.on: custom.on[0], .comingUp: custom.comingUp[0], .justAfter: custom.justAfter[0]]) }
    }
}
