# DJ persona evidence: samples, estimated durations, cap and repeat stats (lane 4)

Evidence for the four DJ personas (`EditorialTone.forPersonality`: warm, upbeat, laidBack, minimal) on `integration/device-duo` at **c3fb6a96c4de7b2919ece7332cfa2d99d7c83183** (#348 merged). -Echo

> **All durations here are word-rate ESTIMATES**, from `DefaultBriefingPlanner.estimatedSpokenSeconds` (150 words per minute, rounded up per line) plus the planner's 0.3 s pause before a talk-over closing line (`DJScriptWriter.wholeSeconds`). **None of this is measured audio.** Nobody has listened to these lines. This is planner output, not device evidence.

All track titles and artists below are **invented example metadata**, not real catalog tracks. Some include catalog-style suffixes (`(Remastered 2011)`, `(feat. …)`, `[Explicit]`, `(Live 2014)`, `(Clean Mix)`) so `SpokenTitle` gets exercised.

## Setup

- The writer is built the way `DJBreakSession` builds it: `DJScriptWriter(cadence: station.active.cadence(base: DJCadence()), seed:, stationName: DJScriptWriter.builtInStationName, tone: EditorialTone.forPersonality(p), shapes: .natural)`. `AppDependencies` passes the default base. The station is `StationConfiguration(personality: p)`, which uses the default `commentary: .occasional`.
- Resulting cadence: `talkFraction` 0.3, `minSongsBetweenBreaks` 2, `maxOrdinaryBreakSeconds` 12, `maxClosingSeconds` 4, `maxTransitionSeconds` 15 for warm, upbeat and laidBack, and 6 for minimal (`DJPersonality.maxTransitionSeconds`).
- Main run: 600 sessions per personality. Session `s` uses seed `0x4543484F + s` and plays the 12 example tracks once, rotated by `s % 12`, at local hour `[8, 14, 19, 23][s % 4]` (morning, afternoon, evening, late night). There's no briefing, so every break is an ordinary break.
- Supplementary run: the same 600 seeds with 60-song sessions (the 12 tracks cycled 5 times), so the 6-break anti-repeat window and the station ID grace period actually fill up. Songs repeat in this run, which a real queue usually would not.
- The same seeds are used for every personality. Break positions and shapes come from RNG streams that don't depend on the tone, so all four personas get identical positions and shape mixes. Only the words and the caps differ.
- How the repeat stats are computed: an identical-line repeat is a spoken line whose normalised text (`RecentSpokenTemplates.textKey`) appeared in the previous 6 breaks of the same session. A shared-phrase repeat is a line that isn't identical but shares a sentence of 3 or more words (`RecentSpokenTemplates.phrases`) with those breaks. An opener first-word repeat is two consecutive breaks whose first lines start with the same word. A "Here's" violation is any 3 consecutive breaks with more than one line starting "Here's". These are checked on spoken text only, not by template, so the same template with a different song isn't counted.

## Summary: main run (600 sessions × 12 songs per personality)

| Personality | Boundaries | Breaks | Speech share | Combined / natural breaks | Whole break max / p95 (cap 12 s) | Main segment max / p95 (cap) | Talk-over closing max (cap 4 s) | Over any cap | Max cues (limit 4) | Identical-line repeats | Shared-phrase repeats | Opener first-word repeats | "Here's" violations |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| warm | 6600 | 2178 | 33.0% | 33.4% | 11.3 / 10.3 s | 8.0 / 6.0 s (cap 15 s) | 4.0 s | 0 | 4 | 0 of 4265 lines | 0 | 0 of 1578 pairs | 0 of 982 windows |
| upbeat | 6600 | 2178 | 33.0% | 33.4% | 11.3 / 10.3 s | 9.0 / 7.0 s (cap 15 s) | 4.0 s | 0 | 4 | 0 of 4243 lines | 0 | 0 of 1578 pairs | 0 of 982 windows |
| laidBack | 6600 | 2178 | 33.0% | 33.4% | 11.3 / 10.3 s | 9.0 / 7.0 s (cap 15 s) | 4.0 s | 0 | 4 | 0 of 4244 lines | 0 | 0 of 1578 pairs | 0 of 982 windows |
| minimal | 6600 | 2178 | 33.0% | 33.4% | 10.3 / 8.3 s | 6.0 / 5.0 s (cap 6 s) | 4.0 s | 0 | 4 | 0 of 4268 lines | 0 | 0 of 1578 pairs | 0 of 982 windows |

Shape mix, identical for all four personas: greeting (classic planner) 600 (27.5%), combined 527 (24.2%), classic 403 (18.5%), comingUpOnly 380 (17.4%), backAnnounceOnly 219 (10.1%), stationID 49 (2.2%). `timeCheckIntro` never appears, because no clock source is wired into the writer yet (`timeCheckAvailable: false`).

## Supplementary: 600 sessions × 60 songs per personality

| Personality | Boundaries | Breaks | Speech share | Combined / natural breaks | Whole break max / p95 (cap 12 s) | Main segment max / p95 (cap) | Talk-over closing max (cap 4 s) | Over any cap | Max cues (limit 4) | Identical-line repeats | Shared-phrase repeats | Opener first-word repeats | "Here's" violations |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| warm | 35400 | 10754 | 30.4% | 29.3% | 11.3 / 10.3 s | 8.0 / 6.0 s (cap 15 s) | 4.0 s | 0 | 4 | 0 of 17593 lines | 0 | 1 of 10154 pairs | 0 of 9554 windows |
| upbeat | 35400 | 10754 | 30.4% | 29.3% | 11.3 / 10.3 s | 9.0 / 6.0 s (cap 15 s) | 4.0 s | 0 | 4 | 0 of 17475 lines | 0 | 0 of 10154 pairs | 0 of 9554 windows |
| laidBack | 35400 | 10754 | 30.4% | 29.3% | 11.3 / 10.3 s | 9.0 / 6.0 s (cap 15 s) | 4.0 s | 0 | 4 | 0 of 17483 lines | 0 | 0 of 10154 pairs | 0 of 9554 windows |
| minimal | 35400 | 10754 | 30.4% | 29.3% | 10.3 / 7.3 s | 6.0 / 5.0 s (cap 6 s) | 4.0 s | 0 | 4 | 0 of 17607 lines | 0 | 1 of 10154 pairs | 0 of 9554 windows |

Shape mix, identical for all four personas: combined 2975 (27.7%), comingUpOnly 2366 (22.0%), classic 2339 (21.8%), backAnnounceOnly 1311 (12.2%), stationID 1163 (10.8%), greeting (classic planner) 600 (5.6%).

## Findings

- **No cap breaches.** Across both runs, no planned break went over 12 s whole, over the main-segment cap (15 s, or 6 s for minimal), or over the 4 s talk-over closing cap. No break had more than 4 cues, and no boundary was skipped for being over a cap. The longest whole breaks were 11.3 s (warm, upbeat, laidBack) and 10.3 s (minimal). Minimal's main segment reached exactly its 6 s cap. All of these are estimates.
- **Speech share is 33.0% in 12-song sessions and 30.4% in 60-song sessions**, against the 30% target (`expectedTalkShare` 30.0%). `eligibleBoundaryProbability` is a long-run solution. My likely explanation for the extra 3 points in short queues is that the first boundary of a session has no earlier break holding it silent. I haven't verified that further.
- **Combined is 33.4% of natural-shape breaks in 12-song sessions and 29.3% in 60-song sessions** (its weight is 30%). Station ID is only 2.2% of breaks in 12-song sessions, against a weight of 10. That's because it's barred from the first 2 breaks after the greeting, and a 12-song session has only about 2.6 natural breaks. In 60-song sessions it reaches 10.8%. The greeting break, which goes through the classic planner, is 27.5% of all breaks in 12-song sessions.
- **Repeats:** no identical-line repeats, no shared-phrase repeats and no "Here's" violations in any run. Opener first-word repeats appear only in the 60-song run: 1 of 10154 consecutive pairs for warm, 1 for minimal and 0 for upbeat and laidBack. That's the planner's tier-2 fallback, which relaxes the first-word rule when nothing else fits, and it's allowed by design.
- **Things to check when listening (not tested):** titles that keep their version text are read out with the brackets, for example “Ocean Avenue (Live 2014)” and “Now, Coastline Radio with Ocean Avenue (Live 2014).” How a voice reads the brackets and the year is untested. A `featuring` title inside a combined line can sound clumsy, for example warm's “Somewhere Warm featuring Lila Ray there. Up next, The Hollow Pines.” Combined lines over 4 s estimated, such as that one at 5 s, don't talk over the next intro and play in the gap instead.

## Sample breaks (main run)

These are the first break of each shape in seed order from sessions 0–39, then the earliest other breaks, up to 8 per personality. Each line shows its own estimate. The whole-break figure adds the 0.3 s pause before a talk-over closing line. **All are estimates, not measured audio.**

### warm

| Session | Hour | After track | Shape | Spoken lines (per-line estimate) | Est. whole break |
|---|---|---|---|---|---|
| 0 | 8 | 1 | `greeting (classic planner)` | “Hey, good morning.” (2 s) / “Stay right there.” (2 s) / “And this one's Slow Burn.” (2 s) | 6.3 s (main 4.0, closing 2.0) |
| 0 | 8 | 4 | `combined` | “Somewhere Warm featuring Lila Ray there. Up next, The Hollow Pines.” (5 s) | 5.0 s (main 5.0, closing 0.0) |
| 0 | 8 | 7 | `comingUpOnly` | “Ruby Vale now, with Static Hearts.” (3 s) | 3.0 s (main 0.0, closing 3.0) |
| 1 | 14 | 0 | `greeting (classic planner)` | “Good afternoon.” (1 s) / “OnAirly. Good to have you.” (2 s) / “Thanks for hanging out.” (2 s) / “Here's Northbound Echo, with Slow Burn.” (3 s) | 8.3 s (main 5.0, closing 3.0) |
| 1 | 14 | 4 | `combined` | “That was The Hollow Pines. Next, Odessa Bloom.” (4 s) | 4.0 s (main 0.0, closing 4.0) |
| 2 | 19 | 7 | `classic` | “Coastline Radio with Ocean Avenue (Live 2014), just now.” (4 s) / “Lots more music ahead.” (2 s) / “Sable & Stone now, with Low Light.” (3 s) | 9.3 s (main 6.0, closing 3.0) |
| 3 | 23 | 8 | `backAnnounceOnly` | “That's Carry Me Home from Ada Wren.” (3 s) | 3.0 s (main 3.0, closing 0.0) |
| 10 | 19 | 10 | `stationID` | “Right here on OnAirly.” (2 s) / “Now, Coastline Radio with Ocean Avenue (Live 2014).” (4 s) | 6.3 s (main 2.0, closing 4.0) |

### upbeat

| Session | Hour | After track | Shape | Spoken lines (per-line estimate) | Est. whole break |
|---|---|---|---|---|---|
| 0 | 8 | 1 | `greeting (classic planner)` | “Morning, everybody.” (1 s) / “Keep it right here.” (2 s) / “Turn it up for Slow Burn.” (3 s) | 6.3 s (main 3.0, closing 3.0) |
| 0 | 8 | 4 | `combined` | “Here's Midnight Ferry, right after Somewhere Warm featuring Lila Ray.” (4 s) | 4.0 s (main 0.0, closing 4.0) |
| 0 | 8 | 7 | `comingUpOnly` | “Keep it going with Static Hearts.” (3 s) | 3.0 s (main 0.0, closing 3.0) |
| 1 | 14 | 0 | `greeting (classic planner)` | “Hey there, afternoon crew.” (2 s) / “OnAirly. Let's keep going.” (2 s) / “Plenty more on the way.” (2 s) / “Here comes Northbound Echo with Slow Burn.” (3 s) | 9.3 s (main 6.0, closing 3.0) |
| 1 | 14 | 4 | `combined` | “From The Hollow Pines to Odessa Bloom, no stopping.” (4 s) | 4.0 s (main 0.0, closing 4.0) |
| 2 | 19 | 7 | `classic` | “Coastline Radio just now. That's Ocean Avenue (Live 2014).” (4 s) / “More coming your way.” (2 s) / “Now it's Sable & Stone, Low Light.” (3 s) | 9.3 s (main 6.0, closing 3.0) |
| 3 | 23 | 8 | `backAnnounceOnly` | “Ada Wren, everybody. That was Carry Me Home.” (4 s) | 4.0 s (main 4.0, closing 0.0) |
| 10 | 19 | 10 | `stationID` | “This is OnAirly. Here we go.” (3 s) / “Rolling right into Ocean Avenue (Live 2014).” (3 s) | 6.3 s (main 3.0, closing 3.0) |

### laidBack

| Session | Hour | After track | Shape | Spoken lines (per-line estimate) | Est. whole break |
|---|---|---|---|---|---|
| 0 | 8 | 1 | `greeting (classic planner)` | “Morning. Make yourself comfy.” (2 s) / “Stay as long as you like.” (3 s) / “Let's slip into Slow Burn.” (2 s) | 7.3 s (main 5.0, closing 2.0) |
| 0 | 8 | 4 | `combined` | “Somewhere Warm featuring Lila Ray just went by. Now it's Midnight Ferry.” (5 s) | 5.0 s (main 5.0, closing 0.0) |
| 0 | 8 | 7 | `comingUpOnly` | “This is Static Hearts, from Ruby Vale.” (3 s) | 3.0 s (main 0.0, closing 3.0) |
| 1 | 14 | 0 | `greeting (classic planner)` | “Hey, afternoon. Kick back.” (2 s) / “Just OnAirly, and you.” (2 s) / “Plenty more, no rush.” (2 s) / “And now, it's Slow Burn.” (2 s) | 8.3 s (main 6.0, closing 2.0) |
| 1 | 14 | 4 | `combined` | “There's The Hollow Pines. We'll let Odessa Bloom take it from here.” (5 s) | 5.0 s (main 5.0, closing 0.0) |
| 2 | 19 | 7 | `classic` | “Hope that one sat well. Ocean Avenue (Live 2014), Coastline Radio.” (5 s) / “We're not going anywhere.” (2 s) / “Now a little Sable & Stone, Low Light.” (4 s) | 11.3 s (main 7.0, closing 4.0) |
| 3 | 23 | 8 | `backAnnounceOnly` | “There was Ada Wren, with Carry Me Home.” (4 s) | 4.0 s (main 4.0, closing 0.0) |
| 10 | 19 | 10 | `stationID` | “This is OnAirly. Take your time.” (3 s) / “Something from Coastline Radio now, Ocean Avenue (Live 2014).” (4 s) | 7.3 s (main 3.0, closing 4.0) |

### minimal

| Session | Hour | After track | Shape | Spoken lines (per-line estimate) | Est. whole break |
|---|---|---|---|---|---|
| 0 | 8 | 1 | `greeting (classic planner)` | “Hey. Morning.” (1 s) / “There's more.” (1 s) / “Now, Slow Burn.” (2 s) | 4.3 s (main 2.0, closing 2.0) |
| 0 | 8 | 4 | `combined` | “Somewhere Warm featuring Lila Ray. Up next, The Hollow Pines.” (4 s) | 4.0 s (main 0.0, closing 4.0) |
| 0 | 8 | 7 | `comingUpOnly` | “Ruby Vale now, Static Hearts.” (2 s) | 2.0 s (main 0.0, closing 2.0) |
| 1 | 14 | 0 | `greeting (classic planner)` | “Afternoon, all.” (1 s) / “OnAirly, on air.” (2 s) / “Back to it.” (2 s) / “Slow Burn.” (1 s) | 6.3 s (main 5.0, closing 1.0) |
| 1 | 14 | 4 | `combined` | “The Hollow Pines out. Odessa Bloom in.” (3 s) | 3.0 s (main 0.0, closing 3.0) |
| 2 | 19 | 7 | `classic` | “Ocean Avenue (Live 2014). That was Coastline Radio.” (4 s) / “More music next.” (2 s) / “It's Low Light.” (2 s) | 8.3 s (main 6.0, closing 2.0) |
| 3 | 23 | 8 | `backAnnounceOnly` | “That's Carry Me Home.” (2 s) | 2.0 s (main 2.0, closing 0.0) |
| 10 | 19 | 10 | `stationID` | “OnAirly. Stay put.” (2 s) / “Next, Ocean Avenue (Live 2014).” (2 s) | 4.3 s (main 2.0, closing 2.0) |

## Reproduce

1. Check out `integration/device-duo` at `c3fb6a96c4de7b2919ece7332cfa2d99d7c83183`.
2. Save the harness below as `ios/AeroDJCore/Tests/AeroDJCoreTests/PersonaEvidenceHarness.swift`. It's a throwaway file that isn't committed.
3. From `ios/AeroDJCore`, run `PERSONA_OUT=/tmp/persona-evidence.md swift test --filter PersonaEvidenceHarness`. The run here used Swift 6.4.1 on Linux x86_64 and took about 133 s. Every figure in this doc comes from that output file. Then delete the harness file.

The output is deterministic: two runs at this commit gave the same stats.

```swift
// THROWAWAY evidence harness for docs/dj-persona-evidence.md. Not committed.
// Run: PERSONA_OUT=/tmp/persona.md swift test --filter PersonaEvidenceHarness
import Foundation
import XCTest
@testable import AeroDJCore

final class PersonaEvidenceHarness: XCTestCase {
    // EXAMPLE METADATA ONLY: invented titles and artists, not real catalog tracks.
    static let tracks: [(String, String)] = [
        ("Golden Hour Drive", "The Velvet Lanterns"),
        ("Paper Planes Over Lisbon", "Mara Quinn"),
        ("Slow Burn (Remastered 2011)", "Northbound Echo"),
        ("Neon Tide", "Kaito & The Satellites"),
        ("Somewhere Warm (feat. Lila Ray)", "June Harbor"),
        ("Midnight Ferry", "The Hollow Pines"),
        ("Rather Stay (Clean Mix)", "Odessa Bloom"),
        ("Brick Lane Sunday", "Felix Arden"),
        ("Static Hearts [Explicit]", "Ruby Vale"),
        ("Ocean Avenue (Live 2014)", "Coastline Radio"),
        ("Low Light", "Sable & Stone"),
        ("Carry Me Home", "Ada Wren"),
    ]
    static let baseSeed: UInt64 = 0x4543_484F   // "ECHO"
    static let sessions = 600
    static let hours = [8, 14, 19, 23]           // one per day part, cycled by session

    struct Row { var session: Int; var hour: Int; var b: DJBreak }

    /// Session `s`: the example list rotated by `s`, cycled to `length` songs (12: each song once).
    static func queue(_ s: Int, length: Int = tracks.count) -> [DJTrack] {
        let r = s % tracks.count   // rotate so every pair of neighbours appears
        return (0..<length).map { i in
            let t = tracks[(i + r) % tracks.count]
            return DJTrack(id: "ex-\((i + r) % tracks.count)", title: t.0, artist: t.1, origin: .catalog)
        }
    }

    /// Same cadence `DJBreakSession` builds: `station.active.cadence(base: DJCadence())`.
    static func cadence(_ p: DJPersonality) -> DJCadence {
        StationConfiguration(personality: p).cadence(base: DJCadence())
    }

    static func whole(_ b: DJBreak) -> Double { DJScriptWriter.wholeSeconds(b) }
    static func key(_ t: String) -> String { RecentSpokenTemplates.textKey(t) }
    static func shapeName(_ b: DJBreak) -> String { b.shape?.rawValue ?? "greeting (classic planner)" }
    static func p95(_ xs: [Double]) -> Double {
        let s = xs.sorted(); return s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
    }
    static func f(_ x: Double) -> String { String(format: "%.1f", x) }

    func testPersonaEvidence() throws {
        var out = "<!-- generated by PersonaEvidenceHarness -->\n"
        for p in DJPersonality.allCases { out += Self.report(p, length: tracks12, samples: 8) }
        out += "\n# Supplementary: 600 sessions x 60 songs (the 12 example tracks cycled 5 times)\n"
        for p in DJPersonality.allCases { out += Self.report(p, length: 60, samples: 0) }
        let path = ProcessInfo.processInfo.environment["PERSONA_OUT"] ?? "/tmp/persona-evidence.md"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
        print(out)
    }
    let tracks12 = PersonaEvidenceHarness.tracks.count

    static func report(_ p: DJPersonality, length: Int, samples sampleCount: Int) -> String {
        var out = ""
        let window = DJBreakShapeConfig.natural.recentBreakWindow, hereWindow = DJBreakShapeConfig.natural.hereWindow
        do {
            let c = Self.cadence(p)
            var boundaries = 0, breaksN = 0, maxCues = 0
            var shapes: [String: Int] = [:]
            var wholes: [Double] = [], mains: [Double] = [], closings: [Double] = []
            var overOrdinary = 0, overMain = 0, overClosing = 0
            var identical = 0, phrase = 0, firstWord = 0, hereViol = 0, hereWindows = 0, linesN = 0
            var skippedOverCap = 0
            var samples: [Row] = []
            for s in 0..<Self.sessions {
                let q = Self.queue(s, length: length)
                boundaries += q.count - 1
                var w = DJScriptWriter(cadence: c, seed: Self.baseSeed &+ UInt64(s),
                                       stationName: DJScriptWriter.builtInStationName,
                                       tone: EditorialTone.forPersonality(p), shapes: .natural)
                let plan = w.plan(tracks: q, briefing: nil, hour: Self.hours[s % Self.hours.count])
                skippedOverCap += plan.ordinaryCapReport.skippedOverCap.count
                let bs = plan.breaks
                breaksN += bs.count
                for (i, b) in bs.enumerated() {
                    // Samples, in seed order: the first break of each shape, then the earliest others up to `sampleCount`.
                    if sampleCount > 0, s < 40 { samples.append(Row(session: s, hour: Self.hours[s % Self.hours.count], b: b)) }
                    shapes[Self.shapeName(b), default: 0] += 1
                    maxCues = max(maxCues, b.cues.count)
                    wholes.append(Self.whole(b)); mains.append(b.mainSeconds); closings.append(b.closingSeconds)
                    if Self.whole(b) > Double(c.maxOrdinaryBreakSeconds) { overOrdinary += 1 }
                    if b.mainSeconds > Double(c.maxTransitionSeconds) { overMain += 1 }
                    if b.closingSeconds > Double(c.maxClosingSeconds) { overClosing += 1 }
                    // Repeats against the previous `window` breaks of the same session (spoken text).
                    let prior = bs[max(0, i - window)..<i].flatMap { $0.cues.map(\.text) }
                    let priorKeys = Set(prior.map(Self.key))
                    let priorPhrases = prior.reduce(into: Set<String>()) { $0.formUnion(RecentSpokenTemplates.phrases($1)) }
                    for cue in b.cues {
                        linesN += 1
                        if priorKeys.contains(Self.key(cue.text)) { identical += 1 }
                        else if !RecentSpokenTemplates.phrases(cue.text).isDisjoint(with: priorPhrases) { phrase += 1 }
                    }
                    if i > 0, let a = bs[i - 1].cues.first, let o = b.cues.first,
                       RecentSpokenTemplates.firstWord(a.text) == RecentSpokenTemplates.firstWord(o.text) { firstWord += 1 }
                }
                // "Here's": more than one line starting "Here's" in any `hereWindow` consecutive breaks.
                if bs.count > 0 {
                    for start in 0..<max(1, bs.count - hereWindow + 1) {
                        hereWindows += 1
                        let n = bs[start..<min(bs.count, start + hereWindow)].flatMap(\.cues)
                            .filter { RecentSpokenTemplates.startsWithHere($0.text) }.count
                        if n > 1 { hereViol += 1 }
                    }
                }
            }
            out += "\n## \(p.rawValue) (\(length)-song sessions)\n\n"
            out += "cadence: talkFraction \(c.talkFraction), minSongsBetweenBreaks \(c.minSongsBetweenBreaks), maxTransitionSeconds \(c.maxTransitionSeconds), maxOrdinaryBreakSeconds \(c.maxOrdinaryBreakSeconds), maxClosingSeconds \(c.maxClosingSeconds), expectedTalkShare \(Self.f(c.expectedTalkShare * 100))%\n\n"
            if sampleCount > 0 {
                out += "### Samples\n\n"
                var seen = Set<String>(), picked: [Int] = []
                for (i, r) in samples.enumerated() where seen.insert(Self.shapeName(r.b)).inserted { picked.append(i) }
                for i in samples.indices where picked.count < sampleCount && !picked.contains(i) { picked.append(i) }
                samples = picked.prefix(sampleCount).sorted().map { samples[$0] }
            }
            for r in samples {
                out += "- session \(r.session), hour \(r.hour), after track \(r.b.afterTrack), shape `\(Self.shapeName(r.b))`, est. \(Self.f(Self.whole(r.b))) s (main \(Self.f(r.b.mainSeconds)) s, talk-over closing \(Self.f(r.b.closingSeconds)) s)\n"
                for cue in r.b.cues { out += "  - \"\(cue.text)\" (\(Int(cue.plannedSeconds)) s)\n" }
            }
            out += "\n### Stats\n\n"
            out += "sessions \(Self.sessions), boundaries \(boundaries), breaks \(breaksN), speech share \(Self.f(Double(breaksN) / Double(boundaries) * 100))%\n"
            let natural = breaksN - (shapes["greeting (classic planner)"] ?? 0)
            out += "natural-shape breaks \(natural); combined share of natural \(Self.f(Double(shapes["combined"] ?? 0) / Double(max(1, natural)) * 100))%\n"
            out += "shapes: " + shapes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value) (\(Self.f(Double($0.value) / Double(breaksN) * 100))%)" }.joined(separator: ", ") + "\n"
            out += "whole est.: max \(Self.f(wholes.max() ?? 0)) s, p95 \(Self.f(Self.p95(wholes))) s, over \(c.maxOrdinaryBreakSeconds) s: \(overOrdinary)\n"
            out += "main est.: max \(Self.f(mains.max() ?? 0)) s, p95 \(Self.f(Self.p95(mains))) s, over \(c.maxTransitionSeconds) s: \(overMain)\n"
            out += "talk-over closing est.: max \(Self.f(closings.max() ?? 0)) s, over \(c.maxClosingSeconds) s: \(overClosing)\n"
            out += "max cues per break: \(maxCues); boundaries skipped over cap: \(skippedOverCap)\n"
            out += "lines \(linesN); identical-line repeats in window \(window): \(identical); shared-phrase repeats: \(phrase)\n"
            out += "opener first-word repeats (consecutive breaks): \(firstWord) of \(breaksN - Self.sessions) consecutive pairs\n"
            out += "Here's violations: \(hereViol) of \(hereWindows) \(hereWindow)-break windows\n"
        }
        return out
    }
}
```

## Limits

- **The persona is not live on air yet.** `DJBreakSession` still builds its writer without a tone, so every station speaks warm. Personas reach listeners only after Fry adds `tone: .forPersonality(station.active.personality)` in `DJBreakSession`. That's a single-writer file, and this PR doesn't touch it.
- **Durations are word-rate estimates** (150 wpm, rounded up per line), not measured audio. Rendered audio can be longer or shorter. At air time, the measured-audio trim (`DJBreakPreparer`, `optionalCueIDs`) is what enforces the caps.
- **Naturalness and pronunciation are NOT TESTED.** There's no listening evidence for any persona or voice.
- **This is not device evidence.** It's planner output from `swift test` on Linux, with no app, MusicKit, TTS or device involved.
- The metadata is invented, there's no briefing content, the time-check shape is off, and the repeat checks look at spoken text only.
