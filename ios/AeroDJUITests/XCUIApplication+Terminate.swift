import XCTest

extension XCUIApplication {
    /// How long to wait for the process to leave after each terminate. Long enough
    /// for a clean exit, short enough that a stuck process fails in a bounded time
    /// instead of XCTest's ~60 s un-retried "Failed to terminate" path.
    private static let terminateWait: TimeInterval = 10

    /// Terminates only when the app is still running, waits for `.notRunning`,
    /// retries terminate once, and fails with a clear message only if it is still
    /// running. Use this in place of `terminate()`.
    @MainActor
    func terminateIfRunning(file: StaticString = #filePath, line: UInt = #line) {
        guard state != .notRunning else { return }
        terminate()
        if waitUntilNotRunning() { return }
        if state != .notRunning {
            terminate()
        }
        if waitUntilNotRunning() { return }
        XCTFail(
            "Failed to terminate com.aerodj.app: still \(describe(state)) after terminate and one retry",
            file: file,
            line: line
        )
    }

    /// Makes sure any leftover process is gone (with one retry) before `launch()`,
    /// so launch does not hit XCTest's un-retried "Failed to terminate" path.
    @MainActor
    func launchAfterTerminatingIfRunning(file: StaticString = #filePath, line: UInt = #line) {
        terminateIfRunning(file: file, line: line)
        guard state == .notRunning else { return }
        launch()
    }

    @MainActor
    private func waitUntilNotRunning() -> Bool {
        if state == .notRunning { return true }
        let deadline = Date().addingTimeInterval(Self.terminateWait)
        while Date() < deadline {
            if state == .notRunning { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return state == .notRunning
    }

    private func describe(_ state: State) -> String {
        switch state {
        case .notRunning: return "notRunning"
        case .runningForeground: return "runningForeground"
        case .runningBackground: return "runningBackground"
        case .runningBackgroundSuspended: return "runningBackgroundSuspended"
        case .unknown: return "unknown"
        @unknown default: return "state(\(state.rawValue))"
        }
    }
}
