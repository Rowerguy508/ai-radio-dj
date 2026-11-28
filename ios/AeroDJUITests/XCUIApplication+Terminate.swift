import XCTest

extension XCUIApplication {
    /// How long to wait for a leftover or just-terminated process to leave.
    private static let exitWait: TimeInterval = 10

    /// Terminates only when the app is still running, then waits up to 10 s for
    /// `.notRunning` so the next `launch()` does not find a leftover process.
    /// Use this in place of `terminate()`. It does not retry: XCTest records a
    /// stuck terminate as a failure inside `terminate()` itself.
    @MainActor
    func terminateIfRunning() {
        guard state != .notRunning else { return }
        terminate()
        _ = waitUntilNotRunning()
    }

    /// If a leftover process is already on its way out (not in the foreground),
    /// waits up to 10 s for it to exit, then calls `launch()`. A live foreground
    /// leftover never exits on its own, so it gets no wait and `launch()`
    /// handles it as before. It never calls `terminate()` first, so a process
    /// that is slow to leave gets time to go before `launch()` would hit
    /// XCTest's un-retried ~60 s "Failed to terminate" path.
    /// If that wait times out, the leftover is still running: the test fails
    /// and `launch()` is not called (Refs #654).
    @MainActor
    func launchAfterLeftoverExits() {
        if state != .runningForeground {
            if !waitUntilNotRunning() {
                XCTFail("Leftover process did not exit within \(Int(Self.exitWait)) s (bundle com.aerodj.app, state \(state.rawValue)); launch skipped")
                return
            }
        }
        launch()
    }

    @MainActor
    private func waitUntilNotRunning() -> Bool {
        let deadline = Date().addingTimeInterval(Self.exitWait)
        while state != .notRunning {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }
}
