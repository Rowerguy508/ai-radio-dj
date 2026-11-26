import XCTest
@testable import AeroDJCore

/// #196 template wiring (-Fry): the session's tone is the personality's bank hosted by the
/// station's resolved host language. Dark by default: the default preference, or any preference
/// with no installed Spanish voice, plans byte for byte what it planned before.
private struct WiringVoice: VoiceProvider {
    func synthesize(_ text: String, voice: VoiceProfile, context: RequestContext) async throws -> VoiceArtifact {
        let words = SpeechDelivery.plainText(fromSSML: text).split(separator: " ").count
        return VoiceArtifact(data: Data(text.utf8), durationSeconds: Double(words) * 0.4,
                             billableUnits: 0, provider: "device", cacheKey: nil)
    }
}

@MainActor
final class LatinHostWiringTests: XCTestCase {
    private static let allStyles = Set(SpanishVoiceStyle.allCases)
    private static let genreTags: [[String]] = [[], ["rock"]] + LatinGenre.allCases.map { [$0.rawValue] }

    private func session(_ config: StationConfiguration, styles: Set<SpanishVoiceStyle>?,
                         seed: UInt64 = 11) async -> DJBreakSession {
        let station = StationConfigurationModel(
            store: InMemoryStationConfigurationStore(snapshot: .init(state: .init(active: config))),
            consent: StaticIntegrationConsent([:]))
        await station.load()
        let renderer = VoiceRenderer(routes: [VoiceRoute(providerID: "device", provider: WiringVoice(), voice: djVoice)],
                                     budget: VoiceBudget(dailyCapMicrodollars: 0), cache: InMemoryAudioCache())
        let preparer = DJBreakPreparer(renderer: renderer, userID: "u", stationID: "s", cadence: config.cadence())
        if let styles {
            return DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed,
                                  hour: { 14 }, spanishVoiceStyles: styles)
        }
        return DJBreakSession(preparer: preparer, station: station, dj: DJPresentationStore(), seed: seed, hour: { 14 })
    }

    /// Every planned cue, in boundary order, as its boundary and text (cue ids are random UUIDs).
    private func plan(_ s: DJBreakSession) -> [String] {
        s.testPlannedBreaks.sorted { $0.key < $1.key }.flatMap { k, b in b.cues.map { "\(k)|\($0.isContent)|\($0.text)" } }
    }

    func testAnEnglishHostReturnsEveryToneUnchanged() {
        let spanishNoVoice = DJHostLanguageResolver.resolve(.init(language: .spanish, spanglish: .conversational),
                                                            availableStyles: [])
        let english = DJHostLanguageResolver.resolve(.default, availableStyles: Self.allStyles)
        XCTAssertFalse(english.speaksSpanish)
        XCTAssertFalse(spanishNoVoice.speaksSpanish)
        for p in DJPersonality.allCases {
            for genre in [nil] + LatinGenre.allCases.map(Optional.some) {
                XCTAssertEqual(EditorialTone.forPersonality(p).hosted(by: english, genre: genre), .forPersonality(p))
                XCTAssertEqual(EditorialTone.forPersonality(p).hosted(by: spanishNoVoice, genre: genre), .forPersonality(p))
            }
        }
    }

    func testTheDefaultPreferenceKeepsEachStationsPersonalityTone() {
        for p in DJPersonality.allCases {
            for tags in Self.genreTags {
                for styles in [Set<SpanishVoiceStyle>(), Self.allStyles] {
                    let config = StationConfiguration(genres: tags, personality: p)
                    XCTAssertEqual(EditorialTone.forStation(config, spanishVoiceStyles: styles), .forPersonality(p),
                                   "\(p) \(tags) \(styles)")
                }
            }
        }
    }

    /// The proof Orion asked for: today's session (no styles passed, default preference) and a
    /// session with every Spanish voice but the default preference plan the same cues, byte for
    /// byte. So does a Spanish preference while no Spanish voice is installed (today's devices).
    func testDefaultOutputIsByteIdentical() async {
        for p in DJPersonality.allCases {
            for tags in [[], ["salsa"], ["bachata", "pop"]] {
                let base = StationConfiguration(genres: tags, personality: p, commentary: .frequent)
                var spanish = base
                spanish.hostLanguage = .init(language: .spanish, spanglish: .light, voiceStyle: .caribbean)
                let today = await session(base, styles: nil)
                let withVoices = await session(base, styles: Self.allStyles)
                let noVoice = await session(spanish, styles: [])
                for s in [today, withVoices, noVoice] { await s.queueStarted(djTracks(40)) }
                let reference = plan(today)
                XCTAssertFalse(reference.isEmpty, "\(p) \(tags): breaks planned")
                XCTAssertEqual(today.testWriterTone, .forPersonality(p))
                XCTAssertEqual(plan(withVoices), reference, "\(p) \(tags): default preference with voices")
                XCTAssertEqual(plan(noVoice), reference, "\(p) \(tags): Spanish preference, no Spanish voice")
                for s in [today, withVoices, noVoice] { await s.stop() }
            }
        }
    }

    func testASpanishHostSwapsOnlyTheClosingPool() {
        let host = DJHostLanguageResolver.resolve(.init(language: .spanish), availableStyles: Self.allStyles)
        for p in DJPersonality.allCases {
            let base = EditorialTone.forPersonality(p)
            let hosted = base.hosted(by: host, genre: .salsa)
            XCTAssertEqual(hosted.closing, LatinHostCopy.closingPool(host: host, genre: .salsa).map(\.text))
            XCTAssertFalse(hosted.closing.isEmpty)
            XCTAssertEqual(hosted.combined, [], "English combined lines are dropped; the shape falls back to closing")
            var rest = hosted
            rest.closing = base.closing
            rest.combined = base.combined
            XCTAssertEqual(rest, base, "\(p): every other pool is the personality's own")
        }
    }

    func testASessionWithASpanishVoiceClosesFromTheLatinPool() async {
        var config = StationConfiguration(genres: ["salsa"], commentary: .frequent)
        config.hostLanguage = .init(language: .spanish)
        let s = await session(config, styles: [.neutralLatinAmerican])
        let host = DJHostLanguageResolver.resolve(config.hostLanguage, availableStyles: [.neutralLatinAmerican])
        XCTAssertEqual(s.testWriterTone, EditorialTone.warm.hosted(by: host, genre: .salsa))
        XCTAssertNotEqual(s.testWriterTone, .warm)
        await s.queueStarted(djTracks(40))
        let openings = s.testWriterTone.closing.map { String($0.prefix { $0 != "{" }) }.filter { $0.count > 3 }
        XCTAssertTrue(plan(s).contains { cue in openings.contains { cue.contains("|" + $0) } },
                      "a planned break closes with a Latin host line")
        await s.stop()
    }
}
