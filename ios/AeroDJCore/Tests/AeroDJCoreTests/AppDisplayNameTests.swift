import XCTest
@testable import AeroDJCore

/// OnAirly is the display name. The bundle ID, targets, module, scheme and paths keep AeroDJ.
/// User-visible copy names the app only through `AppName.display`.
final class AppDisplayNameTests: XCTestCase {
    private var iosDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDisplayNameIsOnAirly() {
        XCTAssertEqual(AppName.display, "OnAirly")
    }

    /// Station IDs name the app as OnAirly, and the brand stays fixed phrasing (`.presenter`).
    func testBuiltInStationNameIsTheDisplayName() {
        XCTAssertEqual(DJScriptWriter.builtInStationName, AppName.display)
        XCTAssertEqual(DJScriptWriter().stationName, "OnAirly")
    }

    func testCoreCopyUsesTheConstant() {
        XCTAssertEqual(NowPlayingContent.needsAuthorization.detail,
                       "OnAirly needs permission before it can play from Apple Music.")
        XCTAssertTrue(SharedImportsState().description.hasSuffix("send something to OnAirly."))
        XCTAssertFalse(SharedImportsState().description.contains("AeroDJ"))
    }

    /// No string literal in the app, share extension or core copy names AeroDJ as a word.
    /// Allowed: identifiers such as "AeroDJ.cache…" keys and lines marked `// not user-visible:`
    /// (hash seeds). DJ/ (spoken scripts) is scanned too: on-air station IDs say OnAirly.
    func testNoUserVisibleAeroDJLiterals() throws {
        let roots = ["AeroDJ", "AeroDJShare", "AeroDJCore/Sources/AeroDJCore"].map { iosDir.appendingPathComponent($0) }
        let literal = try NSRegularExpression(pattern: #""[^"\n]*\bAeroDJ\b(?![.\-])[^"\n]*""#)
        var offenders: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                XCTFail("missing \(root.path)"); continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                for (n, line) in source.components(separatedBy: "\n").enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && !line.contains("// not user-visible:") {
                    let range = NSRange(line.startIndex..., in: line)
                    if literal.firstMatch(in: line, range: range) != nil {
                        offenders.append("\(url.lastPathComponent):\(n + 1)")
                    }
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testPlistsShowOnAirlyAndKeepTheBundleID() throws {
        let project = try String(contentsOf: iosDir.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("INFOPLIST_KEY_CFBundleDisplayName: OnAirly"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.aerodj.app\n"))
        for line in project.components(separatedBy: "\n") where line.contains("UsageDescription:") {
            XCTAssertFalse(line.contains("AeroDJ"), line)
            XCTAssertTrue(line.contains("OnAirly"), line)
        }
        let share = try Data(contentsOf: iosDir.appendingPathComponent("AeroDJShare/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: share, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "OnAirly")
    }
}
