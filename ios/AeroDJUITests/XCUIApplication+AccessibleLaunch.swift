import Foundation
import XCTest

/// Thread-safe flag for the expected-failure issue matcher (Swift 6: the matcher may run off the
/// main actor, so it must not capture a plain `var`).
private final class AXIssueFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var matched = false
    func set() { lock.lock(); matched = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return matched }
}

extension XCUIApplication {
    /// #654 hosted-Mac Duo UI flake: right after launch the simulator's accessibility server is
    /// sometimes not reachable yet, and the first snapshot query fails with
    /// "Failed to get matching snapshots: Timed out / Error getting main window kAXError…".
    ///
    /// Launches (via `launchAfterLeftoverExits`), waits for the app to reach the foreground, then
    /// waits for its main window and `readyIdentifier` before any test query runs.
    ///
    /// It relaunches once only when the first attempt actually hit that accessibility error while
    /// the app was still running in the foreground. On that first attempt, only issues matching
    /// that error text are recorded as expected (non-strict). Any other first-attempt failure
    /// (a plain timeout, no foreground, a crash, capture.failed) fails the test right there with no
    /// relaunch. If the second attempt is not ready, the test fails. Nothing is skipped. Every
    /// relaunch prints a `::warning::` line so repeats show up in CI.
    @MainActor
    func launchUntilAccessible(readyIdentifier: String, in test: XCTestCase,
                               timeout: TimeInterval = 30) {
        launchAfterLeftoverExits()
        switch firstProbe(readyIdentifier: readyIdentifier, in: test, timeout: timeout) {
        case .ready:
            return
        case .notReady(let reason):
            XCTFail("App not accessible on first launch (\(readyIdentifier)): \(reason); no relaunch")
            return
        case .accessibilityServerError:
            break
        }
        let note = "#654 Duo UI: kAXError/snapshot error on first launch; relaunching once (\(readyIdentifier), \(test.name))"
        print("::warning::\(note)")
        NSLog("AERODJ-AX-RELAUNCH %@", note)
        XCTContext.runActivity(named: "Relaunch once: \(note)") { _ in
            terminateIfRunning()
            launchAfterLeftoverExits()
            if !probe(readyIdentifier: readyIdentifier, timeout: timeout) {
                XCTFail("App still not accessible after one relaunch (\(readyIdentifier))")
            }
        }
    }

    private enum FirstProbeResult {
        case ready
        case accessibilityServerError
        case notReady(String)
    }

    /// First attempt: absorbs only kAX/snapshot issues, and reports whether one was seen.
    @MainActor
    private func firstProbe(readyIdentifier: String, in test: XCTestCase,
                            timeout: TimeInterval) -> FirstProbeResult {
        let flag = AXIssueFlag()
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            let text = issue.compactDescription
            let isAX = text.contains("kAXError") || text.contains("Failed to get matching snapshots")
            if isAX { flag.set() }
            return isAX
        }
        // An expected issue must not stop the test before we decide whether to relaunch.
        let previous = test.continueAfterFailure
        test.continueAfterFailure = true
        defer { test.continueAfterFailure = previous }
        var ready = false
        XCTExpectFailure("Hosted-Mac accessibility server not ready after launch", options: options) {
            ready = probe(readyIdentifier: readyIdentifier, timeout: timeout)
        }
        if ready { return .ready }
        guard flag.value else { return .notReady("timed out with no accessibility error, state \(state.rawValue)") }
        // A crashed or backgrounded app can also produce a snapshot error; that is not infrastructure.
        guard state == .runningForeground else {
            return .notReady("accessibility error but app is not running in the foreground, state \(state.rawValue)")
        }
        return .accessibilityServerError
    }

    /// True once the app is in the foreground with its main window and `readyIdentifier` present.
    @MainActor
    private func probe(readyIdentifier: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard wait(for: .runningForeground, timeout: timeout) else { return false }
        guard windows.firstMatch.waitForExistence(timeout: max(1, deadline.timeIntervalSinceNow)) else { return false }
        return descendants(matching: .any)[readyIdentifier]
            .waitForExistence(timeout: max(1, deadline.timeIntervalSinceNow))
    }
}
