import XCTest
@testable import AeroDJCore

/// #565 review: the sleep timer is per rail, and a hidden Stations rail timer must never pause
/// playback while the player is pushed over it (the player's rail shows Off). These drive
/// `DuoRailSleepTimerState` the way `DuoSleepTimerButton` does: arm, wait under the task keyed
/// by `generation`, then pause only when `expire(generation:)` says so.
final class DuoRailSleepTimerTests: XCTestCase {
    /// A rail's button: its timer state, the generation its wait was armed at, and its pauses.
    private struct Rail {
        var timer = DuoRailSleepTimerState()
        var pendingWait: Int?
        var pauses = 0

        mutating func choose(_ minutes: Int?) {
            timer.arm(minutes)
            pendingWait = timer.delaySeconds == nil ? nil : timer.generation
        }

        mutating func setShown(_ shown: Bool) {
            let before = timer.generation
            timer.setShown(shown)
            // The task is keyed by generation: a change cancels the running wait.
            if timer.generation != before { pendingWait = nil }
        }

        /// The armed wait runs to the end (a cancelled wait never reaches here).
        mutating func waitElapses() {
            guard let armed = pendingWait else { return }
            pendingWait = nil
            if timer.expire(generation: armed) { pauses += 1 }
        }

        /// A wait that elapsed despite cancellation (late delivery): it must still not pause.
        mutating func staleWaitElapses(armedAt armed: Int) {
            if timer.expire(generation: armed) { pauses += 1 }
        }
    }

    func testStationsTimerArmedThenPlayerPushedNeverPauses() {
        var stations = Rail()
        stations.choose(15)
        XCTAssertEqual(stations.timer.delaySeconds, 900)
        let armed = stations.timer.generation

        // Player pushed over Stations: the Stations rail is hidden, and its timer goes Off.
        stations.setShown(false)
        XCTAssertNil(stations.timer.minutes)
        XCTAssertEqual(DuoSleepTimer.accessibilityValue(minutes: stations.timer.minutes), "Off")

        stations.waitElapses()
        stations.staleWaitElapses(armedAt: armed)
        XCTAssertEqual(stations.pauses, 0, "A hidden Stations timer must not pause playback")

        // Back on Stations: still Off, nothing pending, no pause.
        stations.setShown(true)
        stations.waitElapses()
        XCTAssertNil(stations.timer.minutes)
        XCTAssertEqual(stations.pauses, 0)
    }

    func testStationsTimerCannotBeArmedWhileHidden() {
        var stations = Rail()
        stations.setShown(false)
        stations.choose(30)
        XCTAssertNil(stations.timer.minutes)
        stations.waitElapses()
        XCTAssertEqual(stations.pauses, 0)
    }

    func testPlayerRailTimerIsUnaffectedByTheStationsTimer() {
        var stations = Rail()
        var player = Rail()

        // Stations arms 15, then the player is pushed and its own rail reads Off.
        stations.choose(15)
        stations.setShown(false)
        XCTAssertEqual(DuoSleepTimer.accessibilityValue(minutes: player.timer.minutes), "Off")
        stations.waitElapses()
        player.waitElapses()
        XCTAssertEqual(stations.pauses + player.pauses, 0)

        // The player's own timer, armed on its rail, fires once, independent of Stations.
        player.choose(30)
        XCTAssertEqual(player.timer.minutes, 30)
        XCTAssertNil(stations.timer.minutes)
        player.waitElapses()
        XCTAssertEqual(player.pauses, 1)
        XCTAssertEqual(stations.pauses, 0)
        XCTAssertNil(player.timer.minutes, "Back to Off after it fires")

        // Hiding Stations again does not touch an armed player timer.
        player.choose(45)
        stations.setShown(true)
        stations.setShown(false)
        XCTAssertEqual(player.timer.minutes, 45)
        player.waitElapses()
        XCTAssertEqual(player.pauses, 2)
        XCTAssertEqual(stations.pauses, 0)
    }

    func testVisibleStationsTimerStillPausesWhenItExpires() {
        var stations = Rail()
        stations.choose(60)
        XCTAssertEqual(stations.timer.delaySeconds, 3600)
        stations.waitElapses()
        XCTAssertEqual(stations.pauses, 1)
        XCTAssertNil(stations.timer.minutes)
        XCTAssertEqual(DuoSleepTimer.accessibilityValue(minutes: stations.timer.minutes), "Off")
    }

    func testOffAndReArmCancelTheEarlierWait() {
        var timer = DuoRailSleepTimerState()
        timer.arm(15)
        let first = timer.generation
        timer.arm(30)
        XCTAssertFalse(timer.expire(generation: first), "A re-armed timer ignores the old wait")
        let second = timer.generation
        timer.arm(nil)
        XCTAssertNil(timer.delaySeconds)
        XCTAssertFalse(timer.expire(generation: second), "Off never pauses")
    }

    func testHidingAnOffTimerKeepsItsGeneration() {
        // Hiding with nothing armed cancels nothing, so the task is not restarted needlessly.
        var timer = DuoRailSleepTimerState()
        let before = timer.generation
        timer.setShown(false)
        XCTAssertEqual(timer.generation, before)
        XCTAssertFalse(timer.isShown)
        timer.setShown(true)
        XCTAssertTrue(timer.isShown)
    }
}
