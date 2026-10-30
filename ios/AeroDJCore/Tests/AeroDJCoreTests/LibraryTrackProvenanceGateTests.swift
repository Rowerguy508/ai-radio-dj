import XCTest
@testable import AeroDJCore

// Library provenance gate (Sentinel): a track from the listener's own Apple Music library, or
// one whose origin is unknown, is personal. On a CATALOG station (no library seed, so the
// station-wide `onDeviceOnly` gate is off) DJ lines naming it must still never reach an
// off-device voice: back-announce, artist focus, "up next" intro and (with #209) the closing
// line alike. Genuinely catalog tracks keep the cloud voice. In-process fakes only.

/// Off-device spy: records every text it is handed and renders it at once.
private final class ProvenanceSpy: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var received: [String] { lock.withLock { texts } }
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        lock.withLock { texts.append(text) }
        return VoiceArtifact(data: Data("cloud".utf8), durationSeconds: 1, billableUnits: text.count,
                             provider: "cloud", cacheKey: nil)
    }
}

private struct ProvenanceDeviceVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data("device".utf8), durationSeconds: 1, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

/// Odd indices use `personal`; even indices are catalog. Personal names all contain "Private".
private func mixedTracks(_ n: Int, personal: TrackOrigin) -> [DJTrack] {
    (0..<n).map { i in
        i % 2 == 0
            ? DJTrack(id: "c\(i)", title: "Open Song \(i)", artist: "Open Artist \(i)", origin: .catalog)
            : DJTrack(id: "p\(i)", title: "Private Song \(i)", artist: "Private Artist \(i)", origin: personal)
    }
}

private func transition(_ text: String) -> NarrationCue {
    NarrationCue(id: UUID(), order: 0, group: -1, kind: .transition, text: text,
                 estimatedSeconds: 3, maxSeconds: 20, sourceItemID: nil, source: nil, provenance: nil)
}

final class LibraryTrackProvenanceGateTests: XCTestCase {
    private func renderer(_ spy: ProvenanceSpy) -> VoiceRenderer {
        VoiceRenderer(routes: [VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice, leavesDevice: true),
                               VoiceRoute(providerID: "device", provider: ProvenanceDeviceVoice(), voice: djVoice)],
                      budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                      revocations: NarrationRevocations(), cloudConsent: .inMemory(.accepted))
    }

    // MARK: The gate itself

    func testOnlyCatalogTrackMetadataMayLeaveTheDevice() {
        let cue = transition("Up next, a song.")
        XCTAssertTrue(VoiceRenderer.mayLeaveDevice(cue, attribution: .trackMetadata(trackIDs: ["c"], origin: .catalog)))
        XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: .trackMetadata(trackIDs: ["l"], origin: .library)))
        XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: .trackMetadata(trackIDs: ["u"], origin: .unknown)))
        XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: .trackMetadata(trackIDs: ["d"])),
                       "no origin recorded: fail closed")
        XCTAssertTrue(VoiceRenderer.mayLeaveDevice(cue, attribution: .presenter), "presenter lines are unchanged")
    }

    func testResolvingTakesTheMostRestrictiveOriginAndFailsClosed() {
        let tracks = [DJTrack(id: "c", title: "A", artist: "B", origin: .catalog),
                      DJTrack(id: "l", title: "C", artist: "D", origin: .library),
                      DJTrack(id: "u", title: "E", artist: "F"),
                      DJTrack(id: "dup", title: "G", artist: "H", origin: .catalog),
                      DJTrack(id: "dup", title: "G", artist: "H", origin: .library)]
        func origin(_ ids: [String]) -> TrackOrigin? {
            if case .trackMetadata(_, let o) = SpokenAttribution.trackMetadata(trackIDs: ids).resolvingTrackOrigins(in: tracks) { o } else { nil }
        }
        XCTAssertEqual(origin(["c"]), .catalog)
        XCTAssertEqual(origin(["l"]), .library)
        XCTAssertEqual(origin(["u"]), .unknown, "a track with no recorded origin")
        XCTAssertEqual(origin(["missing"]), .unknown, "an id not in the queue")
        XCTAssertEqual(origin([]), .unknown, "no id named")
        XCTAssertEqual(origin(["c", "l"]), .library)
        XCTAssertEqual(origin(["c", "u"]), .unknown)
        XCTAssertEqual(origin(["dup"]), .library, "the same id seen as library anywhere is library")
        // A stale `.catalog` claim is replaced by what the queue says.
        XCTAssertEqual(SpokenAttribution.trackMetadata(trackIDs: ["l"], origin: .catalog).resolvingTrackOrigins(in: tracks),
                       .trackMetadata(trackIDs: ["l"], origin: .library))
        XCTAssertEqual(SpokenAttribution.presenter.resolvingTrackOrigins(in: tracks), .presenter)
    }

    /// Every cue the writer attributes to a library or unknown track is local-only, whatever its
    /// position in the break (opener, intro, or #209's closing line); catalog-only cues stay eligible.
    func testWriterTagsEveryCueNamingAPersonalTrack() {
        for personal in [TrackOrigin.library, .unknown] {
            let tracks = mixedTracks(12, personal: personal)
            let origins = Dictionary(tracks.map { ($0.id, $0.origin) }, uniquingKeysWith: { $0.restricted(by: $1) })
            var namedPersonal = 0, namedCatalog = 0
            for seed: UInt64 in 1...6 {
                var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 0), seed: seed)
                for djBreak in writer.plan(tracks: tracks, briefing: nil, hour: 14).breaks {
                    for cue in djBreak.cues {
                        guard case .trackMetadata(let ids, let origin)? = djBreak.attributions[cue.id] else { continue }
                        let expected = ids.map { origins[$0] ?? .unknown }.reduce(TrackOrigin.catalog) { $0.restricted(by: $1) }
                        XCTAssertEqual(origin, expected, "\(ids)")
                        let mayLeave = VoiceRenderer.mayLeaveDevice(cue, attribution: djBreak.attributions[cue.id])
                        if expected == .catalog { namedCatalog += 1; XCTAssertTrue(mayLeave) }
                        else { namedPersonal += 1; XCTAssertFalse(mayLeave, "\(personal) track line may leave: \(cue.text)") }
                    }
                }
            }
            XCTAssertGreaterThan(namedPersonal, 0, "precondition: some lines name a \(personal) track")
            XCTAssertGreaterThan(namedCatalog, 0, "precondition: some lines name a catalog track")
        }
    }

    // MARK: Preparer: transition and intro lines on a catalog station

    private func prepareAll(_ breaks: [DJBreak], spy: ProvenanceSpy) async -> [PreparedDJBreak] {
        let preparer = DJBreakPreparer(renderer: renderer(spy), userID: "u", stationID: "s",
                                       cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 0))
        var ready: [PreparedDJBreak] = []
        for djBreak in breaks {
            await preparer.prepare(djBreak, deadline: .seconds(10), onDeviceOnly: false)  // catalog station
            while await preparer.testResult(afterTrack: djBreak.afterTrack) == nil { await Task.yield() }
            if case .ready(let b) = await preparer.takeBreak(afterTrack: djBreak.afterTrack) { ready.append(b) }
        }
        return ready
    }

    private func assertPersonalTracksStayOnDevice(_ personal: TrackOrigin) async {
        let spy = ProvenanceSpy()
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 0), seed: 4)
        let breaks = writer.plan(tracks: mixedTracks(10, personal: personal), briefing: nil, hour: 14).breaks
        let ready = await prepareAll(breaks, spy: spy)
        XCTAssertFalse(ready.isEmpty, "precondition: breaks play on-device")
        XCTAssertFalse(spy.received.contains { $0.contains("Private") },
                       "a \(personal) track's name reached the off-device voice: \(spy.received)")
        var personalOnDevice = 0
        for b in ready {
            for (cue, clip) in zip(b.cues, b.clips) where cue.text.contains("Private") {
                XCTAssertEqual(clip.audio.providerID, "device"); personalOnDevice += 1
            }
        }
        XCTAssertGreaterThan(personalOnDevice, 0, "precondition: \(personal) tracks were named and spoken on-device")
        XCTAssertTrue(spy.received.contains { $0.contains("Open") }, "catalog track lines still use the cloud voice")
    }

    func testLibraryTrackOnACatalogStationNeverReachesTheOffDeviceVoice() async {
        await assertPersonalTracksStayOnDevice(.library)
    }

    func testUnknownOriginTrackNeverReachesTheOffDeviceVoice() async {
        await assertPersonalTracksStayOnDevice(.unknown)
    }

    func testAllCatalogQueueStillUsesTheCloudVoice() async {
        let spy = ProvenanceSpy()
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 0), seed: 4)
        let tracks = (0..<6).map { DJTrack(id: "c\($0)", title: "Open Song \($0)", artist: "Open Artist \($0)", origin: .catalog) }
        let ready = await prepareAll(writer.plan(tracks: tracks, briefing: nil, hour: 14).breaks, spy: spy)
        XCTAssertFalse(ready.isEmpty)
        XCTAssertTrue(ready.allSatisfy { $0.clips.allSatisfy { $0.audio.providerID == "cloud" } },
                      "every line of an all-catalog break keeps the selected cloud voice")
        XCTAssertTrue(spy.received.contains { $0.contains("Open Song") })
    }

    /// #209's talk-over closing line (`talkOverCueID`) names the next track: when that track is
    /// from the library or of unknown origin the closing cue is local-only; when it is catalog it
    /// keeps the cloud voice. Rendered through the preparer with an off-device spy.
    func testTalkOverClosingCueNamingAPersonalNextTrackStaysOnDevice() async {
        // Library and unknown origin, both parities, so closing lines land on personal and on
        // catalog next tracks.
        let queues = [TrackOrigin.library, .unknown].flatMap { personal in
            [mixedTracks(12, personal: personal), Array(mixedTracks(13, personal: personal).dropFirst())]
        }
        var closings = (personal: 0, catalog: 0)
        for tracks in queues {
            var breaks: [DJBreak] = []
            for seed: UInt64 in 1...8 {
                var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 0), seed: seed)
                for b in writer.plan(tracks: tracks, briefing: nil, hour: 14).breaks {
                    guard let id = b.talkOverCueID, let cue = b.cues.first(where: { $0.id == id }) else { continue }
                    let next = tracks[b.afterTrack + 1]
                    XCTAssertEqual(b.attributions[id], .trackMetadata(trackIDs: [next.id], origin: next.origin))
                    XCTAssertEqual(VoiceRenderer.mayLeaveDevice(cue, attribution: b.attributions[id]), next.origin == .catalog)
                    if next.origin == .catalog { closings.catalog += 1 } else { closings.personal += 1 }
                    if seed == 1 { breaks.append(b) }
                }
            }
            let spy = ProvenanceSpy()
            let ready = await prepareAll(breaks, spy: spy)
            XCTAssertFalse(spy.received.contains { $0.contains("Private") }, "a personal closing line reached the cloud")
            for b in ready {
                guard let id = b.talkOverCueID, let i = b.cues.firstIndex(where: { $0.id == id }) else { continue }
                XCTAssertEqual(b.clips[i].audio.providerID, b.cues[i].text.contains("Private") ? "device" : "cloud", b.cues[i].text)
            }
        }
        XCTAssertGreaterThan(closings.personal, 0, "precondition: a closing line names a personal track")
        XCTAssertGreaterThan(closings.catalog, 0, "precondition: a closing line names a catalog track")
    }

    /// A hand-built break whose last ("up next" / closing) cue names a library track: that cue is
    /// local, so the break plays on-device in one voice (#267); the library track never reaches the cloud.
    func testClosingCueNamingALibraryTrackStaysLocalWhileMainMayUseCloud() async {
        let spy = ProvenanceSpy()
        let tracks = [DJTrack(id: "c0", title: "Open Song", artist: "Open Artist", origin: .catalog),
                      DJTrack(id: "p1", title: "Private Song", artist: "Private Artist", origin: .library)]
        let main = transition("Good to have you with us.")
        let back = transition("That was Open Song by Open Artist.")
        let closing = transition("Here's Private Artist, with Private Song.")
        let attributions: [UUID: SpokenAttribution] = [
            main.id: .presenter,
            back.id: SpokenAttribution.trackMetadata(trackIDs: ["c0"]).resolvingTrackOrigins(in: tracks),
            closing.id: SpokenAttribution.trackMetadata(trackIDs: ["p1"]).resolvingTrackOrigins(in: tracks),
        ]
        let ready = await prepareAll([DJBreak(afterTrack: 0, cues: [main, back, closing], attributions: attributions)], spy: spy)
        XCTAssertEqual(ready.first?.clips.map(\.audio.providerID), ["device", "device", "device"])
        XCTAssertFalse(spy.received.contains { $0.contains("Private") })
    }
}

// MARK: Session paths: prepare, replan after a cadence change, and seek re-arm

@MainActor
final class LibraryTrackProvenanceSessionTests: XCTestCase {
    private struct Rig {
        let session: DJBreakSession
        let preparer: DJBreakPreparer
        let station: StationConfigurationModel
        let spy: ProvenanceSpy
    }

    private func rig() async -> Rig {
        let catalog = StationSeed(kind: .artist, catalogID: "123", name: "Artist", source: .catalog)
        let config = StationConfiguration(commentary: .frequent, seeds: [catalog])
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        XCTAssertFalse(DJBreakSession.speaksOnDeviceOnly(station.active), "precondition: a catalog station")
        let spy = ProvenanceSpy()
        let renderer = VoiceRenderer(
            routes: [VoiceRoute(providerID: "cloud", provider: spy, voice: djVoice, leavesDevice: true),
                     VoiceRoute(providerID: "device", provider: ProvenanceDeviceVoice(), voice: djVoice)],
            budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(), revocations: NarrationRevocations(), cloudConsent: .inMemory(.accepted))
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let session = DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: 1, hour: { 14 })
        await session.start()
        return Rig(session: session, preparer: preparer, station: station, spy: spy)
    }

    private func settled(_ r: Rig, _ k: Int) async -> DJBreakOutcome? {
        for _ in 0..<2000 {
            if let result = await r.preparer.testResult(afterTrack: k) { return result }
            await Task.yield()
        }
        return nil
    }

    /// Plays the whole queue through the session, taking every break at its natural boundary.
    private func playThrough(_ r: Rig, count: Int, from first: Int = 0) async -> [PreparedDJBreak] {
        var spoken: [PreparedDJBreak] = []
        for k in first..<(count - 1) {
            await r.session.songStarted(index: k, remaining: .seconds(180))
            if r.session.plannedBoundaries.contains(k) { _ = await settled(r, k) }
            if let b = await r.session.naturalBoundary(afterTrack: k) { spoken.append(b) }
            r.session.playbackFinished(afterTrack: k)
        }
        return spoken
    }

    private func assertNoPersonalNameLeft(_ r: Rig, _ spoken: [PreparedDJBreak], _ message: String) {
        XCTAssertFalse(r.spy.received.contains { $0.contains("Private") }, "\(message): \(r.spy.received)")
        let personal = spoken.flatMap { b in zip(b.cues, b.clips).filter { $0.0.text.contains("Private") } }
        XCTAssertFalse(personal.isEmpty, "precondition (\(message)): a library track was named on air")
        XCTAssertTrue(personal.allSatisfy { $0.1.audio.providerID == "device" }, message)
    }

    func testCatalogStationSessionKeepsLibraryTrackLinesOnDevice() async {
        let r = await rig()
        await r.session.queueStarted(mixedTracks(12, personal: .library))
        let spoken = await playThrough(r, count: 12)
        assertNoPersonalNameLeft(r, spoken, "prepare path")
        XCTAssertFalse(r.spy.received.isEmpty, "the catalog station still uses the cloud voice")
        await r.session.stop()
    }

    func testReplanAfterACadenceChangeKeepsLibraryTrackLinesOnDevice() async {
        let r = await rig()
        await r.session.queueStarted(mixedTracks(14, personal: .library))
        let first = await playThrough(r, count: 3)  // boundaries 0 and 1 under the original plan
        await r.station.setCommentary(.chatty)       // re-planned at the next song start
        let rest = await playThrough(r, count: 14, from: 2)
        assertNoPersonalNameLeft(r, first + rest, "replan path")
        XCTAssertGreaterThan(rest.count, 1, "precondition: the re-planned (chatty) breaks were spoken")
        await r.session.stop()
    }

    func testSeekReArmKeepsLibraryTrackLinesOnDevice() async {
        let r = await rig()
        await r.session.queueStarted(mixedTracks(8, personal: .library))
        guard let k = r.session.plannedBoundaries.first else { return XCTFail("precondition: a break is planned") }
        for i in 0..<k {
            await r.session.songStarted(index: i, remaining: .seconds(180))
            r.session.playbackFinished(afterTrack: i)
        }
        await r.session.songStarted(index: k, remaining: .seconds(180))
        _ = await settled(r, k)
        await r.preparer.testRecord(.skipped(.timedOut), afterTrack: k)
        await r.session.songSeeked(index: k, remaining: .seconds(150))   // re-arms the timed-out break
        guard case .ready? = await settled(r, k) else { return XCTFail("the re-armed break renders on-device") }
        guard let b = await r.session.naturalBoundary(afterTrack: k) else { return XCTFail("re-armed break is handed out") }
        assertNoPersonalNameLeft(r, [b], "re-arm path")
        await r.session.stop()
    }
}
