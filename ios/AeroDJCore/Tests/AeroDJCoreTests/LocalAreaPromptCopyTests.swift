import XCTest
@testable import AeroDJCore

/// #465 item 10 (onboarding, -Nova). Sentinel's rule for the layout pass on `LocalAreaPrompt`
/// still applies to layout and actions. The pins below lock the per-build v2 copy, which is
/// owner-reviewed wording, not the #509 / v3-notice text. These pins fail on any wording change.
final class LocalAreaPromptCopyTests: XCTestCase {
    /// #625 (-Echo): copy v2 discloses Apple geocoding and says only what each build does
    /// (`LocalAreaConsentCopyBuildTests`). These pins are the owner-reviewed wording.
    func testConsentCopyAndVersionAreUnchanged() {
        XCTAssertEqual(LocalAreaConsentCopy.version, 2)
        // #625 (Orion): "and news" only in the build with a news provider.
        XCTAssertEqual(LocalAreaConsentCopy.title(for: .appStore), "Local weather?")
        XCTAssertEqual(LocalAreaConsentCopy.title(for: .ownerAB), "Local weather?")
        XCTAssertEqual(LocalAreaConsentCopy.title(for: .tester), "Local weather and news?")
        XCTAssertEqual(LocalAreaConsentCopy.body(for: .appStore),
                       "OnAirly can mention your local weather between songs. It uses your approximate "
                       + "location only, while the app is open. To find your city or region, Apple's geocoding "
                       + "service gets your approximate location, rounded, or the city or ZIP you type. "
                       + "Apple Weather gets an approximate point.")
        XCTAssertEqual(LocalAreaConsentCopy.body(for: .ownerAB),
                       "OnAirly can mention your local weather between songs. It uses your approximate "
                       + "location only, while the app is open. To find your city or region, Apple's geocoding "
                       + "service gets your approximate location, rounded, or the city or ZIP you type. "
                       + "Apple Weather gets an approximate point. Your coordinates and your location itself "
                       + "are never sent to the voice service. If you turn on the cloud voice, the words of "
                       + "weather lines are sent to it.")
        XCTAssertEqual(LocalAreaConsentCopy.body(for: .tester),
                       "OnAirly can mention your local weather and headlines between songs. It uses your approximate "
                       + "location only, while the app is open. To find your city or region, Apple's geocoding "
                       + "service gets your approximate location, rounded, or the city or ZIP you type. "
                       + "Your city or region is sent to the news source, and Apple Weather gets an approximate "
                       + "point. Your coordinates and your location itself are never sent to the voice service. "
                       + "If you turn on the cloud voice, the words of weather and news lines are sent to it, "
                       + "and a local headline can name your city or area.")
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

    /// The body sits in a `ScrollView` so it can scroll at accessibility text sizes in the
    /// sheet's `.medium` detent; the actions stay outside so they stay reachable.
    func testThePromptBodyScrollsAndKeepsTheButtonsReachable() throws {
        let source = try promptSource()
        XCTAssertTrue(source.contains("ScrollView"), "the body must scroll in the medium detent")
        let block = try XCTUnwrap(scrollViewBlock(in: source), "ScrollView must have a body")
        XCTAssertTrue(block.contains("Text(LocalAreaConsentCopy.body)"), "the consent body is what scrolls")
        for token in ["localArea.approximate", "localArea.manual", "localArea.save", "localArea.notNow",
                      "LocalAreaConsentCopy.useApproximate", "LocalAreaConsentCopy.enterPlace",
                      "LocalAreaConsentCopy.notNow", "Button(\"Save\""] {
            XCTAssertTrue(source.contains(token), "missing \(token)")
            XCTAssertFalse(block.contains(token), "\(token) must stay outside the ScrollView so it stays reachable")
        }
    }

    /// The first `{`...`}` after `ScrollView`, so a source scan can see what is inside it.
    private func scrollViewBlock(in source: String) -> String? {
        guard let keyword = source.range(of: "ScrollView") else { return nil }
        guard let open = source[keyword.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 }
            else if source[i] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...i]) }
            }
            source.formIndex(after: &i)
        }
        return nil
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
