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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
