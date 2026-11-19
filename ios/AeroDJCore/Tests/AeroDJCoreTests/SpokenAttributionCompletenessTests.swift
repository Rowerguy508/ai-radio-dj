import Foundation
import XCTest
@testable import AeroDJCore

// #388 (Echo's completeness test, -Nova): the talk-over's "does the speaking cue name the song
// just rated never" check reads `SpokenAttribution.trackMetadata(trackIDs:)` and nothing else (no
// title matching on the fade path). That is only safe if every cue whose words contain a queue
// song's title carries that song's ID. This sweeps the script writer over every personality, the
// classic and natural planners, time checks, briefings and the extra-line seam, and checks it.
//
// Fixture names are fictional and chosen so no title is a substring of another title, an artist,
// or any template word.

private struct NamingExtraLine: DJBreakExtraLineSource {
    /// A seam line that names nothing: it must not need an attribution.
    func extraLine(after previous: DJTrack, before next: DJTrack, shape: DJBreakShape) -> DJExtraLine? {
        DJExtraLine(text: "Clouds roll in later.", attribution: .presenter)
    }
}

final class SpokenAttributionCompletenessTests: XCTestCase {
    static let tracks: [DJTrack] = [
        ("Quillfeather Avenue", "Marrow Juniper"), ("Tanglewick Harbour", "Osric Velle"),
        ("Brindlemoor Static", "Pellucid Fawn"), ("Copperwhistle Lane", "Ysolde Gratt"),
        ("Hollowmint Season", "Corvane Dusk"), ("Larkspire Engine", "Marrow Juniper"),
        ("Fennimore Glass", "Tamsin Orrel"), ("Wrenfold Signal", "Bexley Quarn"),
        ("Saltmarrow Drive", "Idris Pelk"), ("Glimmerhaw Tide", "Nolwenn Saye"),
        ("Pebbleroot Choir", "Osric Velle"), ("Ambervault Hours", "Quenby Trask"),
    ].enumerated().map { DJTrack(id: "cat\($0.offset)", title: $0.element.0, artist: $0.element.1, origin: .catalog) }

    private func briefing() -> NarrationHandoff {
        func cue(_ order: Int, _ kind: BriefingScriptSegment.Kind, _ text: String, content: Bool = true) -> NarrationCue {
            NarrationCue(id: UUID(), order: order, group: 0, kind: kind, text: text, estimatedSeconds: 6, maxSeconds: 20,
                         sourceItemID: content ? UUID() : nil, source: content ? .calendar : nil, provenance: content ? "p" : nil)
        }
        return NarrationHandoff(cues: [cue(0, .opener, "Morning.", content: false),
                                       cue(1, .upcomingEvent, "Standup at ten. From your calendar."),
                                       cue(2, .upcomingEvent, "Dentist at four. From your calendar."),
                                       cue(3, .closer, "That's it.", content: false)],
                                maxSpokenSeconds: 120, experienceSeconds: 300)
    }

    private func clock(hour: Int) -> DJPlanClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: hour, minute: 10))!
        return DJPlanClock(now: now, calendar: calendar, style: .twelveHour, airTimes: [:])
    }

    /// Every (break, cue) of one plan where the cue's words contain a queue title but its
    /// attribution does not carry that title's track ID.
    private func gaps(_ plan: DJSessionPlan, tracks: [DJTrack]) -> [String] {
        var out: [String] = []
        for b in plan.breaks {
            for cue in b.cues {
                let ids: [String]
                if case .trackMetadata(let t, _)? = b.attributions[cue.id] { ids = t } else { ids = [] }
                for track in tracks where cue.text.contains(track.title) {
                    if !ids.contains(track.id) {
                        out.append("after \(b.afterTrack): \"\(cue.text)\" names \(track.id), attribution \(String(describing: b.attributions[cue.id]))")
                    }
                }
                // An artist named alone ("more from <artist>") must still carry a song by that artist.
                for artist in Set(tracks.map(\.artist)) where cue.text.contains(artist) {
                    if !tracks.contains(where: { $0.artist == artist && ids.contains($0.id) }) {
                        out.append("after \(b.afterTrack): \"\(cue.text)\" names artist \(artist) with no song of theirs in \(ids)")
                    }
                }
            }
        }
        return out
    }

    func testEveryCueThatSpeaksAQueueTitleCarriesThatSongsID() {
        let dense = DJCadence(talkFraction: 1, minSongsBetweenBreaks: 1)
        var checkedNaming = 0
        var found: [String] = []
        for personality in DJPersonality.allCases {
            for shapes in [nil, DJBreakShapeConfig.natural] {
                for seed in UInt64(0)..<16 {
                    for withBriefing in [false, true] {
                        var writer = DJScriptWriter(cadence: dense, seed: seed, tone: .forPersonality(personality), shapes: shapes)
                        if seed % 3 == 0 { writer.extraLineSource = NamingExtraLine() }
                        let hour = Int(seed % 24)
                        let plan = writer.plan(tracks: Self.tracks, briefing: withBriefing ? briefing() : nil, hour: hour,
                                               clock: shapes == nil ? nil : clock(hour: hour))
                        found += gaps(plan, tracks: Self.tracks)
                        checkedNaming += plan.breaks.flatMap(\.cues).filter { cue in
                            Self.tracks.contains { cue.text.contains($0.title) }
                        }.count
                    }
                }
            }
        }
        XCTAssertGreaterThan(checkedNaming, 500, "the sweep must actually see cues that name songs")
        XCTAssertEqual(found, [], "\(found.count) cue(s) name a queue song without its ID; first: \(found.prefix(5))")
    }

    /// The check itself catches a missing ID (a mutant cue builder that drops one).
    func testTheCheckCatchesACueThatOmitsTheSongsID() {
        let cue = NarrationCue(id: UUID(), order: 0, group: 0, kind: .note, text: "Up next, Tanglewick Harbour.",
                               estimatedSeconds: 2, maxSeconds: 4, sourceItemID: nil, source: nil, provenance: nil)
        let wrong = DJBreak(afterTrack: 0, cues: [cue], attributions: [cue.id: .trackMetadata(trackIDs: ["cat0"])])
        let none = DJBreak(afterTrack: 0, cues: [cue], attributions: [cue.id: .presenter])
        let right = DJBreak(afterTrack: 0, cues: [cue], attributions: [cue.id: .trackMetadata(trackIDs: ["cat0", "cat1"])])
        func plan(_ b: DJBreak) -> DJSessionPlan { DJSessionPlan(breaks: [b], briefingReport: NarrationScheduleReport(entries: [])) }
        XCTAssertEqual(gaps(plan(wrong), tracks: Self.tracks).count, 1)
        XCTAssertEqual(gaps(plan(none), tracks: Self.tracks).count, 1)
        XCTAssertEqual(gaps(plan(right), tracks: Self.tracks), [])
    }
}
