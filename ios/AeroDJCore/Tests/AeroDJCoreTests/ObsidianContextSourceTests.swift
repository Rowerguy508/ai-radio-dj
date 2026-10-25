import XCTest
@testable import AeroDJCore

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

/// In-memory stand-in for the security-scoped document reader.
private struct FixtureReader: MarkdownDocumentReader {
    var files: [String: Result<Data, MarkdownReadError>]
    var selectionError: MarkdownReadError?

    init(_ files: [String: String] = [:], failures: [String: MarkdownReadError] = [:],
         selectionError: MarkdownReadError? = nil) {
        var all = files.mapValues { Result<Data, MarkdownReadError>.success(Data($0.utf8)) }
        for (path, error) in failures { all[path] = .failure(error) }
        self.files = all
        self.selectionError = selectionError
    }

    func selectedPaths() async throws -> [String] {
        if let selectionError { throw selectionError }
        return Array(files.keys)
    }

    func read(relativePath: String) async throws -> Data {
        guard let result = files[relativePath] else { throw MarkdownReadError.notFound }
        return try result.get()
    }
}

private var utc: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func source(_ reader: FixtureReader, policy: ObsidianImportPolicy = .init(),
                    calendar: Calendar = utc) -> ObsidianContextSource {
    ObsidianContextSource(reader: reader, policy: policy, calendar: calendar, now: { fixedNow })
}

final class ObsidianImportPolicyTests: XCTestCase {
    private let policy = ObsidianImportPolicy()

    func testAcceptsMarkdownInsideScope() {
        XCTAssertNil(policy.rejection(forPath: "Daily/2026-10-25.md"))
        XCTAssertNil(policy.rejection(forPath: "Notes/Plan.MARKDOWN"))
    }

    func testRejectsTraversalAbsoluteAndMalformedPaths() {
        XCTAssertEqual(policy.rejection(forPath: "../outside.md"), .outsideScope)
        XCTAssertEqual(policy.rejection(forPath: "a/../../b.md"), .outsideScope)
        XCTAssertEqual(policy.rejection(forPath: "/etc/notes.md"), .outsideScope)
        XCTAssertEqual(policy.rejection(forPath: "~/notes.md"), .outsideScope)
        XCTAssertEqual(policy.rejection(forPath: ""), .invalidPath)
        XCTAssertEqual(policy.rejection(forPath: "a//b.md"), .invalidPath)
        XCTAssertEqual(policy.rejection(forPath: "./a.md"), .invalidPath)
        XCTAssertEqual(policy.rejection(forPath: "a\\b.md"), .invalidPath)
    }

    func testRejectsHiddenSystemFoldersAndOtherTypes() {
        XCTAssertEqual(policy.rejection(forPath: ".obsidian/workspace.md"), .hiddenOrSystem)
        XCTAssertEqual(policy.rejection(forPath: "Notes/.trash/old.md"), .hiddenOrSystem)
        XCTAssertEqual(policy.rejection(forPath: ".hidden.md"), .hiddenOrSystem)
        XCTAssertEqual(policy.rejection(forPath: "Attachments/photo.png"), .unsupportedType)
        XCTAssertEqual(policy.rejection(forPath: "Notes/README"), .unsupportedType)
    }

    func testDecodeRejectsOversizedBinaryAndInvalidUTF8() {
        let small = ObsidianImportPolicy(maxFileBytes: 4)
        XCTAssertEqual(small.decode(Data("12345".utf8)), .failure(.tooLarge))
        XCTAssertEqual(policy.decode(Data([0x41, 0x00, 0x42])), .failure(.binaryContent))
        XCTAssertEqual(policy.decode(Data([0xFF, 0xFE, 0xFD])), .failure(.notUTF8))
        XCTAssertEqual(policy.decode(Data("ok".utf8)), .success("ok"))
    }
}

final class ObsidianContextSourceTests: XCTestCase {
    func testMapsNoteToReviewPendingContextItemWithProvenance() async throws {
        let reader = FixtureReader(["Daily/Today plan.md": """
        ---
        due: 2026-10-26
        ---
        # Today plan
        - [ ] Call dentist
        - [x] Pay rent
        - [ ] Email [[Sam]] about **budget**
        """])
        let result = try await source(reader).importNotes()
        XCTAssertTrue(result.skipped.isEmpty)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.source, .obsidian)
        XCTAssertEqual(item.title, "Today plan")
        XCTAssertEqual(item.summary, "Open tasks: Call dentist; Email Sam about budget")
        XCTAssertEqual(item.provenance, "obsidian-file:Daily/Today%20plan.md")
        XCTAssertEqual(item.consent, .notRequested)
        XCTAssertEqual(item.sensitivity, .medium)
        XCTAssertEqual(item.createdAt, fixedNow)
        XCTAssertEqual(item.expiresAt, fixedNow.addingTimeInterval(7 * 24 * 60 * 60))
        XCTAssertEqual(item.eventAt, utc.date(from: DateComponents(year: 2026, month: 10, day: 26)))
        XCTAssertFalse(item.isNarratable(at: fixedNow), "imports need explicit user approval")
    }

    func testImportedItemsAreNeverNarratedWithoutConsent() async throws {
        let items = try await source(FixtureReader(["a.md": "Something private."])).fetchItems()
        XCTAssertEqual(items.count, 1)
        let plan = try await DefaultBriefingPlanner(now: { fixedNow }).plan(from: items, targetSpokenSeconds: 150)
        XCTAssertTrue(plan.segments.isEmpty)
    }

    func testTitleFallsBackFromFrontmatterToH1ToFileName() async throws {
        let reader = FixtureReader([
            "fm.md": "---\ntitle: From [[Front]]matter\n---\n# Heading\nText.",
            "h1.md": "## Not H1\n# Real H1\nText.",
            "Folder/File name.md": "Just text.",
        ])
        let titles = try await source(reader).importNotes().items.map(\.title)
        XCTAssertEqual(Set(titles), ["From Frontmatter", "Real H1", "File name"])
    }

    func testSummaryUsesFirstParagraphAndIsBounded() async throws {
        let long = (1...60).map { "w\($0)" }.joined(separator: " ")
        let reader = FixtureReader(["n.md": "# T\n\n\(long)\n\nSecond paragraph."])
        let items = try await source(reader).fetchItems()
        let item = try XCTUnwrap(items.first)
        XCTAssertTrue(item.summary.hasPrefix("w1 w2"))
        XCTAssertEqual(item.summary.split(separator: " ").count, ObsidianContextSource.maxSummaryWords)
        XCTAssertTrue(item.summary.hasSuffix("…"))
    }

    func testOptOutPrivateAndEmptyNotesAreSkipped() async throws {
        let reader = FixtureReader([
            "optout.md": "---\naerodj: false\n---\nText.",
            "private.md": "---\nprivate: true\n---\nText.",
            "tagged.md": "---\ntags: [journal, \"#private\"]\n---\nText.",
            "empty.md": "---\ntitle: x\n---\n```\ncode only\n```\n",
            "ok.md": "Fine.",
        ])
        let result = try await source(reader).importNotes()
        XCTAssertEqual(result.items.map(\.provenance), ["obsidian-file:ok.md"])
        XCTAssertEqual(result.skipped, [
            "optout.md": .optedOut, "private.md": .optedOut, "tagged.md": .optedOut, "empty.md": .empty,
        ])
    }

    func testDeniedStaleAndOfflineFilesAreIgnoredWhileOthersImport() async throws {
        let reader = FixtureReader(["ok.md": "Fine."], failures: [
            "denied.md": .accessDenied, "moved.md": .bookmarkStale,
            "icloud.md": .notDownloaded, "gone.md": .notFound,
        ])
        let result = try await source(reader).importNotes()
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.skipped, [
            "denied.md": .accessDenied, "moved.md": .bookmarkStale,
            "icloud.md": .notDownloaded, "gone.md": .notFound,
        ])
        XCTAssertNil(result.selectionError)
    }

    func testRevokedSelectionYieldsNoItemsAndReportsError() async throws {
        let src = source(FixtureReader(selectionError: .accessDenied))
        let result = try await src.importNotes()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.selectionError, .accessDenied)
        let fetched = try await src.fetchItems()
        XCTAssertTrue(fetched.isEmpty)
    }

    func testOutOfScopeAndBinaryFilesAreNeverRead() async throws {
        let reader = FixtureReader([
            "../escape.md": "Should not load.", ".obsidian/app.md": "config",
            "pic.png": "x", "bin.md": "a\u{0}b",
        ])
        let result = try await source(reader).importNotes()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped, [
            "../escape.md": .outsideScope, ".obsidian/app.md": .hiddenOrSystem,
            "pic.png": .unsupportedType, "bin.md": .binaryContent,
        ])
    }

    func testFileLimitIsEnforcedDeterministically() async throws {
        let reader = FixtureReader(["c.md": "C.", "a.md": "A.", "b.md": "B."])
        let result = try await source(reader, policy: .init(maxFiles: 2)).importNotes()
        XCTAssertEqual(result.items.map(\.provenance), ["obsidian-file:a.md", "obsidian-file:b.md"])
        XCTAssertEqual(result.skipped, ["c.md": .fileLimitReached])
    }

    func testIDsAreStableAcrossImportsAndDistinctPerFile() async throws {
        let reader = FixtureReader(["a.md": "A.", "b.md": "B."])
        let first = try await source(reader).fetchItems().map(\.id)
        let second = try await source(reader).fetchItems().map(\.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first).count, 2)
    }

    func testSensitivityOverrideAndInvalidDates() async throws {
        let reader = FixtureReader([
            "high.md": "---\naerodj-sensitivity: high\ndate: 2026-02-30\n---\nText.",
            "blocked.md": "---\naerodj-sensitivity: blocked\ndue: soon\n---\nText.",
        ])
        let items = try await source(reader).fetchItems()
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.provenance, $0) })
        XCTAssertEqual(byPath["obsidian-file:high.md"]?.sensitivity, .high)
        XCTAssertNil(byPath["obsidian-file:high.md"]?.eventAt, "Feb 30 is not a date")
        XCTAssertEqual(byPath["obsidian-file:blocked.md"]?.sensitivity, .blocked)
        XCTAssertNil(byPath["obsidian-file:blocked.md"]?.eventAt)
    }

    func testDueDateUsesInjectedTimeZone() async throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let reader = FixtureReader(["n.md": "---\ndue: 2026-10-26\n---\nText."])
        let items = try await source(reader, calendar: tokyo).fetchItems()
        let item = try XCTUnwrap(items.first)
        // Midnight in Tokyo is 15:00 UTC the previous day.
        XCTAssertEqual(item.eventAt, utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 15)))
    }

    func testCancellationStopsImport() async throws {
        let src = source(FixtureReader(["a.md": "A."]))
        let task = Task { () async throws -> ObsidianImportResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await src.importNotes()
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    // Regression (integrated review #45): a 2024 journal note was announced as "Overdue: 2024-01-03".
    func testDateFrontmatterIsNotADueDateAndDateFileNameIsNotATitle() async throws {
        let reader = FixtureReader([
            "journal/2024-01-03.md": "---\ndate: 2024-01-03\ncreated: 2024-01-03\n---\nCalled the bank about the mortgage.",
            "plan.md": "---\ndate: 2024-01-03\nscheduled: 2026-10-26\n---\nPlan.",
        ])
        let byPath = Dictionary(uniqueKeysWithValues: try await source(reader).importNotes().items.map { ($0.provenance, $0) })
        let journal = try XCTUnwrap(byPath["obsidian-file:journal/2024-01-03.md"])
        XCTAssertNil(journal.eventAt, "`date:` records when the note was written")
        XCTAssertEqual(journal.title, "", "date-named file falls back to the summary")
        XCTAssertEqual(journal.summary, "Called the bank about the mortgage.")
        XCTAssertEqual(byPath["obsidian-file:plan.md"]?.eventAt, utc.date(from: DateComponents(year: 2026, month: 10, day: 26)))
    }

    func testInlinePrivateTagOptsOut() async throws {
        let result = try await source(FixtureReader(["a.md": "Therapy notes #private", "b.md": "Fine."])).importNotes()
        XCTAssertEqual(result.items.map(\.provenance), ["obsidian-file:b.md"])
        XCTAssertEqual(result.skipped["a.md"], .optedOut)
    }
}
