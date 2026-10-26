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
        // Straight to the provider, past the UI guard: refused, and nothing is recorded.
        for action in [ConnectionAction.approve, .readAnyway] {
            do { try await provider.perform(action, on: id); XCTFail("\(action) must refuse a blocked note") }
            catch { XCTAssertEqual(error as? ConnectionActionError, .notAllowed) }
        }
        let consent = await sources.noteConsent(id)
        XCTAssertNotEqual(consent, .granted, "no approval is recorded for a blocked note")
        await model.refresh()
        let row = try XCTUnwrap(model.items(for: .obsidian).first)
        XCTAssertEqual(row.state, .unavailable(.markedPrivate), "stored approval does not override the mark")
        XCTAssertFalse(row.mayBeNarrated(at: now))
        let narratable = try await ApprovedNotesContextSource(sources: sources).fetchItems()
        XCTAssertTrue(narratable.isEmpty, "a blocked note never reaches a briefing")
    }

    /// (4) Sentinel B1: blocking clears the stored approval, so removing the marker later leaves
    /// the note pending: it needs a fresh approval, and nothing reaches a briefing until then.
    func testUnmarkingABlockedNoteRequiresFreshApproval() async throws {
        let (files, sources, model, provider) = try await rig(plainNote)
        let id = try XCTUnwrap(model.items(for: .obsidian).first?.id)
        _ = try await model.perform(.approve, on: id).get()
        var consent = await sources.noteConsent(id)
        XCTAssertEqual(consent, .granted)

        files.set("n", blockedNote)
        await model.refresh()
        consent = await sources.noteConsent(id)
        XCTAssertNotEqual(consent, .granted, "refresh() cleared the stored approval of the blocked note")
        do { try await provider.perform(.approve, on: id); XCTFail("approve must refuse a blocked note") }
        catch { XCTAssertEqual(error as? ConnectionActionError, .notAllowed) }

        files.set("n", plainNote)
        await model.refresh()
        let row = try XCTUnwrap(model.items(for: .obsidian).first)
        XCTAssertEqual(row.id, id, "same note, same id")
        XCTAssertEqual(row.state, .pendingApproval, "unmarked: waiting for a fresh approval, not approved")
        consent = await sources.noteConsent(id)
        XCTAssertNotEqual(consent, .granted)
        var narratable = try await ApprovedNotesContextSource(sources: sources).fetchItems()
        XCTAssertTrue(narratable.isEmpty, "nothing reaches a briefing until it is approved again")

        _ = try await model.perform(.approve, on: id).get()
        XCTAssertEqual(model.items(for: .obsidian).first?.state, .approved, "a fresh approval works")
        narratable = try await ApprovedNotesContextSource(sources: sources).fetchItems()
        XCTAssertEqual(narratable.map(\.id), [id])
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

/// Through the real `StudioPresentationModel` and real picked-notes provider (no stand-in that
/// injects `.low`): sensitivity comes from each note's own `aerodj-sensitivity`, keyed by the
/// row id. The rows are adapted into engine inputs the way #75's `LiveQueueBriefing` does
/// (row consent, `sensitivityByItemID[id] ?? .blocked`). Retarget to `LiveQueueBriefing.provider`
/// once #75 is in this base.
@MainActor
final class StudioSensitivityBriefingTests: XCTestCase {
    func testPrivateNoteGivesNoContentCueAndApprovedPlainNoteDoes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = EditableFiles([
            "p": "---\naerodj-sensitivity: blocked\n---\n# Therapy notes\nTalk about the move.",
            "g": "# Groceries\n- [ ] oat milk"])
        let sources = LiveConnectionSources(calendar: nil, files: files, store: InMemoryConnectionChoicesStore(),
                                            shareInboxAvailable: false)
        try await sources.addNotes([PickedNote(fileName: "Therapy.md", bookmark: Data("p".utf8)),
                                    PickedNote(fileName: "Groceries.md", bookmark: Data("g".utf8))])
        var config = StationConfiguration.sampleMorningMix
        config.requestedIntegrations = Set(StationIntegration.allCases)
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))), consent: sources)
        await station.load()
        let connections = ConnectionsModel(station: station, sourceReader: sources,
                                           providers: [PickedNotesConnectionProvider(sources: sources)],
                                           purger: NarrationPurger(cache: InMemoryAudioCache(), preparer: nil,
                                                                   revocations: NarrationRevocations(), feed: NarrationPurgeFeed()),
                                           now: { now })
        let studio = StudioPresentationModel(station: station, recipes: StationRecipeLibrary(store: InMemoryStationRecipeStore()),
                                             connections: connections, dj: DJPresentationStore())
        await studio.connections.refresh()
        let privateRow = try XCTUnwrap(studio.connections.items.first { $0.title == "Therapy notes" })
        let plainRow = try XCTUnwrap(studio.connections.items.first { $0.title == "Groceries" })
        _ = await studio.connections.perform(.approve, on: privateRow.id)   // refused: .notAllowed
        _ = try await studio.connections.perform(.approve, on: plainRow.id).get()

        let sensitivity = studio.connections.sensitivityByItemID
        XCTAssertEqual(sensitivity[privateRow.id], .blocked, "the note's own value, keyed by row id")
        XCTAssertEqual(sensitivity[plainRow.id], .medium, "notes default to .medium, never .low")
        XCTAssertFalse(sensitivity.values.contains(.low))

        // Adapter as in #75: row consent, and a missing sensitivity is blocked.
        let context = studio.connections.items.map { row in
            ContextItem(id: row.id, source: .obsidian, createdAt: now, title: row.title, summary: "",
                        sensitivity: sensitivity[row.id] ?? .blocked,
                        consent: row.state.mayBeNarrated ? .granted : .denied,
                        expiresAt: row.expiresAt, provenance: "connection:\(row.id.uuidString)")
        }
        let cues = MorningBriefingEngine(now: { now }).script(from: context).handoff(maxSpokenSeconds: 150).cues
        XCTAssertFalse(cues.contains { $0.sourceItemID == privateRow.id }, "the private note gives no content cue")
        XCTAssertTrue(cues.contains { $0.sourceItemID == plainRow.id }, "the approved plain note does")

        // Fallback regression guard: without the table every row is blocked (fails closed), so a
        // caller that drops the table is caught by the assertion above, not silently given .low.
        let blind = context.map { ContextItem(id: $0.id, source: $0.source, createdAt: $0.createdAt, title: $0.title,
                                              summary: $0.summary, sensitivity: .blocked, consent: $0.consent,
                                              expiresAt: $0.expiresAt, provenance: $0.provenance) }
        XCTAssertFalse(MorningBriefingEngine(now: { now }).script(from: blind).handoff(maxSpokenSeconds: 150)
            .cues.contains(where: \.isContent))
    }
}
