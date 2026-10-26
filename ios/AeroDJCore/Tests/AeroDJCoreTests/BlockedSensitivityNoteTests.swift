import XCTest
@testable import AeroDJCore

// Sentinel (#75 comment 6417152044): a note marked `aerodj-sensitivity: blocked` was imported
// and its Connections row was built from consent alone, so it could be approved. It must never
// be approvable or narratable, re-approval cannot override it, and its cached narration is purged.

/// Bookmark stand-in whose files can change between refreshes (the user edits the note).
private final class EditableFiles: SecurityScopedFileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    init(_ files: [String: String]) { self.files = files }
    func set(_ key: String, _ text: String) { lock.withLock { files[key] = text } }
    func read(bookmark: Data) async throws -> (data: Data, renewedBookmark: Data?) {
        let text = lock.withLock { files[String(decoding: bookmark, as: UTF8.self)] }
        guard let text else { throw MarkdownReadError.notFound }
        return (Data(text.utf8), nil)
    }
}

@MainActor
final class BlockedSensitivityNoteTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let blockedNote = "---\naerodj-sensitivity: blocked\n---\n# Therapy notes\nTalk about the move."
    let plainNote = "# Therapy notes\nTalk about the move."

    private func rig(_ text: String, cache: any AudioCache = InMemoryAudioCache())
        async throws -> (EditableFiles, LiveConnectionSources, ConnectionsModel, PickedNotesConnectionProvider) {
        let files = EditableFiles(["n": text])
        let sources = LiveConnectionSources(calendar: nil, files: files, store: InMemoryConnectionChoicesStore(),
                                            shareInboxAvailable: false)
        try await sources.addNotes([PickedNote(fileName: "Therapy.md", bookmark: Data("n".utf8))])
        var config = StationConfiguration.sampleMorningMix
        config.requestedIntegrations = Set(StationIntegration.allCases)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))), consent: sources)
        await station.load()
        let provider = PickedNotesConnectionProvider(sources: sources)
        let now = self.now
        let model = ConnectionsModel(station: station, sourceReader: sources, providers: [provider],
                                     purger: NarrationPurger(cache: cache, preparer: nil, revocations: NarrationRevocations(),
                                                             feed: NarrationPurgeFeed()),
                                     now: { now })
        await model.refresh()
        return (files, sources, model, provider)
    }

    /// (1) The row is not narratable, shows truthful copy, carries the real sensitivity, and
    /// offers no approve action; approving through the model does nothing.
    func testBlockedNoteRowIsNotNarratableAndCannotBeApproved() async throws {
        let (_, sources, model, _) = try await rig(blockedNote)
        let row = try XCTUnwrap(model.items(for: .obsidian).first)
        XCTAssertEqual(row.state, .unavailable(.markedPrivate))
        XCTAssertFalse(row.state.mayBeNarrated)
        XCTAssertFalse(row.mayBeNarrated(at: now))
        XCTAssertEqual(row.sensitivity, .blocked, "the real value, for downstream adapters")
        XCTAssertEqual(row.description, "Not used: marked private in Obsidian (aerodj-sensitivity: blocked).")
        XCTAssertFalse(row.actions.contains(.approve))
        XCTAssertFalse(row.actions.contains(.readAnyway))

        let result = await model.perform(.approve, on: row.id)
        XCTAssertEqual(result.failure, .notAllowed)
        XCTAssertEqual(model.items(for: .obsidian).first?.state, .unavailable(.markedPrivate))
        let consent = await sources.noteConsent(row.id)
        XCTAssertNotEqual(consent, .granted, "no consent was recorded")
        let narratable = try await ApprovedNotesContextSource(sources: sources).fetchItems()
        XCTAssertTrue(narratable.isEmpty)
    }

    /// (2) Consent recorded for the note (approved before it was marked, or written by any other
    /// path) does not override the mark: the row stays blocked and nothing reaches a briefing.
    func testReapprovalCannotOverrideTheMark() async throws {
        let (files, sources, model, provider) = try await rig(plainNote)
        let id = try XCTUnwrap(model.items(for: .obsidian).first?.id)
        _ = try await model.perform(.approve, on: id).get()
        XCTAssertEqual(model.items(for: .obsidian).first?.state, .approved)

        files.set("n", blockedNote)
        await model.refresh()
        XCTAssertEqual(model.items(for: .obsidian).first?.state, .unavailable(.markedPrivate))
        try await provider.perform(.approve, on: id)   // straight to the store, past the UI guard
        await model.refresh()
        let row = try XCTUnwrap(model.items(for: .obsidian).first)
        XCTAssertEqual(row.state, .unavailable(.markedPrivate), "stored approval does not override the mark")
        XCTAssertFalse(row.mayBeNarrated(at: now))
        let narratable = try await ApprovedNotesContextSource(sources: sources).fetchItems()
        XCTAssertTrue(narratable.isEmpty, "a blocked note never reaches a briefing")
    }

    /// (3) Narration cached while the note was approved is purged once it is marked blocked.
    func testExistingCachedNarrationIsPurgedWhenTheNoteIsMarkedBlocked() async throws {
        let cache = InMemoryAudioCache()
        let (files, _, model, _) = try await rig(plainNote, cache: cache)
        let id = try XCTUnwrap(model.items(for: .obsidian).first?.id)
        _ = try await model.perform(.approve, on: id).get()
        await cache.store(CachedAudio(data: Data([1]), seconds: 1, providerID: "device", voiceID: "v",
                                      sourceItemIDs: [id]), for: "note-clip")
        await cache.store(CachedAudio(data: Data([2]), seconds: 1, providerID: "device", voiceID: "v"), for: "generic")
        var kept = await cache.audio(for: "note-clip")
        XCTAssertNotNil(kept, "approved: its narration may stay cached")

        files.set("n", blockedNote)
        await model.refresh()
        kept = await cache.audio(for: "note-clip")
        XCTAssertNil(kept, "its cached narration is purged")
        let generic = await cache.audio(for: "generic")
        XCTAssertNotNil(generic, "generic clips stay")
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}
