import Foundation

// #200 (-Echo): local news from GDELT DOC 2.0 ArtList results, network-free parts. The network
// provider itself (`GDELTNewsProvider`) is compiled only into the tester build; everything here is
// pure and tested on Linux.
//
// Owner decision (Nov 3, 2026): GDELT DOC 2.0, free, TESTERS ONLY, behind `NewsProvider`, swappable
// before any public launch. GDELT's terms: "any use or redistribution of the data must include a
// citation to the GDELT Project and a link to this website (https://www.gdeltproject.org/)."
//
// What leaves the device: a city or region NAME in the query ("Saint Paul", "Minnesota"), never a
// coordinate, ZIP or street. Fallback ladder: city → region/state → quiet (count-only omitted).
// Only recent (inside the fact expiry), English, in-country items from a nameable outlet that are
// on topic for the place are kept; odd items are never aired.

/// One ArtList result. Only these fields are read.
public struct GDELTArticle: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    /// "20261103T221500Z" (UTC).
    public var seendate: String
    public var domain: String
    public var language: String
    public var sourcecountry: String

    public init(url: String, title: String, seendate: String, domain: String, language: String, sourcecountry: String) {
        self.url = url
        self.title = title
        self.seendate = seendate
        self.domain = domain
        self.language = language
        self.sourcecountry = sourcecountry
    }

    public var seen: Date? { GDELTArticleList.parseDate(seendate) }
}

public enum GDELTArticleList {
    private struct Body: Decodable { var articles: [GDELTArticle]? }

    /// Articles, `[]` for GDELT's empty `{}`, or nil for anything else (its plain-text rate-limit
    /// notice, HTML, truncated JSON). Malformed items are skipped, never repaired.
    public static func parse(_ data: Data) -> [GDELTArticle]? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return body.articles ?? []
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: s)
    }
}

/// The two rungs that query the network. The third rung is quiet.
public enum LocalNewsTier: String, Sendable, CaseIterable { case city, region }

/// Builds the DOC 2.0 query text from city/region names only.
public enum GDELTQuery {
    /// GDELT `sourcecountry:` names for the countries we narrow to; others are not narrowed.
    static let countries: [String: (gdelt: String, article: String)] = [
        "US": ("unitedstates", "United States"), "CA": ("canada", "Canada"), "GB": ("unitedkingdom", "United Kingdom"),
        "IE": ("ireland", "Ireland"), "AU": ("australia", "Australia"), "NZ": ("newzealand", "New Zealand"),
    ]

    /// The place name for a tier, or nil. A typed "City, ST" that was never geocoded is split here.
    public static func place(for area: LocalArea, tier: LocalNewsTier) -> String? {
        var locality = area.locality, region = area.region
        if region == nil, let l = locality, let comma = l.lastIndex(of: ",") {
            locality = String(l[..<comma]).trimmingCharacters(in: .whitespaces)
            region = String(l[l.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        let raw: String?
        switch tier {
        case .city: raw = locality
        case .region: raw = region.map { USStates.name(for: $0, country: area.countryCode ?? "US") ?? $0 }
        }
        return raw.flatMap(clean)
    }

    /// Letters, spaces, apostrophes, hyphens and periods; 2–40 characters; no digits (so never a ZIP).
    static func clean(_ raw: String) -> String? {
        let t = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (2...40).contains(t.count), t.contains(where: \.isLetter),
              t.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "-" || $0 == "." }) else { return nil }
        return t
    }

    /// `"<place>" sourcelang:english [sourcecountry:<country>]`. Nil without a usable name.
    public static func text(for area: LocalArea, tier: LocalNewsTier) -> String? {
        guard let place = place(for: area, tier: tier) else { return nil }
        var q = "\"\(place)\" sourcelang:english"
        if let c = countries[area.countryCode ?? ""] { q += " sourcecountry:\(c.gdelt)" }
        return q
    }

    /// ArtList JSON, newest first, last 12 hours. The host is added by the tester-build provider.
    public static func parameters(query: String, maxRecords: Int = 50) -> [URLQueryItem] {
        [URLQueryItem(name: "query", value: query), URLQueryItem(name: "mode", value: "ArtList"),
         URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "maxrecords", value: String(maxRecords)),
         URLQueryItem(name: "timespan", value: "12h"), URLQueryItem(name: "sort", value: "DateDesc")]
    }
}

/// Spoken outlet names by domain, with each outlet's home state (US). A domain not listed gets the
/// generic "a local outlet" only when the item is clearly about the place; otherwise it is dropped.
public enum OutletDirectory {
    public static let genericLocal = "a local outlet"

    public struct Outlet: Equatable, Sendable { public let name: String; public let state: String? }

    public static func outlet(for domain: String) -> Outlet? {
        let d = domain.lowercased().trimmingCharacters(in: .whitespaces)
        for (key, value) in table where d == key || d.hasSuffix("." + key) { return Outlet(name: value.0, state: value.1) }
        return nil
    }

    /// Press-release wires, aggregators and finance spam: never aired, even when on topic.
    public static func isBlocked(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return blocked.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    static let blocked = [
        "prnewswire.com", "globenewswire.com", "businesswire.com", "einpresswire.com", "accesswire.com",
        "newswire.com", "openpr.com", "issuewire.com", "prweb.com", "marketscreener.com", "benzinga.com",
        "financialcontent.com", "yahoo.com", "msn.com", "newsbreak.com", "ground.news", "dailymail.co.uk",
        "zerohedge.com", "theepochtimes.com", "breitbart.com", "infowars.com", "patriotpost.us",
    ]

    static let table: [(String, (String, String?))] = [
        ("startribune.com", ("the Star Tribune", "MN")), ("twincities.com", ("the Pioneer Press", "MN")),
        ("mprnews.org", ("MPR News", "MN")), ("kare11.com", ("KARE 11", "MN")),
        ("latimes.com", ("the Los Angeles Times", "CA")), ("sfchronicle.com", ("the San Francisco Chronicle", "CA")),
        ("sfgate.com", ("SFGATE", "CA")), ("mercurynews.com", ("the Mercury News", "CA")),
        ("sacbee.com", ("the Sacramento Bee", "CA")), ("sandiegouniontribune.com", ("the San Diego Union-Tribune", "CA")),
        ("kqed.org", ("KQED", "CA")), ("laist.com", ("LAist", "CA")),
        ("chicagotribune.com", ("the Chicago Tribune", "IL")), ("suntimes.com", ("the Chicago Sun-Times", "IL")),
        ("wbez.org", ("WBEZ", "IL")),
        ("nydailynews.com", ("the New York Daily News", "NY")), ("gothamist.com", ("Gothamist", "NY")),
        ("silive.com", ("SILive", "NY")), ("newsday.com", ("Newsday", "NY")), ("timesunion.com", ("the Times Union", "NY")),
        ("syracuse.com", ("Syracuse dot com", "NY")), ("brooklynpaper.com", ("the Brooklyn Paper", "NY")),
        ("bostonglobe.com", ("the Boston Globe", "MA")), ("wbur.org", ("WBUR", "MA")), ("masslive.com", ("MassLive", "MA")),
        ("wtop.com", ("WTOP", "DC")),
        ("inquirer.com", ("the Philadelphia Inquirer", "PA")), ("post-gazette.com", ("the Pittsburgh Post-Gazette", "PA")),
        ("pennlive.com", ("PennLive", "PA")), ("whyy.org", ("WHYY", "PA")),
        ("nj.com", ("NJ dot com", "NJ")), ("northjersey.com", ("NorthJersey dot com", "NJ")),
        ("seattletimes.com", ("the Seattle Times", "WA")), ("kuow.org", ("KUOW", "WA")),
        ("oregonlive.com", ("the Oregonian", "OR")), ("opb.org", ("OPB", "OR")),
        ("denverpost.com", ("the Denver Post", "CO")), ("cpr.org", ("Colorado Public Radio", "CO")),
        ("azcentral.com", ("the Arizona Republic", "AZ")),
        ("houstonchronicle.com", ("the Houston Chronicle", "TX")), ("dallasnews.com", ("the Dallas Morning News", "TX")),
        ("statesman.com", ("the Austin American-Statesman", "TX")), ("expressnews.com", ("the San Antonio Express-News", "TX")),
        ("texastribune.org", ("the Texas Tribune", "TX")), ("kut.org", ("KUT", "TX")),
        ("star-telegram.com", ("the Fort Worth Star-Telegram", "TX")),
        ("miamiherald.com", ("the Miami Herald", "FL")), ("tampabay.com", ("the Tampa Bay Times", "FL")),
        ("orlandosentinel.com", ("the Orlando Sentinel", "FL")), ("sun-sentinel.com", ("the Sun Sentinel", "FL")),
        ("ajc.com", ("the Atlanta Journal-Constitution", "GA")),
        ("charlotteobserver.com", ("the Charlotte Observer", "NC")), ("newsobserver.com", ("the News and Observer", "NC")),
        ("tennessean.com", ("the Tennessean", "TN")),
        ("freep.com", ("the Detroit Free Press", "MI")), ("detroitnews.com", ("the Detroit News", "MI")),
        ("mlive.com", ("MLive", "MI")),
        ("cleveland.com", ("Cleveland dot com", "OH")), ("dispatch.com", ("the Columbus Dispatch", "OH")),
        ("cincinnati.com", ("the Cincinnati Enquirer", "OH")),
        ("jsonline.com", ("the Milwaukee Journal Sentinel", "WI")),
        ("stltoday.com", ("the St. Louis Post-Dispatch", "MO")), ("kansascity.com", ("the Kansas City Star", "MO")),
        ("nola.com", ("NOLA dot com", "LA")), ("baltimoresun.com", ("the Baltimore Sun", "MD")),
        ("courant.com", ("the Hartford Courant", "CT")), ("indystar.com", ("IndyStar", "IN")),
        ("courier-journal.com", ("the Courier Journal", "KY")), ("reviewjournal.com", ("the Las Vegas Review-Journal", "NV")),
        ("sltrib.com", ("the Salt Lake Tribune", "UT")), ("oklahoman.com", ("the Oklahoman", "OK")),
        ("desmoinesregister.com", ("the Des Moines Register", "IA")), ("omaha.com", ("the Omaha World-Herald", "NE")),
        ("abqjournal.com", ("the Albuquerque Journal", "NM")), ("staradvertiser.com", ("the Honolulu Star-Advertiser", "HI")),
        ("adn.com", ("the Anchorage Daily News", "AK")),
        ("patch.com", ("Patch", nil)),
    ]
}

/// US state codes to names (region rung, and outlet home-state relevance).
public enum USStates {
    public static func name(for region: String, country: String) -> String? {
        guard country.uppercased() == "US" else { return nil }
        let r = region.trimmingCharacters(in: .whitespaces)
        if let n = names[r.uppercased()] { return n }
        return names.values.first { $0.caseInsensitiveCompare(r) == .orderedSame }
    }

    public static func code(for region: String) -> String? {
        let r = region.trimmingCharacters(in: .whitespaces)
        if names[r.uppercased()] != nil { return r.uppercased() }
        return names.first { $0.value.caseInsensitiveCompare(r) == .orderedSame }?.key
    }

    static let names: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "DC": "Washington, D.C.", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan",
        "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York", "NC": "North Carolina",
        "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
        "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas",
        "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming",
    ]
}

/// Picks the items worth airing from one rung's results. Pure: tested with fixtures on Linux.
public struct LocalNewsSelector: Sendable {
    /// A local story is true enough to air for this long after GDELT saw it.
    public var validity: TimeInterval = 6 * 3600
    /// Fewer qualifying items than this is thin coverage: try the next rung.
    public var minimumItems = 2
    public var maxItems = 3
    public init() {}

    public struct Pick: Equatable, Sendable {
        public let article: GDELTArticle
        public let outlet: String
        public let observedAt: Date
        public let expiresAt: Date
    }

    /// Why items were not kept (count-only diag).
    public struct Counts: Equatable, Sendable {
        public var received = 0, stale = 0, notEnglish = 0, otherCountry = 0, blocked = 0, offTopic = 0
        public var unnamedOutlet = 0, oddTitle = 0, duplicate = 0, kept = 0
        public init() {}
    }

    public func select(_ articles: [GDELTArticle], area: LocalArea, tier: LocalNewsTier, now: Date,
                       counts: inout Counts) -> [Pick] {
        counts.received += articles.count
        guard let place = GDELTQuery.place(for: area, tier: tier) else { return [] }
        let regionCode = GDELTQuery.place(for: area, tier: .region).flatMap(USStates.code(for:))
        let country = GDELTQuery.countries[area.countryCode ?? ""]?.article
        var seen = Set<String>(), picks: [Pick] = []
        for a in articles {
            guard let observed = a.seen, observed <= now.addingTimeInterval(300),
                  observed.addingTimeInterval(validity) > now else { counts.stale += 1; continue }
            guard a.language.caseInsensitiveCompare("English") == .orderedSame else { counts.notEnglish += 1; continue }
            if let country, a.sourcecountry.caseInsensitiveCompare(country) != .orderedSame { counts.otherCountry += 1; continue }
            guard !OutletDirectory.isBlocked(a.domain) else { counts.blocked += 1; continue }
            let title = a.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let words = title.split(separator: " ").count
            guard (4...30).contains(words), title.rangeOfCharacter(from: .letters) != nil,
                  title != title.uppercased(), !title.contains(where: { "{}<>|\n\r".contains($0) }),
                  !PromptInjectionSanitizer().isSuspicious(title) else { counts.oddTitle += 1; continue }
            let mentions = Self.mentions(title, place)
            let known = OutletDirectory.outlet(for: a.domain)
            let homeState = known?.state != nil && known?.state == regionCode
            // On topic: the title names the place, or a known outlet of the listener's state ran it.
            guard mentions || homeState else { counts.offTopic += 1; continue }
            // A nameable outlet, or the generic name only for an on-topic, in-country item.
            let outlet: String
            if let known { outlet = known.name }
            else if mentions, country != nil { outlet = OutletDirectory.genericLocal }
            else { counts.unnamedOutlet += 1; continue }
            guard seen.insert(title.lowercased()).inserted else { counts.duplicate += 1; continue }
            picks.append(Pick(article: a, outlet: outlet, observedAt: observed, expiresAt: observed.addingTimeInterval(validity)))
        }
        guard picks.count >= minimumItems else { return [] }
        counts.kept += min(picks.count, maxItems)
        return Array(picks.prefix(maxItems))
    }

    static func mentions(_ title: String, _ place: String) -> Bool {
        func tokens(_ s: String) -> String {
            String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
                .split(separator: " ").joined(separator: " ")
        }
        let p = tokens(place)
        return !p.isEmpty && (" " + tokens(title) + " ").contains(" " + p + " ")
    }

    /// Facts for picks. Attribution names the outlet aloud; the GDELT citation and link are shown in
    /// the app (`legalURL`).
    public static func facts(_ picks: [Pick]) -> [BroadcastFact] {
        picks.map {
            BroadcastFact(kind: .localNews, payload: .headline(HeadlineFact(headline: $0.article.title, outlet: $0.outlet)),
                          observedAt: $0.observedAt, expiresAt: $0.expiresAt,
                          attribution: .gdelt(outlet: $0.outlet), sourceItemID: $0.article.url)
        }
    }
}

extension FactAttribution {
    /// GDELT's provider code. Every line built from GDELT data, national or local, carries it in
    /// its provenance, and the player shows the citation for it (`FactAttributionMark`, #410).
    public static let gdeltProviderID = "gdelt"
    public static let gdeltCitation = "Local news data: The GDELT Project (gdeltproject.org)"
    public static let gdeltURL = URL(string: "https://www.gdeltproject.org/")!
    public static func gdelt(outlet: String) -> FactAttribution {
        FactAttribution(providerID: gdeltProviderID, spokenName: outlet, requiresSpokenCredit: true, legalURL: gdeltURL)
    }
}

/// Count-only diagnostics of one local-news fetch. Never query text, place or titles.
public struct LocalNewsDiag: Equatable, Sendable {
    public enum Code: String, Sendable {
        case ok, thin, rateLimited, http, timeout, parse, transport, noPlace, notTesterBuild
    }
    public var tier: LocalNewsTier?
    public var code: Code
    public var httpStatus: Int?
    public var received = 0
    public var kept = 0
    public init(tier: LocalNewsTier?, code: Code, httpStatus: Int? = nil, received: Int = 0, kept: Int = 0) {
        self.tier = tier
        self.code = code
        self.httpStatus = httpStatus
        self.received = received
        self.kept = kept
    }
}
