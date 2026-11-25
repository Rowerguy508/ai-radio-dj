import XCTest

extension XCUIApplication {
    /// #654 hosted-Mac Duo UI flake: right after launch the simulator's accessibility server is
    /// sometimes not reachable yet, and the first snapshot query fails with
    /// "Failed to get matching snapshots: Timed out / Error getting main window kAXError…".
    ///
    /// Launches (via `launchAfterLeftoverExits`), waits for the app to reach the foreground, then
    /// waits for its main window and `readyIdentifier` to exist before any test query runs. If the
    /// first attempt hits that accessibility error (or never gets ready), it terminates and
    /// relaunches once. Only on that first attempt is an accessibility-snapshot failure recorded as
    /// expected (non-strict, matched to that error text only); every other failure, and anything on
    /// the second attempt, fails the test as before. Nothing is skipped.
    @MainActor
    func launchUntilAccessible(readyIdentifier: String, in test: XCTestCase,
                               timeout: TimeInterval = 30) {
        launchAfterLeftoverExits()
        if probeAccessible(readyIdentifier: readyIdentifier, in: test, timeout: timeout, tolerateAXError: true) {
            return
        }
        XCTContext.runActivity(named: "Relaunch once: app was not accessible (\(readyIdentifier))") { _ in
            terminateIfRunning()
            launchAfterLeftoverExits()
            // Second attempt: no tolerance. The caller's own assertions then fail clearly if
            // the app is still not accessible.
            _ = probeAccessible(readyIdentifier: readyIdentifier, in: test, timeout: timeout, tolerateAXError: false)
        }
    }

    /// True once the app is in the foreground with its main window and `readyIdentifier` present.
    @MainActor
    private func probeAccessible(readyIdentifier: String, in test: XCTestCase,
                                 timeout: TimeInterval, tolerateAXError: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard wait(for: .runningForeground, timeout: timeout) else { return false }
        let probe: () -> Bool = {
            let window = self.windows.firstMatch
            guard window.waitForExistence(timeout: max(1, deadline.timeIntervalSinceNow)) else { return false }
            let ready = self.descendants(matching: .any)[readyIdentifier]
            return ready.waitForExistence(timeout: max(1, deadline.timeIntervalSinceNow))
        }
        guard tolerateAXError else { return probe() }

        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            let text = issue.compactDescription
            return text.contains("kAXError") || text.contains("Failed to get matching snapshots")
        }
        // An expected issue must not stop the test before the relaunch.
        let previous = test.continueAfterFailure
        test.continueAfterFailure = true
        defer { test.continueAfterFailure = previous }
        var ready = false
        XCTExpectFailure("Hosted-Mac accessibility server not ready after launch; relaunching once",
                         options: options) {
            ready = probe()
        }
        return ready
    }
}
