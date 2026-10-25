import XCTest
@testable import AeroDJCore

/// Claude's integrated-review (#45) regressions, committed verbatim.
private struct Fixture: MarkdownDocumentReader {
    let files: [String: String]
    func selectedPaths() async throws -> [String] { Array(files.keys) }
    func read(relativePath: String) async throws -> Data { Data(files[relativePath]!.utf8) }
}

final class ObsidianRegressionTests: XCTestCase {
    func testCreationDateIsNotTreatedAsDueDate() async throws {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let source = ObsidianContextSource(
            reader: Fixture(files: ["journal/2024-01-03.md": "---\ndate: 2024-01-03\n---\nCalled the bank about the mortgage."]),
            calendar: utc, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let items = try await source.importNotes().items
        let item = try XCTUnwrap(items.first)
        XCTAssertNil(item.eventAt, "`date:` is when the note was written, not when something is due")
    }

    func testFutureCreationDateIsStillNotADueDate() async throws {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let source = ObsidianContextSource(
            reader: Fixture(files: ["plan.md": "---\ndate: 2027-03-01\n---\nOffsite plan."]),
            calendar: utc, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let items = try await source.importNotes().items
        let item = try XCTUnwrap(items.first)
        XCTAssertNil(item.eventAt)
    }

    func testDateNamedFileIsNotSpokenAsTitle() async throws {
        let source = ObsidianContextSource(
            reader: Fixture(files: ["journal/2024-01-03.md": "Called the bank about the mortgage."]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let items = try await source.importNotes().items
        let item = try XCTUnwrap(items.first)
        XCTAssertNotEqual(item.title, "2024-01-03")
    }
}
