import XCTest

/// Sentinel's #629 N2: a Linux source scan, not inspection, that the app-side location
/// files never log coordinates or location. Banned calls: `print`, `NSLog`, `os_log`,
/// `Logger` (and the usual cousins `debugPrint` / `dump`). Files: `CoarseLocation+App.swift`,
/// `LocalAreaPrompt.swift`, `LocalFacts+App.swift`, and every file in `Interludes/`.
final class LocalAreaLocationScanTests: XCTestCase {
    private let iosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    func testLocationFilesNeverLogCoordinatesOrLocation() throws {
        let files = try locationSources()
        XCTAssertFalse(files.isEmpty, "expected CoarseLocation+App, LocalAreaPrompt, LocalFacts+App, and Interludes")
        let banned = ["print(", "debugPrint(", "NSLog(", "os_log(", "Logger(", "dump("]
        for (name, text) in files {
            let code = Self.codeLines(text)
            for call in banned {
                XCTAssertFalse(code.contains(call), "\(name) must not call \(call)")
            }
        }
    }

    private func locationSources() throws -> [(String, String)] {
        var files: [(String, String)] = []
        for relative in ["AeroDJ/CoarseLocation+App.swift", "AeroDJ/LocalAreaPrompt.swift",
                         "AeroDJ/LocalFacts+App.swift"] {
            let url = iosRoot.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("app source not next to the package: \(url.path)")
            }
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        let interludes = iosRoot.appendingPathComponent("AeroDJCore/Sources/AeroDJCore/Interludes")
        let names = try FileManager.default.contentsOfDirectory(atPath: interludes.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(names.isEmpty, interludes.path)
        for name in names {
            let url = interludes.appendingPathComponent(name)
            files.append(("Interludes/\(name)", try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    /// Drop `//` and `///` comment lines so a mention of `Logger` in a comment is not a hit.
    private static func codeLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
