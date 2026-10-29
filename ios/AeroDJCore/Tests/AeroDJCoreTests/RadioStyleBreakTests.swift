import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AeroDJCore

// Radio-style breaks (Echo): longer warm pools, a 15 s main segment, and one closing line that
// names the next song. The closing line is its own cue, budgeted at 4 s, and exposed to the
// player through `PreparedDJBreak.talkOverStartSeconds` / `talkOverSeconds`. All voices are
// in-process fakes: no network, no paid service.

private struct WordVoice: VoiceProvider {
    var secondsPerWord: Double = 0.3
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * secondsPerWord,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

private actor Calls {
    var count = 0
    func bump() { count += 1 }
}

/// Off-device route spy, the same shape as LibrarySeedVoiceGateTests' transport.
private struct RecordingTransport: HTTPTransport {
    let calls = Calls()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await calls.bump()
        let headers = ["Content-Type": "audio/wav", "X-Audio-Duration": "3.0", "X-Billed-Characters": "20"]
        return (Data([9, 9]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

private struct DeviceVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        VoiceArtifact(data: Data(voice.id.utf8), durationSeconds: 2, billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

final class RadioStyleBreakTests: XCTestCase {
    private let tracks = [
        DJTrack(id: "1", title: "Holocene", artist: "Bon Iver"),
        DJTrack(id: "2", title: "Myth", artist: "Beach House"),
        DJTrack(id: "3", title: "Midnight City", artist: "M83"),
        DJTrack(id: "4", title: "Vienna", artist: "Billy Joel"),
        DJTrack(id: "5", title: "Dreams", artist: "Fleetwood Mac"),
        DJTrack(id: "6", title: "Pink + White", artist: "Frank Ocean"),
    ]

    private func placeholders(_ line: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.insert(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    // MARK: Pools

    func testWarmPoolsUseOnlyTheirOwnMetadataPlaceholders() {
        let tone = EditorialTone.warm
        let allowed: [(String, [String], Set<String>)] = [
            ("backAnnounce", tone.backAnnounce, ["title", "artist"]),
            ("artistFocus", tone.artistFocus, ["title", "artist"]),
            ("closing", tone.closing, ["nextTitle", "nextArtist"]),
            ("stationID", tone.stationID, ["station"]),
            ("continuation", tone.continuation, []),
            ("briefingLead", tone.briefingLead, []),
            ("briefingOutro", tone.briefingOutro, []),
            ("atmosphere", tone.atmosphere.values.flatMap { $0 }, []),
            ("greetings", tone.greetings.values.flatMap { $0 }, []),
        ]
        for (name, lines, ok) in allowed {
            XCTAssertFalse(lines.isEmpty, name)
            XCTAssertEqual(Set(lines).count, lines.count, "\(name) has no duplicate lines")
            for line in lines {
                XCTAssertTrue(placeholders(line).isSubset(of: ok), "\(name): \(line)")
            }
        }
        for part in DayPart.allCases {
            XCTAssertFalse(tone.atmosphere[part, default: []].isEmpty, "time-of-day color for \(part)")
            XCTAssertFalse(tone.greetings[part, default: []].isEmpty, "greeting for \(part)")
        }
        XCTAssertTrue(tone.closing.allSatisfy { !placeholders($0).isEmpty }, "every closing line names the next song")
    }

    func testWarmPoolsAreFactFreePlainTextWithoutHype() {
        let tone = EditorialTone.warm
        for line in tone.allLines {
            XCTAssertFalse(line.contains("<") || line.contains(">"), "no SSML in cloud text: \(line)")
            for hype in EditorialPhrasing.forbiddenHype {
                XCTAssertFalse(line.lowercased().contains(hype), line)
            }
            XCTAssertFalse(line.contains(where: \.isNumber), "no invented numbers, dates or chart facts: \(line)")
        }
        // Closing line: one short sentence, about 7 words or fewer.
        for line in tone.closing {
            XCTAssertLessThanOrEqual(line.split(separator: " ").count, 7, line)
            XCTAssertEqual(line.filter { $0 == "." }.count, 1, line)
        }
        XCTAssertTrue(tone.allLines.contains { $0.contains("—") }, "em dashes for natural pauses")
        XCTAssertTrue(tone.allLines.contains { $0.contains("'") }, "contractions")
        XCTAssertEqual(EditorialPhrasing.songIntro, tone.closing)
    }

    // MARK: Break shape and the closing marker

    func testEveryTalkBreakEndsWithItsOwnClosingCueForTheNextTrack() {
        var sawStation = false, sawAtmosphere = false, sawContinuation = false
        for seed in UInt64(0)..<300 {
            var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed, stationName: "AeroDJ")
            let plan = writer.plan(tracks: tracks, briefing: nil, hour: [7, 15, 21, 23][Int(seed % 4)])
            XCTAssertFalse(plan.breaks.isEmpty)
            for djBreak in plan.breaks {
                let next = tracks[djBreak.afterTrack + 1]
                let closing = djBreak.cues.last!
                XCTAssertEqual(djBreak.talkOverCueID, closing.id, "the closing line is marked as the talk-over cue")
                XCTAssertEqual(djBreak.attributions[closing.id], .trackMetadata(trackIDs: [next.id]),
                               "attributed to the next track only")
                XCTAssertEqual(closing.kind, .transition)
                XCTAssertNil(closing.sourceItemID)
                XCTAssertTrue(closing.text.contains(next.title), closing.text)
                XCTAssertGreaterThan(djBreak.cues.count, 1, "a main segment always comes first")
                XCTAssertEqual(djBreak.cues.filter { $0.id == djBreak.talkOverCueID }.count, 1)
                XCTAssertEqual(Set(djBreak.cues.map(\.id)), Set(djBreak.attributions.keys))
                let main = djBreak.cues.dropLast()
                XCTAssertFalse(main.contains { $0.text.contains(next.title) && $0.id != closing.id
                    && djBreak.attributions[$0.id] != .presenter && !$0.text.contains(tracks[djBreak.afterTrack].title) })
                for cue in main {
                    if EditorialTone.warm.stationID.contains(where: { $0.replacingOccurrences(of: "{station}", with: "AeroDJ") == cue.text }) { sawStation = true }
                    if EditorialTone.warm.atmosphere.values.joined().contains(cue.text) { sawAtmosphere = true }
                    if EditorialTone.warm.continuation.contains(cue.text) { sawContinuation = true }
                }
            }
        }
        XCTAssertTrue(sawStation && sawAtmosphere && sawContinuation, "every main-segment pool is used")
    }

    func testCapsMainFifteenClosingFourBriefingFortyFive() {
        let cadence = DJCadence()
        XCTAssertEqual(cadence.maxTransitionSeconds, 15)
        XCTAssertEqual(cadence.maxClosingSeconds, 4)
        XCTAssertEqual(cadence.maxBriefingBreakSeconds, 45)
        XCTAssertEqual(cadence.talkFraction, 0.3)
        for seed in UInt64(0)..<200 {
            var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed, stationName: "AeroDJ")
            for djBreak in writer.plan(tracks: djTracks(40), briefing: nil, hour: 15).breaks {
                XCTAssertLessThanOrEqual(djBreak.mainSeconds, 15)
                XCTAssertLessThanOrEqual(djBreak.closingSeconds, 4)
                XCTAssertEqual(djBreak.estimatedSeconds, djBreak.mainSeconds + djBreak.closingSeconds)
            }
        }
        // A tight main cap drops the continuation and color first; the break still airs.
        var tight = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1, maxTransitionSeconds: 3),
                                   seed: 5, stationName: "AeroDJ")
        for djBreak in tight.plan(tracks: tracks, briefing: nil, hour: 23).breaks {
            XCTAssertLessThanOrEqual(djBreak.mainSeconds, 3)
            XCTAssertNotNil(djBreak.talkOverCueID)
        }
    }

    func testAClosingLineOverItsOwnCapIsNotTalkOverAndCountsInTheMainSegment() {
        var tone = EditorialTone.warm
        tone.closing = ["Coming up after this one, here is {nextTitle} by {nextArtist}, a song from the queue."]
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 3,
                                    stationName: "AeroDJ", tone: tone)
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 15)
        XCTAssertFalse(plan.breaks.isEmpty)
        for djBreak in plan.breaks {
            XCTAssertNil(djBreak.talkOverCueID, "over 4 s: plays in the gap, never over the intro")
            XCTAssertEqual(djBreak.closingSeconds, 0)
            XCTAssertLessThanOrEqual(djBreak.mainSeconds, 15, "and it counts against the main cap")
            XCTAssertEqual(djBreak.attributions[djBreak.cues.last!.id], .trackMetadata(trackIDs: [tracks[djBreak.afterTrack + 1].id]))
        }
    }

    func testToneSwapsWithoutEngineChanges() {
        let tone = EditorialTone(
            backAnnounce: ["{title} — {artist}."], closing: ["Now, {nextTitle}."], artistFocus: ["{artist}."],
            stationID: ["{station}."], atmosphere: [:], continuation: ["Okay."], briefingLead: ["Quickly."],
            briefingOutro: ["Done."], greetings: [:])
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 4,
                                    stationName: "AeroDJ", tone: tone)
        let plan = writer.plan(tracks: tracks, briefing: nil, hour: 15)
        XCTAssertFalse(plan.breaks.isEmpty)
        for djBreak in plan.breaks {
            let warmOnly = Set(EditorialTone.warm.allLines.filter { placeholders($0).isEmpty })
            XCTAssertFalse(djBreak.cues.contains { warmOnly.contains($0.text) }, "only the swapped tone's words")
            XCTAssertEqual(djBreak.cues.last?.text, "Now, \(tracks[djBreak.afterTrack + 1].title).")
        }
    }

    func testPoolsDoNotRepeatUntilExhausted() {
        // Same title/artist everywhere, so the text identifies the template.
        let same = (0..<40).map { DJTrack(id: "s\($0)", title: "Tune", artist: "Band") }
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 8, stationName: "AeroDJ")
        let breaks = writer.plan(tracks: same, briefing: nil, hour: 15).breaks
        let closings = breaks.map { $0.cues.last!.text }
        let n = EditorialTone.warm.closing.count
        XCTAssertGreaterThanOrEqual(closings.count, n * 2)
        for cycle in stride(from: 0, to: closings.count - n + 1, by: n) {
            XCTAssertEqual(Set(closings[cycle..<cycle + n]).count, n, "no closing line repeats within a cycle")
        }
        let continuations = breaks.flatMap(\.cues).map(\.text).filter { EditorialTone.warm.continuation.contains($0) }
        let m = EditorialTone.warm.continuation.count
        XCTAssertGreaterThanOrEqual(continuations.count, m)
        XCTAssertEqual(Set(continuations.prefix(m)).count, m)
        for (a, b) in zip(closings, closings.dropFirst()) { XCTAssertNotEqual(a, b, "never twice in a row") }
    }

    // MARK: Scripts batch 2 (Echo, build 27)

    func testBatch2PoolsRoughlyDoubleAndStayDistinct() {
        let tone = EditorialTone.warm
        XCTAssertGreaterThanOrEqual(tone.backAnnounce.count, 12)
        XCTAssertGreaterThanOrEqual(tone.closing.count, 10)
        XCTAssertGreaterThanOrEqual(tone.stationID.count, 8)
        for part in DayPart.allCases {
            XCTAssertGreaterThanOrEqual(tone.greetings[part, default: []].count, 4, "greetings for \(part)")
            XCTAssertGreaterThanOrEqual(tone.atmosphere[part, default: []].count, 4, "time-of-day color for \(part)")
        }
        XCTAssertEqual(Set(tone.allLines).count, tone.allLines.count, "no line appears in two pools")
        // Lines that differ only by punctuation are paraphrases, not variety.
        let shapes = tone.allLines.map { line in
            line.lowercased().filter { $0.isLetter || $0 == " " || $0 == "{" || $0 == "}" }
                .split(separator: " ").joined(separator: " ")
        }
        XCTAssertEqual(Set(shapes).count, shapes.count)
        for line in tone.allLines {
            XCTAssertFalse(line.contains("!"), "no exclamations: \(line)")
        }
    }

    func testTimeOfDayLinesOnlyNameTheirOwnDayPart() {
        let tone = EditorialTone.warm
        let foreign: [DayPart: [String]] = [
            .earlyMorning: ["afternoon", "evening", "night"],
            .morning: ["afternoon", "evening", "night"],
            .afternoon: ["morning", "evening", "night"],
            .evening: ["morning", "afternoon", "late"],
            .lateNight: ["morning", "afternoon", "evening"],
        ]
        for part in DayPart.allCases {
            for line in tone.greetings[part, default: []] + tone.atmosphere[part, default: []] {
                for word in foreign[part, default: []] {
                    XCTAssertFalse(line.lowercased().contains(word), "\(part): \(line)")
                }
            }
        }
    }

    func testWorstCaseDurationsWithLongNamesStayInsideTheCaps() throws {
        let tone = EditorialTone.warm
        let cadence = DJCadence()
        func seconds(_ text: String) -> Double { Double(SpokenDurationEstimate.seconds(text)) }
        func fill(_ template: String, _ values: [String: String]) throws -> String {
            try XCTUnwrap(TemplatePool.fill(template, values), template)
        }
        // Six-word title and six-word artist: longer than almost anything MusicKit returns.
        let longTitle = "The Less I Know the Better", longArtist = "Edward Sharpe and the Magnetic Zeros"
        let prev = ["title": longTitle, "artist": longArtist]
        let next = ["nextTitle": longTitle, "nextArtist": longArtist]

        // Closing: at most three words besides the names, so a next song whose title and artist
        // come to seven words or fewer always gets a talk-over closing line (4 s).
        for line in tone.closing {
            XCTAssertLessThanOrEqual(line.split(separator: " ").filter { !$0.contains("{") }.count, 3, line)
            let filled = try fill(line, ["nextTitle": "Here Comes the Sun", "nextArtist": "Tears for Fears"])
            XCTAssertLessThanOrEqual(seconds(filled), Double(cadence.maxClosingSeconds), filled)
        }
        // Opener plus a closing that is too long to talk over still fits the main cap, so long
        // names never skip a break; the planner trims color and continuation first.
        let opener = try (tone.backAnnounce + tone.artistFocus).map { seconds(try fill($0, prev)) }.max() ?? 0
        let closing = try tone.closing.map { seconds(try fill($0, next)) }.max() ?? 0
        XCTAssertLessThanOrEqual(opener + closing, Double(cadence.maxTransitionSeconds))
        // Every color and continuation line is short on its own.
        let station = try XCTUnwrap(EditorialStationName.usable("The Late Night Listening Room on AeroDJ"))
        for line in try tone.stationID.map({ try fill($0, ["station": station]) }) + tone.continuation
            + tone.atmosphere.values.joined() + tone.greetings.values.joined() {
            XCTAssertLessThanOrEqual(seconds(line), 7, line)
        }
        // Planner: every eligible boundary airs a break inside both caps.
        let tracks = (0..<41).map { DJTrack(id: "l\($0)", title: longTitle, artist: longArtist) }
        for seed in UInt64(0)..<100 {
            for hour in [5, 9, 15, 19, 23] {
                var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed,
                                            stationName: station)
                let breaks = writer.plan(tracks: tracks, briefing: nil, hour: hour).breaks
                XCTAssertEqual(breaks.count, 20, "no break skipped for length (seed \(seed), hour \(hour))")
                for djBreak in breaks {
                    XCTAssertLessThanOrEqual(djBreak.mainSeconds, Double(cadence.maxTransitionSeconds))
                    XCTAssertLessThanOrEqual(djBreak.closingSeconds, Double(cadence.maxClosingSeconds))
                }
            }
        }
    }

    // MARK: Station-ID attribution (Sentinel, build-26 sweep)

    func testAStationIDNamingACreatedStationStaysOnDevice() {
        func stationCues(_ name: String) -> [(NarrationCue, SpokenAttribution?)] {
            var found: [(NarrationCue, SpokenAttribution?)] = []
            for seed in UInt64(0)..<60 {
                var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: seed, stationName: name)
                for djBreak in writer.plan(tracks: tracks, briefing: nil, hour: 15).breaks {
                    for cue in djBreak.cues where cue.text.contains(name) {
                        found.append((cue, djBreak.attributions[cue.id]))
                    }
                }
            }
            return found
        }
        let builtIn = stationCues(DJScriptWriter.builtInStationName)
        XCTAssertFalse(builtIn.isEmpty)
        for (cue, attribution) in builtIn {
            XCTAssertEqual(attribution, .presenter, cue.text)
            XCTAssertTrue(VoiceRenderer.mayLeaveDevice(cue, attribution: attribution), "the app's own name may use the cloud voice")
        }
        for created in ["Ana's Road Trip", "Morning Mix", "aerodj", "AeroDJ Late"] {
            let cues = stationCues(created)
            XCTAssertFalse(cues.isEmpty, created)
            for (cue, attribution) in cues {
                guard case .personalContext? = attribution else { return XCTFail("\(created): \(String(describing: attribution))") }
                XCTAssertFalse(VoiceRenderer.mayLeaveDevice(cue, attribution: attribution), "a created station's name stays local: \(cue.text)")
            }
        }
    }

    func testBriefingBreakKeepsItsCapAndEndsWithTheClosingLine() {
        let item = UUID()
        let cues = (0..<5).map { i in
            NarrationCue(id: UUID(), order: i, group: i, kind: .note, text: "Item \(i) from your notes, with a few words.",
                         estimatedSeconds: 8, maxSeconds: 16, sourceItemID: item, source: .obsidian, provenance: "n:\(i)")
        }
        let handoff = NarrationHandoff(cues: cues, maxSpokenSeconds: 120, experienceSeconds: 600)
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 2, stationName: "AeroDJ")
        let plan = writer.plan(tracks: djTracks(10), briefing: handoff, hour: 8)
        let briefing = plan.breaks.filter(\.hasBriefing)
        XCTAssertFalse(briefing.isEmpty)
        for djBreak in briefing {
            XCTAssertLessThanOrEqual(djBreak.estimatedSeconds, 45, "the closing line counts inside the 45 s briefing cap")
            XCTAssertEqual(djBreak.attributions[djBreak.cues.last!.id], .trackMetadata(trackIDs: ["t\(djBreak.afterTrack + 1)"]))
            XCTAssertEqual(djBreak.talkOverCueID, djBreak.cues.last!.id)
        }
    }

    // MARK: Hook on PreparedDJBreak

    private func cue(_ text: String, item: UUID? = nil, maxSeconds: Int = 8) -> NarrationCue {
        NarrationCue(id: UUID(), order: 0, group: -1, kind: item == nil ? .transition : .note, text: text,
                     estimatedSeconds: 2, maxSeconds: maxSeconds, sourceItemID: item, source: item == nil ? nil : .obsidian,
                     provenance: item == nil ? nil : "n:1")
    }

    private func clip(_ cue: NarrationCue, _ seconds: Double) -> RenderedClip {
        RenderedClip(cueID: cue.id, audio: CachedAudio(data: Data([1]), seconds: seconds, providerID: "device", voiceID: "v"),
                     cacheKey: "k", attempts: [])
    }

    func testTalkOverHookIsThePrecedingClipsPlusTheGapAndTheClosingClip() throws {
        let a = cue("That was Song 0.", item: nil), b = cue("Stay right where you are."), c = cue("Here's Song 1.")
        let prepared = PreparedDJBreak(afterTrack: 0, cues: [a, b, c], clips: [clip(a, 2.5), clip(b, 1.25), clip(c, 1.5)],
                                       attributions: [a.id: .trackMetadata(trackIDs: ["t0"]), b.id: .presenter,
                                                      c.id: .trackMetadata(trackIDs: ["t1"])],
                                       talkOverCueID: c.id)
        XCTAssertEqual(PreparedDJBreak.talkOverGapSeconds, 0.3)
        XCTAssertEqual(try XCTUnwrap(prepared.talkOverStartSeconds), 2.5 + 1.25 + 0.3, accuracy: 1e-9)
        XCTAssertEqual(prepared.talkOverSeconds, 1.5)

        var none = prepared
        none.talkOverCueID = nil
        XCTAssertNil(none.talkOverStartSeconds, "no closing cue: no hook")
        XCTAssertNil(none.talkOverSeconds)

        // Closing cue dropped (cues and clips filtered together): cleared.
        let dropped = PreparedDJBreak(afterTrack: 0, cues: [a, b], clips: [clip(a, 2.5), clip(b, 1.25)],
                                      attributions: [a.id: .presenter, b.id: .presenter], talkOverCueID: c.id)
        XCTAssertNil(dropped.talkOverStartSeconds)
        XCTAssertNil(dropped.talkOverSeconds)
        // A main cue dropped: recomputed from what is left.
        let fewer = PreparedDJBreak(afterTrack: 0, cues: [a, c], clips: [clip(a, 2.5), clip(c, 1.5)],
                                    attributions: [a.id: .presenter, c.id: .trackMetadata(trackIDs: ["t1"])], talkOverCueID: c.id)
        XCTAssertEqual(try XCTUnwrap(fewer.talkOverStartSeconds), 2.8, accuracy: 1e-9)
        XCTAssertEqual(fewer.talkOverSeconds, 1.5)
        // Only the closing line left, or clips out of step with cues: fails closed to nil.
        let alone = PreparedDJBreak(afterTrack: 0, cues: [c], clips: [clip(c, 1.5)],
                                    attributions: [c.id: .presenter], talkOverCueID: c.id)
        XCTAssertNil(alone.talkOverStartSeconds)
        let skewed = PreparedDJBreak(afterTrack: 0, cues: [a, b, c], clips: [clip(a, 2.5), clip(c, 1.5)],
                                     attributions: [:], talkOverCueID: c.id)
        XCTAssertNil(skewed.talkOverStartSeconds)
        XCTAssertNil(skewed.talkOverSeconds)
        // Not the last cue: never a talk-over start.
        let early = PreparedDJBreak(afterTrack: 0, cues: [a, c, b], clips: [clip(a, 2.5), clip(c, 1.5), clip(b, 1.25)],
                                    attributions: [:], talkOverCueID: c.id)
        XCTAssertNil(early.talkOverStartSeconds)
    }

    // MARK: Preparer and session pass the hook through

    @MainActor
    private func session(_ config: StationConfiguration, voice: WordVoice = .init())
        async -> (DJBreakSession, StationConfigurationModel, DJPresentationStore, DJBreakPreparer) {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        await station.setPlaybackActivity(.holdingSong)
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: voice, voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        let dj = DJPresentationStore()
        let s = DJBreakSession(preparer: preparer, station: station, dj: dj, seed: 1, hour: { 14 })
        await s.start()
        return (s, station, dj, preparer)
    }

    @MainActor
    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private static func seeded(_ id: String) -> StationConfiguration {
        var config = StationConfiguration(commentary: .frequent)
        config.seeds = [StationSeed(kind: .artist, catalogID: id, name: "Artist \(id)")]
        return config
    }

    @MainActor
    func testPreparedBreakCarriesTheHookAndAStaleUpNextDropClearsIt() async throws {
        // No drop: the hook is the measured main segment plus the gap.
        let (keep, keepStation, keepDJ, _) = await session(Self.seeded("old"))
        await keep.queueStarted(djTracks(8))
        await keep.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = keepDJ.studioState { true } else { false } }
        await keepStation.setEnergy(0.9)
        await keepStation.saveChanges()
        let keptBreak = await keep.naturalBoundary(afterTrack: 0)
        let kept = try XCTUnwrap(keptBreak)
        let closing = try XCTUnwrap(kept.talkOverCueID)
        XCTAssertEqual(kept.cues.last?.id, closing)
        XCTAssertEqual(kept.attributions[closing], .trackMetadata(trackIDs: ["t1"]))
        let main = kept.clips.dropLast().reduce(0) { $0 + $1.audio.seconds }
        XCTAssertEqual(try XCTUnwrap(kept.talkOverStartSeconds), main + 0.3, accuracy: 1e-9)
        XCTAssertEqual(kept.talkOverSeconds, kept.clips.last?.audio.seconds)
        XCTAssertLessThanOrEqual(main, 15)
        XCTAssertLessThanOrEqual(try XCTUnwrap(kept.talkOverSeconds), 4)

        // Seeds change promoted at the boundary: the closing names a song that will not play.
        let (stale, staleStation, staleDJ, _) = await session(Self.seeded("old"))
        await stale.queueStarted(djTracks(8))
        await stale.songStarted(index: 0, remaining: .seconds(180))
        await until { if case .ready = staleDJ.studioState { true } else { false } }
        await staleStation.setSeeds(Self.seeded("new").seeds)
        await staleStation.saveChanges()
        let droppedBreak = await stale.naturalBoundary(afterTrack: 0)
        let dropped = try XCTUnwrap(droppedBreak, "the main segment is still true")
        XCTAssertFalse(dropped.cues.contains { dropped.attributions[$0.id] == .trackMetadata(trackIDs: ["t1"]) })
        XCTAssertNil(dropped.talkOverCueID)
        XCTAssertNil(dropped.talkOverStartSeconds, "no closing cue left: no talk-over")
        XCTAssertNil(dropped.talkOverSeconds)
        XCTAssertEqual(dropped.cues.count, dropped.clips.count)
    }

    @MainActor
    func testAConsentDropRecomputesTheHookFromTheKeptClips() async throws {
        let approved = UUID(), unknown = UUID()
        let (s, _, _, preparer) = await session(StationConfiguration(commentary: .frequent))
        let source = ConnectionItem(id: approved, integration: .obsidian, title: "[TEST] note", state: .approved, sensitivity: .medium)
        await s.queueStarted(djTracks(8), sources: [source])
        XCTAssertFalse(s.plannedBoundaries.contains(1))
        await s.songStarted(index: 1, remaining: .seconds(180))
        let opener = cue("That was Song 1."), kept = cue("From your notes: one.", item: approved)
        let lapsed = cue("From your notes: two.", item: unknown), closing = cue("Here's Song 2.")
        let all = [opener, kept, lapsed, closing]
        await preparer.testRecord(.ready(PreparedDJBreak(
            afterTrack: 1, cues: all, clips: [clip(opener, 2), clip(kept, 3), clip(lapsed, 4), clip(closing, 1.5)],
            attributions: [opener.id: .trackMetadata(trackIDs: ["t1"]),
                           kept.id: .personalContext(itemID: approved, source: .obsidian, provenance: "n:1"),
                           lapsed.id: .personalContext(itemID: unknown, source: .obsidian, provenance: "n:1"),
                           closing.id: .trackMetadata(trackIDs: ["t2"])],
            talkOverCueID: closing.id)), afterTrack: 1)
        let handedBreak = await s.naturalBoundary(afterTrack: 1)
        let handed = try XCTUnwrap(handedBreak)
        XCTAssertEqual(handed.cues.map(\.id), [opener.id, kept.id, closing.id], "the unapproved item is dropped")
        XCTAssertEqual(handed.talkOverCueID, closing.id)
        XCTAssertEqual(try XCTUnwrap(handed.talkOverStartSeconds), 2 + 3 + 0.3, accuracy: 1e-9, "recomputed without the dropped clip")
        XCTAssertEqual(handed.talkOverSeconds, 1.5)
    }

    func testPreparerCapsTheMainSegmentAndTheClosingLineSeparately() async {
        // 0.6 s/word: a 25-word main segment measures 15 s, a 6-word closing 3.6 s; 18.6 s in all.
        let main = cue(Array(repeating: "word", count: 25).joined(separator: " "), maxSeconds: 30)
        let closing = cue("Here's Song one, from Artist one.")
        func plan(talkOver: Bool) -> DJBreak {
            var b = DJBreak(afterTrack: 0, cues: [main, closing],
                            attributions: [main.id: .presenter, closing.id: .trackMetadata(trackIDs: ["t1"])])
            if talkOver { b.talkOverCueID = closing.id }
            return b
        }
        func outcome(_ b: DJBreak) async -> DJBreakOutcome {
            let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: WordVoice(secondsPerWord: 0.6), voice: djVoice)],
                                         budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
            let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s")
            let done = AsyncStream<Void>.makeStream()
            await preparer.observe { event in
                switch event {
                case .prepared, .skipped: done.continuation.yield()
                case .preparing: break
                }
            }
            await preparer.prepare(b, deadline: .seconds(5), onDeviceOnly: false)
            for await _ in done.stream { break }
            return await preparer.takeBreak(afterTrack: 0)
        }
        guard case .ready(let ready) = await outcome(plan(talkOver: true)) else {
            return XCTFail("15 s main + 3.6 s talk-over closing fits 15 + 4")
        }
        XCTAssertEqual(ready.talkOverCueID, closing.id)
        XCTAssertEqual(ready.talkOverStartSeconds ?? 0, 15.3, accuracy: 1e-6)
        XCTAssertEqual(ready.talkOverSeconds ?? 0, 3.6, accuracy: 1e-6)
        let skipped = await outcome(plan(talkOver: false))
        XCTAssertEqual(skipped, .skipped(.overBreakBudget), "without the marker it is all main segment: over 15 s")
    }

    /// Fixed measured seconds per cue text, scaled per voice id (a slower premium voice).
    private struct ScriptedVoice: VoiceProvider {
        let seconds: [String: Double]
        var scale: [String: Double] = [:]
        func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
            let plain = SpeechDelivery.plainText(fromSSML: text)
            return VoiceArtifact(data: Data(plain.utf8), durationSeconds: (seconds[plain] ?? 1) * (scale[voice.id] ?? 1),
                                 billableUnits: 0, provider: "device", cacheKey: nil)
        }
    }

    private func outcome(_ b: DJBreak, routes: [VoiceRoute]) async -> DJBreakOutcome {
        let renderer = VoiceRenderer(routes: routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s")
        let done = AsyncStream<Void>.makeStream()
        await preparer.observe { event in
            switch event {
            case .prepared, .skipped: done.continuation.yield()
            case .preparing: break
            }
        }
        await preparer.prepare(b, deadline: .seconds(5), onDeviceOnly: false)
        for await _ in done.stream { break }
        return await preparer.takeBreak(afterTrack: b.afterTrack)
    }

    private func talkOverBreak(main: NarrationCue, closing: NarrationCue) -> DJBreak {
        var b = DJBreak(afterTrack: 0, cues: [main, closing],
                        attributions: [main.id: .presenter, closing.id: .trackMetadata(trackIDs: ["t1"])])
        b.talkOverCueID = closing.id
        return b
    }

    func testMainAndClosingCapsAreEnforcedSeparatelyNotPooled() async {
        let main = cue("A long main segment.", maxSeconds: 30), closing = cue("Here's Song one.")
        func route(_ voice: ScriptedVoice, id: String = "standard") -> VoiceRoute {
            VoiceRoute(providerID: "device", provider: voice, voice: VoiceProfile(id: id, name: "Host"))
        }
        // 18 s main + 1 s closing: 19 s in all, but MAIN is over 15. Single $0 route: no retry, skipped.
        let over = ScriptedVoice(seconds: [main.text: 18, closing.text: 1])
        let mainOver = await outcome(talkOverBreak(main: main, closing: closing), routes: [route(over)])
        XCTAssertEqual(mainOver, .skipped(.overBreakBudget), "18 + 1 must not pass as a pooled 19 s")
        // 10 s main + 5 s closing: 15 s in all, but the closing line is over 4.
        let long = ScriptedVoice(seconds: [main.text: 10, closing.text: 5])
        let closingOver = await outcome(talkOverBreak(main: main, closing: closing), routes: [route(long)])
        XCTAssertEqual(closingOver, .skipped(.overBreakBudget), "the closing line keeps its own 4 s cap")
        // 15 s + 4 s: both at their caps, accepted.
        let edge = ScriptedVoice(seconds: [main.text: 15, closing.text: 4])
        guard case .ready(let atCaps) = await outcome(talkOverBreak(main: main, closing: closing), routes: [route(edge)]) else {
            return XCTFail("15 + 4 is within both caps")
        }
        XCTAssertEqual(atCaps.talkOverStartSeconds ?? 0, 15.3, accuracy: 1e-9)

        // Existing over-cap path, unchanged: a slower premium voice measures 18 + 1, so the whole
        // break is re-rendered once on the last $0 on-device route (9 + 0.5), in one voice.
        let scaled = ScriptedVoice(seconds: [main.text: 18, closing.text: 1], scale: ["standard": 0.5])
        guard case .ready(let retried) = await outcome(talkOverBreak(main: main, closing: closing),
                                                       routes: [route(scaled, id: "premium"), route(scaled)]) else {
            return XCTFail("the $0 retry fits both caps")
        }
        XCTAssertEqual(retried.clips.map(\.audio.voiceID), ["standard", "standard"])
        XCTAssertEqual(retried.talkOverStartSeconds ?? 0, 9.3, accuracy: 1e-9)
        // Still over on the retry (18 + 1 in both voices): skipped, as before.
        let stillOver = await outcome(talkOverBreak(main: main, closing: closing), routes: [route(over, id: "premium"), route(over)])
        XCTAssertEqual(stillOver, .skipped(.overBreakBudget))
    }

    func testBriefingBreakKeepsTheFortyFiveSecondTotalRule() async {
        let item = UUID()
        let content = NarrationCue(id: UUID(), order: 1, group: 0, kind: .note, text: "From your notes: one.",
                                   estimatedSeconds: 8, maxSeconds: 60, sourceItemID: item, source: .obsidian, provenance: "n:1")
        let closing = cue("Here's Song one.")
        // 40 s of briefing + a 5 s closing line: 45 s total passes (the closing is inside the 45 s).
        var b = DJBreak(afterTrack: 0, cues: [content, closing],
                        attributions: [content.id: .personalContext(itemID: item, source: .obsidian, provenance: "n:1"),
                                       closing.id: .trackMetadata(trackIDs: ["t1"])])
        b.talkOverCueID = closing.id
        let voice = ScriptedVoice(seconds: [content.text: 40, closing.text: 5])
        let r = VoiceRoute(providerID: "device", provider: voice, voice: djVoice)
        let ok = await outcome(b, routes: [r])
        guard case .ready = ok else { return XCTFail("45 s total is the briefing rule") }
        let tooLong = ScriptedVoice(seconds: [content.text: 41, closing.text: 5])
        let over = await outcome(b, routes: [VoiceRoute(providerID: "device", provider: tooLong, voice: djVoice)])
        XCTAssertEqual(over, .skipped(.overBreakBudget))
    }

    // MARK: Library gate (Sentinel #154/#176): the closing never reaches the off-device route

    private let jade = "g7LVvkPWALzPxOQbF6OE"
    private func composed(_ transport: RecordingTransport) -> VoiceRenderer {
        let device = ["premium", "standard"].map {
            VoiceRoute(providerID: "avspeech", provider: DeviceVoice(), voice: VoiceProfile(id: $0, name: "Host"))
        }
        let c = PremiumVoiceRoutes.compose(
            onDevice: device, paidProvidersEnabled: true, selectedVoiceID: jade,
            credentials: PremiumProxyCredentials(endpoint: URL(string: "https://aerodj-tts.vercel.app/api/tts")!, token: "owner-test-token"),
            pinnedHosts: ["aerodj-tts.vercel.app"], transport: transport)
        return VoiceRenderer(routes: c.routes, budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache(),
                             revocations: NarrationRevocations())
    }

    private func prepare(_ djBreak: DJBreak, _ r: VoiceRenderer, onDeviceOnly: Bool) async -> DJBreakOutcome {
        let preparer = DJBreakPreparer(renderer: r, userID: "u", stationID: "s")
        let done = AsyncStream<Void>.makeStream()
        await preparer.observe { event in
            switch event {
            case .prepared, .skipped: done.continuation.yield()
            case .preparing: break
            }
        }
        await preparer.prepare(djBreak, deadline: .seconds(5), onDeviceOnly: onDeviceOnly)
        for await _ in done.stream { break }
        return await preparer.takeBreak(afterTrack: djBreak.afterTrack)
    }

    func testLibrarySeededClosingNeverReachesTheOffDeviceRouteWhileMainCuesAreCloudEligible() async throws {
        var writer = DJScriptWriter(cadence: .init(talkFraction: 1, minSongsBetweenBreaks: 1), seed: 2, stationName: "AeroDJ")
        let djBreak = try XCTUnwrap(writer.plan(tracks: tracks, briefing: nil, hour: 15).breaks.first { $0.afterTrack == 2 })
        let closing = try XCTUnwrap(djBreak.talkOverCueID)
        XCTAssertEqual(djBreak.attributions[closing], .trackMetadata(trackIDs: ["4"]), "its own cue, the next track's metadata")
        for cue in djBreak.cues {   // every cue, the closing included, is gated per cue
            XCTAssertTrue(VoiceRenderer.mayLeaveDevice(cue, attribution: djBreak.attributions[cue.id]),
                          "MAIN and closing are cloud-eligible on a catalog station")
        }

        // Catalog station: the gate allows the cloud route for each cue (proves the spy would see it).
        let cloud = RecordingTransport()
        guard case .ready(let viaCloud) = await prepare(djBreak, composed(cloud), onDeviceOnly: false) else {
            return XCTFail("catalog station renders")
        }
        let cloudCalls = await cloud.calls.count
        XCTAssertEqual(cloudCalls, djBreak.cues.count)
        XCTAssertTrue(viaCloud.clips.allSatisfy { $0.audio.providerID == "elevenlabs" })

        // Library-seeded station (the next track comes from the listener's library): nothing,
        // the closing included, reaches the off-device route.
        let library = StationSeed(kind: .playlist, catalogID: "p.lib1", name: "Road Trip", source: .library)
        XCTAssertTrue(DJBreakSession.speaksOnDeviceOnly(StationConfiguration(seeds: [library])))
        let spy = RecordingTransport()
        guard case .ready(let local) = await prepare(djBreak, composed(spy), onDeviceOnly: true) else {
            return XCTFail("an on-device route is available")
        }
        let calls = await spy.calls.count
        XCTAssertEqual(calls, 0, "the closing line never reaches the proxy")
        XCTAssertEqual(local.clips.last?.cueID, closing)
        XCTAssertEqual(local.clips.last?.audio.providerID, "avspeech")
        XCTAssertNotNil(local.talkOverStartSeconds, "on-device clips keep the hook")
    }
}
