import XCTest
@testable import AeroDJCore

/// #465 item 10 (onboarding, -Nova). Sentinel's rule for the layout pass on `LocalAreaPrompt`:
/// layout only. The copy, the consent version and the actions stay byte-identical, because
/// #509 and the v3 notice quote this copy word for word. These pins fail on any wording change.
final class LocalAreaPromptCopyTests: XCTestCase {
    func testConsentCopyAndVersionAreUnchanged() {
        XCTAssertEqual(LocalAreaConsentCopy.version, 1)
        XCTAssertEqual(LocalAreaConsentCopy.title, "Local weather and news?")
        XCTAssertEqual(LocalAreaConsentCopy.body,
                       "OnAirly can mention your local weather and headlines between songs. It uses your approximate "
                       + "location only, while the app is open. Your city or region is sent to the news source, and "
                       + "Apple Weather gets an approximate point. Your coordinates and your location itself are never "
                       + "sent to the voice service. If you turn on the cloud voice, the words of weather and news "
                       + "lines are sent to it, and a local headline can name your city or area.")
        XCTAssertEqual(LocalAreaConsentCopy.useApproximate, "Use approximate location")
        XCTAssertEqual(LocalAreaConsentCopy.enterPlace, "Enter a city or ZIP instead")
        XCTAssertEqual(LocalAreaConsentCopy.notNow, "Not now")
        XCTAssertEqual(LocalAreaConsentCopy.placeFieldPrompt, "City or ZIP")
        XCTAssertEqual(LocalAreaConsentCopy.usageDescription,
                       "OnAirly uses your approximate location, only while the app is open, to mention local weather "
                       + "and news between songs. Your location itself is never sent to the voice service.")
    }

    /// The app view's own string literals, read from the source: exactly the strings and
    /// identifiers it had on integration 1072d46c, none added, none changed, none removed.
    /// Every other piece of text it shows comes from `LocalAreaConsentCopy`, pinned above.
    func testThePromptViewHasTheSameStringLiteralsAndCopyReferences() throws {
        let source = try promptSource()
        let literals = matches(#""((?:[^"\\]|\\.)*)""#, in: source)
        XCTAssertEqual(literals, [
            "", // `place` starts empty
            "localArea.place",
            "Use letters, numbers, spaces and commas only.",
            "Save",
            "localArea.save",
            "localArea.approximate",
            "localArea.manual",
            "localArea.notNow",
        ])
        let copy = matches(#"LocalAreaConsentCopy\.(\w+)"#, in: source)
        XCTAssertEqual(copy, ["title", "body", "placeFieldPrompt", "useApproximate", "enterPlace", "notNow"])
        // The actions: each button still calls exactly what it called.
        for call in ["store.chooseApproximate()", "await location.requestWhenInUse()", "store.decline()",
                     "store.chooseManual(place)", "Button(\"Save\", action: saveTyped)",
                     "Button(LocalAreaConsentCopy.enterPlace) { typing = true }"] {
            XCTAssertTrue(source.contains(call), "missing \(call)")
        }
    }

    private func promptSource() throws -> String {
        // ios/AeroDJCore/Tests/AeroDJCoreTests/ -> ios/AeroDJ/LocalAreaPrompt.swift
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AeroDJ/LocalAreaPrompt.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("app source not next to the package: \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        // Comments may quote button names; only code lines count.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(code.startIndex..., in: code)
        return regex.matches(in: code, range: range).compactMap { match in
            Range(match.range(at: 1), in: code).map { String(code[$0]) }
        }
    }
}
