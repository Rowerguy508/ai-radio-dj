import Foundation
import XCTest

/// Release never builds fixture playback (re-lands #99 e79738b, -Atlas): `PlaybackFixtures` and
/// every use of it compile only under `#if DEBUG`. This scans every Swift file under `ios/`
/// (app, share extension, UI tests, AeroDJCore sources and tests, since `swift test -c release`
/// builds the tests too) and fails on any code reference outside a DEBUG-only branch.
/// Runs on Linux. The binary-side check is `ios/scripts/check-release-excludes-preview-fixtures.sh`
/// (app, iOS CI) and `ios/scripts/check-release-excludes-test-station.sh` (AeroDJCore). -Fry
final class PlaybackFixturesReleaseScanTests: XCTestCase {
    /// Split so this file never matches itself.
    static let token = "Playback" + "Fixtures"

    private static var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AeroDJCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AeroDJCore
            .deletingLastPathComponent() // ios
    }

    struct Hit: Equatable { var file: String; var line: Int }

    // MARK: Scanner

    /// Line numbers of code (not comments) that name `token` outside a DEBUG-only branch.
    /// A branch is DEBUG-only when it is `#if DEBUG`, `#if DEBUG && …`, or the `#else` of
    /// `#if !DEBUG`. `#if DEBUG || …`, `#elseif` and the `#else` of `#if DEBUG` are not.
    /// Any enclosing DEBUG-only branch covers nested `#if`s inside it.
    static func unguardedLines(in source: String, token: String = token) -> [Int] {
        var stack: [Bool] = []       // per open #if: is the current branch DEBUG-only?
        var negated: [Bool] = []     // per open #if: was it `#if !DEBUG`?
        var hits: [Int] = []
        var inBlockComment = false
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let code = stripComments(raw, inBlockComment: &inBlockComment)
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#if\t") {
                let condition = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                stack.append(isDebugOnly(condition))
                negated.append(condition == "!DEBUG")
                continue
            }
            if trimmed.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1] = false; negated[negated.count - 1] = false }
                continue
            }
            if trimmed == "#else" {
                if !stack.isEmpty { stack[stack.count - 1] = negated[negated.count - 1]; negated[negated.count - 1] = false }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast(); negated.removeLast() }
                continue
            }
            if code.contains(token), !stack.contains(true) { hits.append(index + 1) }
        }
        return hits
    }

    /// `DEBUG`, or `DEBUG && …` with no `||` (an OR could be true in Release).
    static func isDebugOnly(_ condition: String) -> Bool {
        let c = condition.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        guard !c.contains("||") else { return false }
        return c.components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("DEBUG")
    }

    /// Drops `//` and `/* */` comments, keeping string literals (a `//` inside quotes is code).
    static func stripComments(_ line: String, inBlockComment: inout Bool) -> String {
        var out = ""
        var inString = false
        var chars = Array(line)[...]
        while let c = chars.first {
            if inBlockComment {
                if c == "*", chars.dropFirst().first == "/" { inBlockComment = false; chars = chars.dropFirst(2) } else { chars = chars.dropFirst() }
                continue
            }
            if inString {
                out.append(c)
                if c == "\\", let n = chars.dropFirst().first { out.append(n); chars = chars.dropFirst(2); continue }
                if c == "\"" { inString = false }
                chars = chars.dropFirst()
                continue
            }
            if c == "/", chars.dropFirst().first == "/" { break }
            if c == "/", chars.dropFirst().first == "*" { inBlockComment = true; chars = chars.dropFirst(2); continue }
            if c == "\"" { inString = true }
            out.append(c)
            chars = chars.dropFirst()
        }
        return out
    }

    static func scanRepository() throws -> (files: Int, references: [Hit], unguarded: [Hit]) {
        let root = iosRoot.standardizedFileURL
        let selfPath = URL(fileURLWithPath: #filePath).standardizedFileURL.path
        let skip: Set<String> = [".build", ".swiftpm", "DerivedData", "build"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw NSError(domain: "scan", code: 1)
        }
        var files = 0
        var references: [Hit] = []
        var unguarded: [Hit] = []
        for case let url as URL in walker {
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard url.pathExtension == "swift", url.standardizedFileURL.path != selfPath else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let rel = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            files += 1
            var block = false
            for (i, line) in source.components(separatedBy: "\n").enumerated()
            where stripComments(line, inBlockComment: &block).contains(token) {
                references.append(Hit(file: rel, line: i + 1))
            }
            unguarded += unguardedLines(in: source).map { Hit(file: rel, line: $0) }
        }
        return (files, references, unguarded)
    }

    // MARK: The repository

    func testEveryPlaybackFixturesReferenceIsInsideIfDebug() throws {
        let scan = try Self.scanRepository()
        XCTAssertEqual(scan.unguarded, [], "\(Self.token) is referenced outside #if DEBUG, so Release would build it")
        // Non-vacuous: the walk saw the app and the package, and the known users.
        XCTAssertGreaterThan(scan.files, 100)
        let users = Set(scan.references.map(\.file))
        for expected in [
            "AeroDJCore/Sources/AeroDJCore/Playback/PlaybackFixtures.swift",
            "AeroDJ/CompactPlayer.swift", "AeroDJ/PlaybackComponents.swift", "AeroDJ/PlayingScreen.swift",
            "AeroDJ/FoldedPlayer.swift", "AeroDJ/DJLavaOrb.swift", "AeroDJ/PlaybackActions.swift",
            "AeroDJ/StudioCapture.swift", "AeroDJCore/Tests/AeroDJCoreTests/PlaybackFixturesTests.swift",
        ] {
            XCTAssertTrue(users.contains(expected), "scan did not see \(expected); found \(users.sorted())")
        }
        XCTAssertGreaterThanOrEqual(scan.references.count, 40)
    }

    func testTheDeclarationItselfIsDebugOnly() throws {
        let url = Self.iosRoot.appendingPathComponent("AeroDJCore/Sources/AeroDJCore/Playback/PlaybackFixtures.swift")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        XCTAssertEqual(lines.first, "#if DEBUG")
        XCTAssertEqual(lines.last, "#endif")
        XCTAssertEqual(lines.filter { $0.hasPrefix("#if") }.count, 1)
    }

    // MARK: Scanner controls (so the repository test cannot pass vacuously)

    private let t = PlaybackFixturesReleaseScanTests.token

    func testFlagsAnUnguardedUse() {
        XCTAssertEqual(Self.unguardedLines(in: "let a = 1\nlet s = \(t).station\n"), [2])
    }

    func testAcceptsDebugGuardsAndNestedConditions() {
        let src = """
        #if DEBUG
        let s = \(t).station
          #if compiler(>=6.2)
          let p = \(t).playing
          #else
          let p = \(t).paused
          #endif
        #endif
        #if DEBUG && os(iOS)
        let x = \(t).songs
        #endif
        #if !DEBUG
        let y = 1
        #else
        let z = \(t).stopped
        #endif
        #if DEBUG // trailing comment
        let w = \(t).songs
        #endif
        """
        XCTAssertEqual(Self.unguardedLines(in: src), [])
    }

    func testFlagsReleaseReachableBranches() {
        let src = """
        #if DEBUG
        let a = 1
        #else
        let b = \(t).station
        #endif
        #if DEBUG || TESTFLIGHT
        let c = \(t).station
        #endif
        #if !DEBUG
        let d = \(t).station
        #endif
        #if DEBUG
        let e = 1
        #elseif os(iOS)
        let f = \(t).station
        #endif
        #if os(iOS)
        let g = \(t).station
        #endif
        """
        XCTAssertEqual(Self.unguardedLines(in: src), [4, 7, 10, 15, 18])
    }

    func testCommentsDoNotCountButStringsDo() {
        let src = """
        /// Uses the shared `\(t)` snapshot.
        let a = 1 // \(t)
        /* \(t)
           \(t) */
        let url = "https://example.com"; let s = \(t).station
        """
        XCTAssertEqual(Self.unguardedLines(in: src), [5])
    }
}
