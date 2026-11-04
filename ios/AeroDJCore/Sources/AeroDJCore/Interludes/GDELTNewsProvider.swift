import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// #200 (-Echo): owner decision Nov 3, 2026: GDELT DOC 2.0 for TESTERS ONLY. The network provider
// is compiled only when `AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB`; every other build gets
// `NullFactProvider(kind: .localNews)` from `TesterLocalNews.makeProvider`, and the GDELT host
// string is absent from its binary (ios/scripts/check-release-excludes-gdelt.sh).
//
// Privacy: the request carries a city or region NAME only (`GDELTQuery`), never coordinates or a
// ZIP. Diagnostics carry tier, code, HTTP status and counts only: no query text, place or titles.
// Rate: at most one request per 5.5 s from this process (GDELT asks for one per 5 s), a 60 s
// back-off after a rate-limit reply, an 8 s timeout, a 15-minute cache. Failures are quiet:
// `.omitted(.unavailable)`, never an error on air.

/// Always compiled: the local-news provider for this build.
public enum TesterLocalNews {
    /// True only in the tester build.
    public static var isCompiledIn: Bool {
        #if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
        return true
        #else
        return false
        #endif
    }

    public static func makeProvider(transport: any HTTPTransport = URLSessionTransport(),
                                    diag: (@Sendable (LocalNewsDiag) -> Void)? = nil) -> any NewsProvider {
        #if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
        return GDELTNewsProvider(transport: transport, diag: diag)
        #else
        diag?(LocalNewsDiag(tier: nil, code: .notTesterBuild))
        return NullFactProvider(kind: .localNews)
        #endif
    }
}

#if AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB
/// One request at a time, spaced at least `minInterval` apart, with a back-off after rate limiting.
actor GDELTRateGate {
    let minInterval: TimeInterval
    let penalty: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var nextSlot = Date.distantPast
    private var blockedUntil = Date.distantPast

    init(minInterval: TimeInterval, penalty: TimeInterval, now: @escaping @Sendable () -> Date,
         sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        self.minInterval = max(5, minInterval)   // never faster than GDELT's one per 5 s
        self.penalty = penalty
        self.now = now
        self.sleep = sleep
    }

    /// False while backing off (the caller goes quiet). Otherwise waits for the next slot.
    func acquire() async -> Bool {
        let t = now()
        guard t >= blockedUntil else { return false }
        let slot = max(t, nextSlot)
        nextSlot = slot.addingTimeInterval(minInterval)
        if slot > t { await sleep(slot.timeIntervalSince(t)) }
        return true
    }

    func backOff() { blockedUntil = now().addingTimeInterval(penalty) }
}

/// Small per-query cache so repeated breaks do not refetch.
actor GDELTCache {
    private var entries: [String: (Date, [GDELTArticle])] = [:]
    func get(_ key: String, now: Date, ttl: TimeInterval) -> [GDELTArticle]? {
        guard let (at, items) = entries[key], now.timeIntervalSince(at) < ttl else { return nil }
        return items
    }
    func put(_ key: String, _ items: [GDELTArticle], at: Date) {
        if entries.count > 8 { entries.removeAll() }
        entries[key] = (at, items)
    }
}

public struct GDELTNewsProvider: NewsProvider {
    public let kind = BroadcastFactKind.localNews
    static let endpoint = "https://api.gdeltproject.org/api/v2/doc/doc"

    let transport: any HTTPTransport
    let selector: LocalNewsSelector
    let timeout: TimeInterval
    let cacheTTL: TimeInterval
    let now: @Sendable () -> Date
    let diag: (@Sendable (LocalNewsDiag) -> Void)?
    let gate: GDELTRateGate
    let cache = GDELTCache()

    public init(transport: any HTTPTransport, selector: LocalNewsSelector = LocalNewsSelector(),
                minInterval: TimeInterval = 5.5, penalty: TimeInterval = 60, timeout: TimeInterval = 8,
                cacheTTL: TimeInterval = 15 * 60, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) },
                diag: (@Sendable (LocalNewsDiag) -> Void)? = nil) {
        self.transport = transport
        self.selector = selector
        self.timeout = timeout
        self.cacheTTL = cacheTTL
        self.now = now
        self.diag = diag
        self.gate = GDELTRateGate(minInterval: minInterval, penalty: penalty, now: now, sleep: sleep)
    }

    public func facts(for request: FactRequest) async -> FactProviderResult {
        guard let area = request.area else { return .omitted(.noLocation) }
        var queried = false
        // Ladder: city, then region/state, then quiet.
        for tier in LocalNewsTier.allCases {
            guard let query = GDELTQuery.text(for: area, tier: tier) else { continue }
            queried = true
            guard let articles = await fetch(query, tier: tier) else { return .omitted(.unavailable) }
            var counts = LocalNewsSelector.Counts()
            var picks = selector.select(articles, area: area, tier: tier, now: request.now, counts: &counts)
            picks = Array(picks.prefix(max(0, request.maxFacts)))
            diag?(LocalNewsDiag(tier: tier, code: picks.isEmpty ? .thin : .ok, received: counts.received, kept: picks.count))
            if !picks.isEmpty { return .facts(LocalNewsSelector.facts(picks)) }
        }
        if !queried { diag?(LocalNewsDiag(tier: nil, code: .noPlace)) }
        return .omitted(.unavailable)
    }

    /// Articles, or nil on any failure (already reported as a code).
    func fetch(_ query: String, tier: LocalNewsTier) async -> [GDELTArticle]? {
        if let hit = await cache.get(query, now: now(), ttl: cacheTTL) { return hit }
        guard await gate.acquire() else { diag?(LocalNewsDiag(tier: tier, code: .rateLimited)); return nil }
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = GDELTQuery.parameters(query: query)
        guard let url = components.url else { diag?(LocalNewsDiag(tier: tier, code: .noPlace)); return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let outcome = await Self.race(timeout: timeout) { [transport, req] in try await transport.send(req) }
        switch outcome {
        case .timedOut:
            diag?(LocalNewsDiag(tier: tier, code: .timeout)); return nil
        case .failed:
            diag?(LocalNewsDiag(tier: tier, code: .transport)); return nil
        case .done(let data, let http):
            if http.statusCode == 429 {
                await gate.backOff(); diag?(LocalNewsDiag(tier: tier, code: .rateLimited, httpStatus: 429)); return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                diag?(LocalNewsDiag(tier: tier, code: .http, httpStatus: http.statusCode)); return nil
            }
            guard let articles = GDELTArticleList.parse(data) else {
                // GDELT's rate-limit notice is plain text with HTTP 200.
                let limited = String(decoding: data.prefix(200), as: UTF8.self).localizedCaseInsensitiveContains("limit requests")
                if limited { await gate.backOff() }
                diag?(LocalNewsDiag(tier: tier, code: limited ? .rateLimited : .parse, httpStatus: http.statusCode))
                return nil
            }
            await cache.put(query, articles, at: now())
            return articles
        }
    }

    enum Outcome: Sendable { case done(Data, HTTPURLResponse), failed, timedOut }

    static func race(timeout: TimeInterval,
                     _ op: @escaping @Sendable () async throws -> (Data, HTTPURLResponse)) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do { let (d, r) = try await op(); return .done(d, r) } catch { return .failed }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
                return .timedOut
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }
}
#endif
