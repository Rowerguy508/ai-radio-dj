import XCTest
@testable import AeroDJCore

/// #318: lines that aired in one session are not the first lines of the next. Template ids only.
final class SpokenLineMemoryTests: XCTestCase {
    private let cadence = DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1)
    private let tracks = djTracks(12)

    private func writer(seed: UInt64, memory: any SpokenLineMemoryStoring) -> DJScriptWriter {
        DJScriptWriter(cadence: cadence, seed: seed, shapes: .natural, lineMemory: memory)
    }

    private func texts(_ plan: DJSessionPlan) -> [[String]] { plan.breaks.map { $0.cues.map(\.text) } }

    private func greetingTemplate(in cue: String) -> String? {
        EditorialTone.warm.greetings[.afternoon]?.filter { cue.hasPrefix($0) }.max(by: { $0.count < $1.count })
    }

    private func closingTemplate(_ djBreak: DJBreak) -> String? {
        guard tracks.indices.contains(djBreak.afterTrack + 1), let text = djBreak.cues.last?.text else { return nil }
        let next = tracks[djBreak.afterTrack + 1]
        let values = ["nextTitle": next.title, "nextArtist": next.artist]
        return EditorialTone.warm.closing.first { TemplatePool.fill($0, values) == text }
    }

    func testSameSeedDoesNotRepeatTheOpenerGreetingOrClosingInTheNextSession() {
        let memory = InMemorySpokenLineMemoryStore()
        var first = writer(seed: 42, memory: memory)
        let plan1 = first.plan(tracks: tracks, briefing: nil, hour: 14)
        XCTAssertEqual(plan1.breaks.first?.shape, .showOpener)
        XCTAssertGreaterThanOrEqual(plan1.breaks.count, 3)
        var control = writer(seed: 42, memory: InMemorySpokenLineMemoryStore())
        XCTAssertEqual(texts(control.plan(tracks: tracks, briefing: nil, hour: 14)), texts(plan1),
                       "an empty store leaves the draw where it was")

        let opener = plan1.breaks[0]
        let greeting = greetingTemplate(in: opener.cues[0].text)
        let closing = closingTemplate(opener)
        XCTAssertNotNil(greeting)
        XCTAssertNotNil(closing)
        for djBreak in plan1.breaks { first.commitAiredBreak(djBreak.cues[0].id) }

        let stored = memory.load()
        XCTAssertEqual(stored.pools[SpokenLinePool.greeting(.afternoon)]?.used, [SpokenTemplateID.of(greeting!)])
        XCTAssertTrue(stored.pools[SpokenLinePool.closing]?.used.contains(SpokenTemplateID.of(closing!)) == true)
        XCTAssertLessThanOrEqual(stored.recent.count, SpokenLineMemory.maxRecentBreaks)

        var second = writer(seed: 42, memory: memory)
        let plan2 = second.plan(tracks: tracks, briefing: nil, hour: 14)
        let early = plan2.breaks.prefix(3)
        XCTAssertGreaterThanOrEqual(early.count, 1)
        XCTAssertFalse(early[0].cues[0].text.hasPrefix(greeting!), "session 2 must not open on session 1's greeting")
        XCTAssertNotEqual(closingTemplate(early[0]), closing, "session 2's first closing is not session 1's")
        for djBreak in early {
            XCTAssertNotEqual(closingTemplate(djBreak), closing, "session 1's sign-off stays out of the early breaks")
            XCTAssertFalse(djBreak.cues.contains { $0.text.hasPrefix(greeting!) })
        }
    }

    func testAReplannedBreakIsNotRecorded() {
        let memory = InMemorySpokenLineMemoryStore()
        var writer = writer(seed: 3, memory: memory)
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 14)
        let opener = plan.breaks[0]
        let later = plan.breaks[1]
        writer.forgetPlannedBreaks([opener])
        writer.commitAiredBreak(opener.cues[0].id)
        XCTAssertTrue(memory.load().pools.isEmpty, "a forgotten opener never aired")
        XCTAssertTrue(memory.load().recent.isEmpty)
        writer.commitAiredBreak(later.cues[0].id)
        let greeting = greetingTemplate(in: opener.cues[0].text)!
        let greetingID = SpokenTemplateID.of(greeting)
        XCTAssertFalse(memory.load().pools[SpokenLinePool.greeting(.afternoon)]?.used.contains(greetingID) ?? false)
        XCTAssertFalse(memory.load().recent.flatMap { $0 }.contains(greetingID))
        XCTAssertFalse(memory.load().recent.isEmpty, "the break that was kept is recorded")
    }

    func testOnlyFinishedLinesAreRecordedWhenThePlayerReportsLines() {
        let memory = InMemorySpokenLineMemoryStore()
        var writer = writer(seed: 9, memory: memory)
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 14)
        let opener = plan.breaks[0]
        writer.markLineReporting(break: opener.cues[0].id)
        writer.finishAiredBreak(opener.cues[0].id, wholeIfUnreported: true)
        XCTAssertTrue(memory.load().recent.isEmpty, "reporting lines, and none finished: nothing aired")

        // Cue ids are minted per plan, so the second session has its own.
        var again = self.writer(seed: 9, memory: memory)
        let replay = again.plan(tracks: tracks, briefing: nil, hour: 14)
        let replayed = replay.breaks[0]
        again.markLineReporting(break: replayed.cues[0].id)
        again.noteCueFinished(replayed.cues[0].id, replayed.cues[0].id)
        again.finishAiredBreak(replayed.cues[0].id, wholeIfUnreported: true)
        let greeting = greetingTemplate(in: replayed.cues[0].text)!
        XCTAssertEqual(memory.load().pools[SpokenLinePool.greeting(.afternoon)]?.used, [SpokenTemplateID.of(greeting)])
        XCTAssertFalse(memory.load().pools[SpokenLinePool.closing]?.used.contains(SpokenTemplateID.of(closingTemplate(replayed)!)) ?? false,
                       "the closing cue never finished")
    }

    func testFileRoundTripKeepsIdsOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("line-memory-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("recent-templates.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let memory = FileSpokenLineMemoryStore(fileURL: url)
        var writer = writer(seed: 4, memory: memory)
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 14)
        for djBreak in plan.breaks { writer.commitAiredBreak(djBreak.cues[0].id) }

        let raw = try Data(contentsOf: url)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("Song"))
        XCTAssertFalse(text.contains("Artist"))
        XCTAssertFalse(text.contains("OnAirly"))
        XCTAssertFalse(text.contains("Good afternoon"))
        XCTAssertFalse(text.contains("t0"))
        XCTAssertFalse(text.contains("{title}"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertNotNil(object["pools"] as? [String: Any])
        XCTAssertNotNil(object["recent"] as? [[String]])

        let reloaded = FileSpokenLineMemoryStore(fileURL: url)
        XCTAssertEqual(reloaded.load(), memory.load())
        var second = self.writer(seed: 4, memory: reloaded)
        let plan2 = second.plan(tracks: tracks, briefing: nil, hour: 14)
        let greeting = greetingTemplate(in: plan.breaks[0].cues[0].text)!
        XCTAssertFalse(plan2.breaks[0].cues[0].text.hasPrefix(greeting))
    }

    func testCorruptFileAndUnknownIdsAreIgnored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("line-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("recent-templates.json")
        try Data("not json {{{".utf8).write(to: url)
        let corrupt = FileSpokenLineMemoryStore(fileURL: url)
        XCTAssertEqual(corrupt.load(), .empty)
        var writer = writer(seed: 1, memory: corrupt)
        XCTAssertFalse(writer.plan(tracks: tracks, briefing: nil, hour: 14).breaks.isEmpty, "corrupt data starts fresh")

        let unknown = """
        {"v":1,"pools":{"closing":{"used":["0123456789abcdef","zzzz"],"last":"0123456789abcdef"},"bad key":{"used":["0123456789abcdef"]}},"recent":[["0123456789abcdef"],["not-an-id"]]}
        """
        try Data(unknown.utf8).write(to: url)
        let ignored = FileSpokenLineMemoryStore(fileURL: url)
        XCTAssertEqual(ignored.load().pools["closing"]?.used, ["0123456789abcdef"])
        XCTAssertNil(ignored.load().pools["bad key"])
        XCTAssertEqual(ignored.load().recent, [["0123456789abcdef"]])
        var fresh = self.writer(seed: 1, memory: ignored)
        let plan = fresh.plan(tracks: tracks, briefing: nil, hour: 14)
        XCTAssertNotNil(closingTemplate(plan.breaks[0]), "an unknown id does not silence the pool")
    }

    func testNewerVersionIsLeftOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("line-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("recent-templates.json")
        let original = #"{"v":9,"pools":{"closing":{"used":["abcdef0123456789"]}}}"#
        try Data(original.utf8).write(to: url)
        let memory = FileSpokenLineMemoryStore(fileURL: url)
        XCTAssertEqual(memory.load(), .empty)
        var writer = writer(seed: 2, memory: memory)
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 14)
        writer.commitAiredBreak(plan.breaks[0].cues[0].id)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testPurgeDropsTheFileAndTheNarrationPurgeDoesToo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("line-memory-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("recent-templates.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let memory = FileSpokenLineMemoryStore(fileURL: url)
        var writer = writer(seed: 6, memory: memory)
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 14)
        writer.commitAiredBreak(plan.breaks[0].cues[0].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        memory.purge()
        XCTAssertEqual(memory.load(), .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(FileSpokenLineMemoryStore(fileURL: url).load(), .empty)
    }

    func testTheFolderIsExcludedFromBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("line-memory-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("recent-templates.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = LineMemoryExclusion()
        let memory = FileSpokenLineMemoryStore(fileURL: url, backupExclusion: marker, log: { _ in })
        memory.record(pools: ["closing": ["0123456789abcdef"]], recent: ["0123456789abcdef"],
                      known: ["closing": ["0123456789abcdef"]])
        XCTAssertTrue(marker.marked.contains(LineMemoryExclusion.path(folder)))
        XCTAssertTrue(marker.marked.contains(LineMemoryExclusion.path(url)))
        let reopen = LineMemoryExclusion()
        _ = FileSpokenLineMemoryStore(fileURL: url, backupExclusion: reopen, log: { _ in })
        XCTAssertTrue(reopen.marked.contains(LineMemoryExclusion.path(folder)))
        XCTAssertTrue(reopen.marked.contains(LineMemoryExclusion.path(url)))

        let failing = LineMemoryExclusion(fails: true)
        let blocked = FileSpokenLineMemoryStore(fileURL: folder.appendingPathComponent("nope").appendingPathComponent("recent-templates.json"),
                                                backupExclusion: failing, log: { _ in })
        blocked.record(pools: ["closing": ["0123456789abcdef"]], recent: ["0123456789abcdef"],
                       known: ["closing": ["0123456789abcdef"]])
        XCTAssertEqual(blocked.load().recent, [["0123456789abcdef"]], "the session still remembers when the disk is refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("nope/recent-templates.json").path))
    }

    func testTheStoreIsBoundedAndCycles() {
        var ids = (0..<70).map { String(format: "%016x", $0 + 1) }
        let known = Set(ids)
        var memory = SpokenLineMemory.empty
        memory.record(pools: ["closing": ids], recent: ids, known: ["closing": known])
        XCTAssertEqual(memory.pools["closing"]?.used.count, SpokenLineMemory.maxIDsPerPool)
        XCTAssertEqual(memory.recent.first?.count, SpokenLineMemory.maxIDsPerBreak)
        for index in 0..<10 {
            memory.record(pools: ["closing": [ids[index]]], recent: [ids[index]], known: ["closing": known])
        }
        XCTAssertEqual(memory.recent.count, SpokenLineMemory.maxRecentBreaks)

        let pair: Set<String> = ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"]
        memory = SpokenLineMemory(pools: ["closing": .init(used: Array(pair), last: "bbbbbbbbbbbbbbbb")])
        memory.record(pools: ["closing": ["aaaaaaaaaaaaaaaa"]], recent: ["aaaaaaaaaaaaaaaa"], known: ["closing": pair])
        XCTAssertEqual(memory.pools["closing"]?.used, ["aaaaaaaaaaaaaaaa"])
        XCTAssertEqual(memory.pools["closing"]?.last, "aaaaaaaaaaaaaaaa")
    }

}

@MainActor
final class SpokenLineMemorySessionTests: XCTestCase {
    func testPlaybackRecordsOnlyLinesThatFinished() async throws {
        let memory = InMemorySpokenLineMemoryStore()
        let (first, dj) = await rig(memory)
        await first.queueStarted(djTracks(8))
        await first.songStarted(index: 0, remaining: .seconds(180))
        await untilReady(dj)
        let handedBreak = await first.naturalBoundary(afterTrack: 0)
        let handed = try XCTUnwrap(handedBreak)
        XCTAssertTrue(memory.load().recent.isEmpty, "handing the break out has not aired it")

        let (early, _) = await rig(memory)
        await early.queueStarted(djTracks(8))
        XCTAssertEqual(early.testPlannedBreaks[0]?.cues[0].text, handed.cues[0].text,
                       "nothing has aired, so the next session still draws the same opener")

        first.breakReportsLines(afterTrack: 0)
        first.playbackFinished(afterTrack: 0)
        XCTAssertTrue(memory.load().recent.isEmpty, "lines were reported and none finished")

        let airedMemory = InMemorySpokenLineMemoryStore()
        let (aired, airedDJ) = await rig(airedMemory)
        await aired.queueStarted(djTracks(8))
        await aired.songStarted(index: 0, remaining: .seconds(180))
        await untilReady(airedDJ)
        let playedBreak = await aired.naturalBoundary(afterTrack: 0)
        let played = try XCTUnwrap(playedBreak)
        aired.breakReportsLines(afterTrack: 0)
        for cue in played.cues { aired.lineFinished(afterTrack: 0, cueID: cue.id) }
        aired.playbackFinished(afterTrack: 0)
        XCTAssertEqual(airedMemory.load().recent.count, 1)

        let (second, _) = await rig(airedMemory)
        await second.queueStarted(djTracks(8))
        let opener = try XCTUnwrap(second.testPlannedBreaks[0])
        XCTAssertNotEqual(opener.cues[0].text, played.cues[0].text)
        XCTAssertNotEqual(opener.cues.last?.text, played.cues.last?.text)

        let failedMemory = InMemorySpokenLineMemoryStore()
        let (failed, failedDJ) = await rig(failedMemory)
        await failed.queueStarted(djTracks(8))
        await failed.songStarted(index: 0, remaining: .seconds(180))
        await untilReady(failedDJ)
        let failedHand = await failed.naturalBoundary(afterTrack: 0)
        XCTAssertNotNil(failedHand)
        failed.playbackFailed(afterTrack: 0)
        XCTAssertTrue(failedMemory.load().recent.isEmpty, "a failure never aired")
    }

    func testNarrationPurgeClearsTheMemory() async {
        let memory = InMemorySpokenLineMemoryStore()
        memory.record(pools: ["closing": ["0123456789abcdef"]], recent: ["0123456789abcdef"],
                      known: ["closing": ["0123456789abcdef"]])
        let (session, _) = await rig(memory)
        let purger = NarrationPurger(cache: InMemoryAudioCache(), preparer: nil, session: session)
        await purger.purge(sourceItemIDs: [UUID()])
        XCTAssertEqual(memory.load(), .empty, "withdrawing an item purges the narration cache and this set")

        memory.record(pools: ["closing": ["0123456789abcdef"]], recent: ["0123456789abcdef"],
                      known: ["closing": ["0123456789abcdef"]])
        await purger.purgeAllPersonalNarration()
        XCTAssertEqual(memory.load(), .empty, "the data-reset purge clears it too")
    }

    private func rig(_ memory: any SpokenLineMemoryStoring) async -> (DJBreakSession, DJPresentationStore) {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: .init(commentary: .frequent)))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let dj = DJPresentationStore()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: LineMemoryVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: station.active.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 7, hour: { 14 }, lineMemory: memory)
        await session.start()
        return (session, dj)
    }

    private func untilReady(_ dj: DJPresentationStore) async {
        for _ in 0..<500 {
            if case .ready = dj.studioState { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the break was not ready")
    }
}

private struct LineMemoryVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private final class LineMemoryExclusion: BackupExclusionMarking, @unchecked Sendable {
    private let lock = NSLock()
    private var markedPaths: [String] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    var marked: [String] { lock.withLock { markedPaths } }
    func markExcluded(_ directory: URL) throws {
        lock.withLock { markedPaths.append(Self.path(directory)) }
        if fails { throw CocoaError(.fileWriteNoPermission) }
    }
    func isExcluded(_ directory: URL) throws -> Bool? { lock.withLock { markedPaths.contains(Self.path(directory)) } }
    static func path(_ url: URL) -> String {
        url.standardizedFileURL.path.hasSuffix("/") ? String(url.standardizedFileURL.path.dropLast()) : url.standardizedFileURL.path
    }
}
