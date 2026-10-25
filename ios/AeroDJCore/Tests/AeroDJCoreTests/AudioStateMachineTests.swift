import XCTest
@testable import AeroDJCore

final class AudioStateMachineTests: XCTestCase {
    func testFullCycle() {
        var sm = AudioStateMachine()
        XCTAssertEqual(sm.state, .idle)

        sm.apply(.startMusic)
        XCTAssertEqual(sm.state, .music)

        sm.apply(.trackEnded)
        XCTAssertEqual(sm.state, .transition)

        sm.apply(.interludeReady)
        XCTAssertEqual(sm.state, .voice)

        sm.apply(.interludeEnded)
        XCTAssertEqual(sm.state, .music)
    }

    func testStopReturnsToIdle() {
        var sm = AudioStateMachine(state: .voice)
        sm.apply(.stop)
        XCTAssertEqual(sm.state, .idle)
    }

    func testInvalidTransitionIgnored() {
        // voice -> startMusic is invalid; state unchanged.
        var sm = AudioStateMachine(state: .voice)
        sm.apply(.startMusic)
        XCTAssertEqual(sm.state, .voice)
    }

    func testPauseKeepsState() {
        var sm = AudioStateMachine(state: .music)
        sm.apply(.pause)
        XCTAssertEqual(sm.state, .music)
        sm.apply(.resume)
        XCTAssertEqual(sm.state, .music)
    }
}
