import XCTest
@testable import AeroDJCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// #200 GDELT local news (testers only), paraphrase validation and the fallback ladder (-Echo).
// Fixtures only: no network.

private let now = Date(timeIntervalSince1970: 1_793_000_000)
private let saintPaul = LocalArea(locality: "Saint Paul", region: "MN", countryCode: "US",
                                  coordinate: CoarseCoordinate(latitude: 44.9537, longitude: -93.09), origin: .device)

private func seen(_ ago: TimeInterval) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: now.addingTimeInterval(-ago))
}

private func article(_ title: String, _ domain: String, ago: TimeInterval = 1800, language: String = "English",
                     country: String = "United States") -> GDELTArticle {
    GDELTArticle(url: "https://\(domain)/a/\(abs(title.hashValue))", title: title, seendate: seen(ago), domain: domain,
                 language: language, sourcecountry: country)
}

// MARK: - Paraphrase validator: adversarial fixtures

final class HeadlineParaphraseValidatorTests: XCTestCase {
    let headline = "Minneapolis City Council approves $2 million plan for Hennepin Avenue bike lanes"
    let v = HeadlineParaphraseValidator()

    private func check(_ p: String) -> Result<String, ParaphraseRejection> { v.validate(p, headline: headline) }

    func testAFaithfulRewordingPasses() {
        XCTAssertEqual(try check("Minneapolis council backs a $2 million bike lane plan on Hennepin.").get(),
                       "Minneapolis council backs a $2 million bike lane plan on Hennepin")
        XCTAssertNoThrow(try check("Minneapolis council okays $2 million Hennepin bike lane plan").get())
        XCTAssertEqual(check("A $2 million Hennepin bike lane plan wins council approval"), .failure(.newClaim),
                       "\"wins\" is a claim the headline does not make")
    }

    func testAnInventedNumberIsDropped() {
        XCTAssertEqual(check("Minneapolis council backs a $3 million bike lane plan"), .failure(.number))
        XCTAssertEqual(check("Minneapolis council backs three bike lane plans on Hennepin"), .failure(.number))
        XCTAssertEqual(check("Minneapolis backs bike lanes on Hennepin by 2027"), .failure(.number))
    }

    func testANewNameIsDropped() {
        XCTAssertEqual(check("Mayor Frey backs Minneapolis bike lane plan on Hennepin"), .failure(.properNoun))
        XCTAssertEqual(check("Minneapolis and Saint Paul council back bike lane plan"), .failure(.properNoun))
        XCTAssertEqual(check("Hennepin bike lane plan backed by Minneapolis Democrats"), .failure(.properNoun))
    }

    func testVerbatimAndNearVerbatimCopiesAreDropped() {
        XCTAssertEqual(check(headline), .failure(.verbatim))
        XCTAssertEqual(check(headline + "."), .failure(.verbatim))
        XCTAssertEqual(check("Minneapolis City Council approves $2 million plan for Hennepin bike lanes"), .failure(.sharedRun))
        XCTAssertEqual(check("City Council approves $2 million plan, Minneapolis says"), .failure(.sharedRun))
    }

    func testOverLengthAndUnderLengthAreDropped() {
        XCTAssertEqual(check("Minneapolis council backs a $2 million plan to add new bike lanes along Hennepin Avenue"),
                       .failure(.length))
        XCTAssertEqual(check("Bike lanes"), .failure(.length))
    }

    func testNewClaimsAndNegationsAreDropped() {
        XCTAssertEqual(check("Minneapolis council backs bike lanes after crash on Hennepin"), .failure(.newClaim))
        XCTAssertEqual(check("Minneapolis council backs bike lanes, police on Hennepin say"), .failure(.newClaim))
        XCTAssertEqual(check("Minneapolis council does not back Hennepin bike lanes"), .failure(.negation))
        XCTAssertEqual(check("Minneapolis council quietly rushes controversial Hennepin bike lanes"), .failure(.newClaim))
    }

    func testMarkupQuotesColonsAndModelRefusalsAreDropped() {
        XCTAssertEqual(check("NONE"), .failure(.empty))
        XCTAssertEqual(check("   "), .failure(.empty))
        XCTAssertEqual(check("Minneapolis council: \"yes\" to Hennepin bike lanes"), .failure(.characters))
        XCTAssertEqual(check("Minneapolis backs bike lanes. Hennepin Avenue gets them"), .failure(.characters))
        XCTAssertEqual(check("Minneapolis backs <b>Hennepin</b> bike lanes now"), .failure(.characters))
    }

    func testFitsTheTwelveSecondCapWithTheOutletNamed() {
        let longest = "Minneapolis council backs a $2 million bike lane plan on Hennepin"
        let line = FactInterludeComposer.newsSummary(HeadlineSummary(summary: longest, outlet: "the Minneapolis Star Tribune"))
        XCTAssertLessThanOrEqual(DefaultBriefingPlanner.estimatedSpokenSeconds(for: line?.0 ?? ""), 7)
    }

    // The summarizer drops, never repairs, and without a model (Linux, older OS) says nothing.
    private struct Canned: HeadlineParaphraser {
        let reply: String?
        func paraphrase(_ headline: String) async -> String? { reply }
    }

    private func fact(_ title: String) -> BroadcastFact {
        BroadcastFact(kind: .localNews, payload: .headline(HeadlineFact(headline: title, outlet: "the Star Tribune")),
                      observedAt: now, expiresAt: now.addingTimeInterval(3600), attribution: .gdelt(outlet: "the Star Tribune"))
    }

    func testSummarizerKeepsValidSummariesAndDropsTheRestWithCountsOnly() async {
        let good = await HeadlineSummarizer(paraphraser: Canned(reply: "Minneapolis council backs a $2 million Hennepin bike plan"))
            .summarize([fact(headline)])
        XCTAssertEqual(good.counts.kept, 1)
        guard case .headlineSummary(let s) = good.facts.first?.payload else { return XCTFail("summary") }
        XCTAssertEqual(s.outlet, "the Star Tribune")
        XCTAssertEqual(good.facts.first?.sourceItemID, nil)

        let invented = await HeadlineSummarizer(paraphraser: Canned(reply: "Minneapolis council backs a $9 million bike plan"))
            .summarize([fact(headline)])
        XCTAssertTrue(invented.facts.isEmpty)
        XCTAssertEqual(invented.counts.rejected, [.number: 1])

        let none = await HeadlineSummarizer(paraphraser: NoHeadlineParaphraser()).summarize([fact(headline)])
        XCTAssertTrue(none.facts.isEmpty, "no model: dropped, never the headline")
        XCTAssertEqual(none.counts.noModel, 1)
    }

    func testOnLinuxTheBestParaphraserIsNone() async {
        #if !canImport(FoundationModels)
        let p = HeadlineParaphrasers.best()
        let out = await p.paraphrase(headline)
        XCTAssertNil(out)
        #endif
    }
}

// MARK: - GDELT parsing, query and the fallback ladder

final class LocalNewsSelectionTests: XCTestCase {
    func testParsesArticlesEmptyAndFailsQuietlyOnText() {
        let json = """
        {"articles":[{"url":"https://www.startribune.com/x","url_mobile":"","title":"Saint Paul schools add bus routes",
        "seendate":"20261103T200000Z","socialimage":"","domain":"startribune.com","language":"English",
        "sourcecountry":"United States"}]}
        """
        XCTAssertEqual(GDELTArticleList.parse(Data(json.utf8))?.first?.domain, "startribune.com")
        XCTAssertEqual(GDELTArticleList.parse(Data("{}".utf8)), [])
        XCTAssertNil(GDELTArticleList.parse(Data("Please limit requests to one every 5 seconds".utf8)))
        XCTAssertNil(GDELTArticleList.parse(Data("{\"articles\":[".utf8)))
    }

    func testQueryCarriesOnlyACityOrRegionName() {
        XCTAssertEqual(GDELTQuery.text(for: saintPaul, tier: .city),
                       "\"Saint Paul\" sourcelang:english sourcecountry:unitedstates")
        XCTAssertEqual(GDELTQuery.text(for: saintPaul, tier: .region),
                       "\"Minnesota\" sourcelang:english sourcecountry:unitedstates")
        let typed = LocalArea(locality: "Duluth, MN", region: nil, countryCode: nil, coordinate: nil, origin: .manual)
        XCTAssertEqual(GDELTQuery.place(for: typed, tier: .city), "Duluth")
        XCTAssertEqual(GDELTQuery.place(for: typed, tier: .region), "Minnesota")
        let zip = LocalArea(locality: "55101", region: nil, countryCode: "US", coordinate: nil, origin: .manual)
        XCTAssertNil(GDELTQuery.text(for: zip, tier: .city), "a ZIP never goes out")
        for tier in LocalNewsTier.allCases {
            let items = GDELTQuery.parameters(query: GDELTQuery.text(for: saintPaul, tier: tier)!)
            let all = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
            XCTAssertFalse(all.contains("44.9") || all.contains("93.0") || all.contains("55101"), "no coordinates or ZIP")
            XCTAssertTrue(all.contains("mode=ArtList") && all.contains("format=json"))
        }
    }

    func testOutletsAreNamedFromTheDomainAndWiresAreBlocked() {
        XCTAssertEqual(OutletDirectory.outlet(for: "www.startribune.com")?.name, "the Star Tribune")
        XCTAssertEqual(OutletDirectory.outlet(for: "patch.com")?.name, "Patch")
        XCTAssertNil(OutletDirectory.outlet(for: "startribune.com.evil.example"))
        XCTAssertTrue(OutletDirectory.isBlocked("www.prnewswire.com"))
        XCTAssertTrue(OutletDirectory.isBlocked("finance.yahoo.com"))
    }

    func testCityRungKeepsRecentOnTopicNameableItemsOnly() {
        let items = [
            article("Saint Paul schools add new bus routes for winter", "startribune.com"),
            article("Minnesota lawmakers weigh transit funding plan", "mprnews.org"),           // home-state outlet
            article("Saint Paul bakery wins regional award this week", "smalltownblog.example"), // generic outlet
            article("Saint Paul old story from yesterday morning", "twincities.com", ago: 7 * 3600), // stale
            article("Saint Paul en español noticias del día hoy", "startribune.com", language: "Spanish"),
            article("Saint Paul company announces quarterly results", "prnewswire.com"),          // wire
            article("Celebrity gossip roundup for the weekend", "example-tabloid.com"),            // off topic
            article("Saint Paul schools add new bus routes for winter", "twincities.com"),       // duplicate
            article("SAINT PAUL BREAKING ALL CAPS ALERT NOW", "kare11.com"),                      // odd
        ]
        var counts = LocalNewsSelector.Counts()
        let picks = LocalNewsSelector().select(items, area: saintPaul, tier: .city, now: now, counts: &counts)
        XCTAssertEqual(picks.map(\.outlet), ["the Star Tribune", "MPR News", OutletDirectory.genericLocal])
        XCTAssertEqual(counts.stale, 1); XCTAssertEqual(counts.notEnglish, 1); XCTAssertEqual(counts.blocked, 1)
        XCTAssertEqual(counts.offTopic, 1); XCTAssertEqual(counts.duplicate, 1); XCTAssertEqual(counts.oddTitle, 1)
        for p in picks { XCTAssertEqual(p.expiresAt, p.observedAt.addingTimeInterval(6 * 3600), "nothing airs late") }
        let facts = LocalNewsSelector.facts(picks)
        XCTAssertEqual(facts.first?.attribution.providerID, "gdelt")
        XCTAssertEqual(facts.first?.attribution.legalURL, URL(string: "https://www.gdeltproject.org/"))
        XCTAssertEqual(facts.first?.kind, .localNews)
    }

    func testThinCoverageYieldsNothingSoTheLadderMovesOn() {
        var counts = LocalNewsSelector.Counts()
        let one = [article("Saint Paul schools add new bus routes for winter", "startribune.com")]
        XCTAssertTrue(LocalNewsSelector().select(one, area: saintPaul, tier: .city, now: now, counts: &counts).isEmpty)
        let unknownOffTopic = [article("Minnesota roads get new signs", "blog.example"), article("Statewide fair plans", "x.example")]
        XCTAssertTrue(LocalNewsSelector().select(unknownOffTopic, area: saintPaul, tier: .city, now: now, counts: &counts).isEmpty)
    }
}

// MARK: - Build gating (runs in check-release-disables-paid-voice.sh via the TesterVoiceBuildFlagTests filter)

private final class DiagLog: @unchecked Sendable {
    private let lock = NSLock(); private var got: [LocalNewsDiag] = []
    func add(_ d: LocalNewsDiag) { lock.withLock { got.append(d) } }
    var all: [LocalNewsDiag] { lock.withLock { got } }
}

private actor Script: HTTPTransport {
    var replies: [(Int, String)]
    var urls: [URL] = []
    var delay: UInt64 = 0
    init(_ replies: [(Int, String)], delayNanos: UInt64 = 0) { self.replies = replies; self.delay = delayNanos }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        urls.append(request.url!)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let (code, body) = replies.isEmpty ? (200, "{}") : replies.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
    func sent() -> [URL] { urls }
}

final class GDELTTesterVoiceBuildFlagTests: XCTestCase {
    func testOnlyTheTesterBuildHasTheGDELTProvider() async {
        let log = DiagLog()
        let provider = TesterLocalNews.makeProvider(transport: Script([]), diag: log.add)
        XCTAssertEqual(provider.kind, .localNews)
        #if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
        XCTAssertTrue(TesterLocalNews.isCompiledIn)
        XCTAssertTrue(provider is GDELTNewsProvider)
        #else
        XCTAssertFalse(TesterLocalNews.isCompiledIn)
        XCTAssertTrue(provider is NullFactProvider)
        let result = await provider.facts(for: FactRequest(now: now, area: saintPaul))
        XCTAssertEqual(result, .omitted(.notConfigured))
        XCTAssertEqual(log.all.map(\.code), [.notTesterBuild])
        #endif
    }

    #if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
    private func json(_ items: [GDELTArticle]) -> String {
        String(decoding: try! JSONEncoder().encode(["articles": items]), as: UTF8.self)
    }

    private final class Sleeps: @unchecked Sendable {
        private let lock = NSLock(); private var got: [TimeInterval] = []
        func add(_ t: TimeInterval) { lock.withLock { got.append(t) } }
        var all: [TimeInterval] { lock.withLock { got } }
    }

    func testCityThenRegionThenQuietWithCountOnlyDiagsAndNoLocationInTheURL() async {
        let region = json([article("Minnesota lawmakers weigh transit funding plan", "mprnews.org"),
                           article("Minnesota DNR opens new trail near Duluth", "startribune.com")])
        let script = Script([(200, "{}"), (200, region)])
        let log = DiagLog(), sleeps = Sleeps()
        let provider = GDELTNewsProvider(transport: script, now: { now }, sleep: { sleeps.add($0) }, diag: log.add)
        guard case .facts(let facts) = await provider.facts(for: FactRequest(now: now, area: saintPaul)) else {
            return XCTFail("region rung")
        }
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(log.all.map(\.code), [.thin, .ok])
        XCTAssertEqual(log.all.map(\.tier), [.city, .region])
        XCTAssertEqual(sleeps.all, [5.5], "the second request waits for the 5 s slot")
        let urls = await script.sent()
        XCTAssertEqual(urls.count, 2)
        for url in urls {
            XCTAssertEqual(url.host, "api.gdeltproject.org")
            let s = url.absoluteString.removingPercentEncoding ?? ""
            XCTAssertFalse(s.contains("44.9") || s.contains("-93") || s.contains("lat") || s.contains("55101"))
        }
        XCTAssertTrue((urls[0].absoluteString.removingPercentEncoding ?? "").contains("\"Saint Paul\""))
        XCTAssertTrue((urls[1].absoluteString.removingPercentEncoding ?? "").contains("\"Minnesota\""))

        // Thin everywhere: quiet.
        let quiet = GDELTNewsProvider(transport: Script([(200, "{}"), (200, "{}")]), now: { now }, sleep: { _ in }, diag: log.add)
        let result = await quiet.facts(for: FactRequest(now: now, area: saintPaul))
        XCTAssertEqual(result, .omitted(.unavailable))
    }

    func testRateLimitTextHTTPErrorsAndTimeoutsFailQuietlyAndBackOff() async {
        let log = DiagLog()
        let limited = GDELTNewsProvider(transport: Script([(200, "Please limit requests to one every 5 seconds")]),
                                        now: { now }, sleep: { _ in }, diag: log.add)
        let a = await limited.facts(for: FactRequest(now: now, area: saintPaul))
        XCTAssertEqual(a, .omitted(.unavailable))
        let b = await limited.facts(for: FactRequest(now: now, area: saintPaul))
        XCTAssertEqual(b, .omitted(.unavailable))
        XCTAssertEqual(log.all.map(\.code), [.rateLimited, .rateLimited], "backing off: the second call sends nothing")

        let log2 = DiagLog()
        let server = GDELTNewsProvider(transport: Script([(503, "")]), now: { now }, sleep: { _ in }, diag: log2.add)
        let c = await server.facts(for: FactRequest(now: now, area: saintPaul))
        XCTAssertEqual(c, .omitted(.unavailable))
        XCTAssertEqual(log2.all, [LocalNewsDiag(tier: .city, code: .http, httpStatus: 503)])

        let log3 = DiagLog()
        let slow = GDELTNewsProvider(transport: Script([(200, "{}")], delayNanos: 3_000_000_000), timeout: 0.2,
                                     now: { now }, sleep: { _ in }, diag: log3.add)
        let d = await slow.facts(for: FactRequest(now: now, area: saintPaul))
        XCTAssertEqual(d, .omitted(.unavailable))
        XCTAssertEqual(log3.all.map(\.code), [.timeout])
    }

    func testNoAreaMeansNoRequest() async {
        let script = Script([])
        let provider = GDELTNewsProvider(transport: script, now: { now }, sleep: { _ in })
        let r = await provider.facts(for: FactRequest(now: now, area: nil))
        XCTAssertEqual(r, .omitted(.noLocation))
        let sent = await script.sent()
        XCTAssertTrue(sent.isEmpty)
    }
    #endif
}
