import XCTest

/// Parses each `PrivacyInfo.xcprivacy` (app, share, widgets) and asserts that
/// required-reason categories found in the matching sources are declared.
final class PrivacyManifestTests: XCTestCase {
    func testManifestsDeclareTheRequiredReasonAPIsFoundInSource() throws {
        let result = try runChecker()
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("privacy manifests OK"), result.output)
    }

    func testCheckerFailsWhenARequiredReasonIsRemoved() throws {
        let result = try runChecker(arguments: ["--self-test"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("self-test OK"), result.output)
    }

    private func runChecker(arguments: [String] = []) throws -> (status: Int32, output: String) {
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = ios.appendingPathComponent("scripts/check-privacy-manifests.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), script.path)

        let process = Process()
        process.executableURL = try Self.python3()
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting so a large report can't fill the pipe and stall the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    /// `python3` from `PATH`. The Linux swift container has no Python, so the check is
    /// skipped there; it still runs for real in macOS core tests and the CI checks job.
    /// On macOS a missing interpreter fails instead of skipping, so it can't go quiet.
    private static func python3() throws -> URL {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("python3")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        #if os(macOS)
        XCTFail("python3 not found on PATH (\(path)); the privacy manifest check must run on macOS")
        throw XCTSkip("python3 missing")
        #else
        throw XCTSkip("python3 not on PATH in this container; check-privacy-manifests.py runs in macOS core tests and the CI checks job")
        #endif
    }
}
