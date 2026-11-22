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

    /// Waits up to 10 s for any leftover process to exit on its own, then calls
    /// `launch()`. It never calls `terminate()` first, so a process that is
    /// slow to leave gets time to go before `launch()` would hit XCTest's
    /// un-retried ~60 s "Failed to terminate" path. If it is still running after
    /// the wait, `launch()` behaves exactly as it did before this helper.
    @MainActor
    func launchAfterLeftoverExits() {
        _ = waitUntilNotRunning()
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
