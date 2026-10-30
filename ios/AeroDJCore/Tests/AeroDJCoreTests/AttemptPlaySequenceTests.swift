import XCTest
@testable import AeroDJCore

/// #143 (-Atlas): attempt A suspended in `prepareToPlay()` or `play()` must never play, pause or
/// mark attempt B's queue on the shared player. Deterministic: awaits are held open with gates.
@MainActor
final class AttemptPlaySequenceTests: XCTestCase {

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        private(set) var entered = false
        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                entered = true
                if opened {
                    lock.unlock()
                    cont.resume()
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }
        func open() {
            lock.lock()
            opened = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    /// The one shared player plus the service state the sequence may touch.
    @MainActor
    private final class Harness {
        var attempts = PlaybackAttempts()
        var log: [String] = []
        /// Attempt numbers that reached `didPlay` (the `isPlaying = true` / self-start mark).
        var marked: [Int] = []
        var mayAutoResume = true
        var userWantsPlayback = true
        var prepareGates: [Int: Gate] = [:]
        var playGates: [Int: Gate] = [:]

        func run(_ attempt: PlaybackAttemptID) async throws -> AttemptPlayOutcome {
            try await AttemptPlaySequence.run(
                attempt: attempt,
                current: { self.attempts.current },
                prepare: {
                    self.log.append("prepare#\(attempt.number)")
                    if let gate = self.prepareGates[attempt.number] { await gate.wait() }
                },
                willPlay: { self.log.append("willPlay#\(attempt.number)") },
                play: {
                    self.log.append("play#\(attempt.number)")
                    if let gate = self.playGates[attempt.number] { await gate.wait() }
                },
                didPlay: { self.marked.append(attempt.number) },
                gates: { (self.mayAutoResume, self.userWantsPlayback) },
                pause: { self.log.append("pause#\(attempt.number)") })
        }
    }

    private func waitUntil(_ gate: Gate) async {
        for _ in 0..<1_000 where !gate.entered { await Task.yield() }
        XCTAssertTrue(gate.entered)
    }

    func testCurrentAttemptPlays() async throws {
        let h = Harness()
        let a = h.attempts.beginStart()
        let outcome = try await h.run(a)
        XCTAssertEqual(outcome, .playing)
        XCTAssertEqual(h.log, ["prepare#1", "willPlay#1", "play#1"])
        XCTAssertEqual(h.marked, [1])
    }

    func testStaleAttemptResumingFromPrepareNeverPlaysTheNewerQueue() async throws {
        let h = Harness()
        let gateA = Gate()
        h.prepareGates[1] = gateA
        let a = h.attempts.beginStart()
        let taskA = Task { try await h.run(a) }
        await waitUntil(gateA)
        // B replaces the queue and starts while A is suspended in prepareToPlay().
        let b = h.attempts.beginStart()
        let outcomeB = try await h.run(b)
        XCTAssertEqual(outcomeB, .playing)
        gateA.open()
        let outcomeA = try await taskA.value
        XCTAssertEqual(outcomeA, .superseded)
        XCTAssertEqual(h.log, ["prepare#1", "prepare#2", "willPlay#2", "play#2"],
                       "A must not call play() on B's queue")
        XCTAssertEqual(h.marked, [2])
    }

    func testStaleAttemptReturningFromPlayNeverPausesOrMarksTheNewerAttempt() async throws {
        let h = Harness()
        let gateA = Gate()
        h.playGates[1] = gateA
        let a = h.attempts.beginStart()
        let taskA = Task { try await h.run(a) }
        await waitUntil(gateA)
        let b = h.attempts.beginStart()
        // B is a held start (e.g. a call began): its own sequence decides, not A's.
        let outcomeB = try await h.run(b)
        XCTAssertEqual(outcomeB, .playing)
        // A route hold lands after B started; A's late return must not act on it.
        h.mayAutoResume = false
        gateA.open()
        let outcomeA = try await taskA.value
        XCTAssertEqual(outcomeA, .superseded)
        XCTAssertFalse(h.log.contains("pause#1"), "stale A must not pause B")
        XCTAssertEqual(h.marked, [2], "stale A must not mark isPlaying / self-start for itself")
    }

    func testOverlappingPlaysOnlyTheNewestAttemptMarks() async throws {
        let h = Harness()
        let gateA = Gate()
        let gateB = Gate()
        h.playGates[1] = gateA
        h.playGates[2] = gateB
        let a = h.attempts.beginStart()
        let taskA = Task { try await h.run(a) }
        await waitUntil(gateA)
        let b = h.attempts.beginStart()
        let taskB = Task { try await h.run(b) }
        await waitUntil(gateB)
        gateA.open()
        let outcomeA = try await taskA.value
        XCTAssertEqual(outcomeA, .superseded)
        gateB.open()
        let outcomeB = try await taskB.value
        XCTAssertEqual(outcomeB, .playing)
        XCTAssertEqual(h.marked, [2])
        XCTAssertFalse(h.log.contains { $0.hasPrefix("pause") })
    }

    func testHoldDuringOwnPlayStillPausesTheCurrentAttempt() async throws {
        let h = Harness()
        let gateA = Gate()
        h.playGates[1] = gateA
        let a = h.attempts.beginStart()
        let taskA = Task { try await h.run(a) }
        await waitUntil(gateA)
        h.mayAutoResume = false
        gateA.open()
        let outcomeA = try await taskA.value
        XCTAssertEqual(outcomeA, .pausedBecauseHeld)
        XCTAssertEqual(h.log.last, "pause#1")
    }

    func testUserCancelDuringPrepareNeverCallsPlay() async throws {
        let h = Harness()
        let gateA = Gate()
        h.prepareGates[1] = gateA
        let a = h.attempts.beginStart()
        let taskA = Task { try await h.run(a) }
        await waitUntil(gateA)
        h.attempts.userCancelledCurrent()
        h.userWantsPlayback = false
        h.mayAutoResume = false
        gateA.open()
        let outcomeA = try await taskA.value
        XCTAssertEqual(outcomeA, .superseded)
        XCTAssertEqual(h.log, ["prepare#1"])
        XCTAssertEqual(h.marked, [])
    }

    func testUserCancelDuringPlayStillPausesThroughTheHoldGate() async throws {
        let h = Harness()
        let gateA = Gate()
        h.playGates[1] = gateA
        let a = h.attempts.beginStart()
        let taskA = Task { try await h.run(a) }
        await waitUntil(gateA)
        // Stop after the deadline: no attempt is current, the user does not want playback.
        h.attempts.userCancelledCurrent()
        h.userWantsPlayback = false
        h.mayAutoResume = false
        gateA.open()
        let outcomeA = try await taskA.value
        XCTAssertEqual(outcomeA, .superseded)
        XCTAssertEqual(h.log.last, "pause#1", "audio the user stopped must not keep playing")
        XCTAssertEqual(h.marked, [])
    }

    func testStalePrepareErrorStillPropagates() async {
        let h = Harness()
        let a = h.attempts.beginStart()
        struct Boom: Error {}
        do {
            _ = try await AttemptPlaySequence.run(
                attempt: a, current: { h.attempts.current },
                prepare: { throw Boom() }, willPlay: { XCTFail("no play") },
                play: { XCTFail("no play") }, didPlay: {},
                gates: { (true, true) }, pause: { XCTFail("no pause") })
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
