import Foundation

/// Tunables for a briefing. Defaults follow #21: up to 6 item segments and at
/// most 150 spoken seconds inside a ~5 minute experience.
public struct MorningBriefingConfiguration: Equatable, Sendable {
    public var experienceSeconds: Int
    public var maxSpokenSeconds: Int
    public var maxItemSegments: Int
    public var maxDetailWords: Int
    /// Calendar events further ahead than this are left out.
    public var eventHorizon: TimeInterval

    public init(experienceSeconds: Int = 300, maxSpokenSeconds: Int = 150, maxItemSegments: Int = 6,
                maxDetailWords: Int = 25, eventHorizon: TimeInterval = 12 * 3600) {
        self.experienceSeconds = experienceSeconds
        self.maxSpokenSeconds = maxSpokenSeconds
        self.maxItemSegments = maxItemSegments
        self.maxDetailWords = maxDetailWords
        self.eventHorizon = eventHorizon
    }
}

/// Why an item did not make it into the briefing.
public enum BriefingExclusion: String, Error, Codable, Sendable {
    case notNarratable, duplicate, emptyContent, pastEvent, outsideHorizon, overBudget, segmentCap
    /// Instruction-like text (#44): held back until the user re-confirms it.
    case flaggedForReview
}

/// One spoken segment. Text is templated from the item's own fields only;
/// `title`, `detail` and `timePhrase` are kept separately so a later voice or
/// LLM layer can restyle without re-reading the source item.
public struct BriefingScriptSegment: Identifiable, Codable, Equatable, Sendable {
    /// Declared in priority order.
    public enum Kind: Int, Codable, Comparable, Sendable {
        case opener, upcomingEvent, dueTask, followUp, note, fallback, closer
        /// DJ talk between songs (no personal content).
        case transition
        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let id: UUID
    public let kind: Kind
    public let text: String
    public let title: String?
    public let detail: String?
    public let timePhrase: String?
    public let sourceItemID: UUID?
    public let source: ContextSourceKind?
    public let provenance: String?
    public let estimatedSpokenSeconds: Int

    func replacingText(_ newText: String) -> BriefingScriptSegment {
        BriefingScriptSegment(id: id, kind: kind, text: newText, title: title, detail: detail,
                              timePhrase: timePhrase, sourceItemID: sourceItemID, source: source,
                              provenance: provenance,
                              estimatedSpokenSeconds: DefaultBriefingPlanner.estimatedSpokenSeconds(for: newText))
    }
}

/// Speech and music in air order.
public enum RundownEntry: Codable, Equatable, Sendable {
    case speech(segmentID: UUID, seconds: Int)
    /// `seconds` is an estimated minimum, never a cut point (see `rundown`).
    case music(slot: Int, seconds: Int)
}

public struct BriefingScript: Equatable, Sendable {
    public let segments: [BriefingScriptSegment]
    public let excluded: [UUID: BriefingExclusion]
    public let unavailableSources: [ContextSourceKind]
    public let experienceSeconds: Int

    public var estimatedSpokenSeconds: Int { segments.reduce(0) { $0 + $1.estimatedSpokenSeconds } }
    public var isEmpty: Bool { !segments.contains { $0.sourceItemID != nil } }

    /// Opener, first item, then a music slot between each later item; the
    /// closer follows the last item. Music fills the rest of the experience.
    ///
    /// **Estimates, not playback control.** Speech seconds are word-count
    /// estimates and each `.music` value is a *minimum* target. The scheduler
    /// plays whole tracks and inserts speech only at track boundaries, so the
    /// show runs approximately `experienceSeconds` and may run longer; it must
    /// never trim or skip protected music to hit these numbers, and any UI
    /// must label durations as estimated.
    public var rundown: [RundownEntry] {
        var blocks: [[BriefingScriptSegment]] = []
        for segment in segments {
            if blocks.isEmpty || (segment.sourceItemID != nil && blocks.last!.contains { $0.sourceItemID != nil }) {
                blocks.append([segment])
            } else {
                blocks[blocks.count - 1].append(segment)
            }
        }
        let slots = max(1, blocks.count - 1)
        let music = max(0, experienceSeconds - estimatedSpokenSeconds)
        var entries: [RundownEntry] = []
        var slot = 0
        for (index, block) in blocks.enumerated() {
            entries += block.map { .speech(segmentID: $0.id, seconds: $0.estimatedSpokenSeconds) }
            if index < blocks.count - 1 || blocks.count == 1, music > 0 {
                let seconds = music / slots + (slot == slots - 1 ? music % slots : 0)
                entries.append(.music(slot: slot, seconds: seconds))
                slot += 1
            }
        }
        return entries
    }

    /// Bridge to #27's `BriefingPlan` (and so to `BroadcastScheduler`).
    public var plan: BriefingPlan {
        BriefingPlan(segments: segments.map {
            BriefingSegment(id: $0.id, text: $0.text, sourceItemID: $0.sourceItemID,
                            estimatedSpokenSeconds: $0.estimatedSpokenSeconds)
        }, targetSpokenSeconds: estimatedSpokenSeconds)
    }
}

/// Rules-first, deterministic briefing builder. No network, no LLM, no secrets.
/// Clock, calendar and time zone are injected so output is reproducible.
public struct MorningBriefingEngine: BriefingPlanner {
    static let openerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let closerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let fallbackID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    public let configuration: MorningBriefingConfiguration
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(configuration: MorningBriefingConfiguration = .init(), calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.calendar = calendar
        self.now = now
    }

    /// Fetches from each source; a failing source is reported, not fatal.
    public func collect(from sources: [any ContextSource]) async -> (items: [ContextItem], unavailable: [ContextSourceKind]) {
        var items: [ContextItem] = []
        var unavailable: [ContextSourceKind] = []
        for source in sources {
            do { items += try await source.fetchItems() } catch { unavailable.append(source.source) }
        }
        return (items, unavailable)
    }

    /// Collects, applies persisted "read anyway" reconfirmations from sources
    /// that keep them (the share inbox), and scripts in one step.
    public func briefing(from sources: [any ContextSource], maxSpokenSeconds: Int? = nil) async -> BriefingScript {
        let collected = await collect(from: sources)
        var reconfirmed: Set<UUID> = []
        for case let source as any ReconfirmationProviding in sources { reconfirmed.formUnion(await source.reconfirmedItemIDs) }
        return script(from: collected.items, unavailableSources: collected.unavailable,
                      maxSpokenSeconds: maxSpokenSeconds, reconfirmed: reconfirmed)
    }

    /// Every item passes through `PromptInjectionSanitizer` first: text is
    /// cleaned for speech (no URLs/markup/invisible characters), and
    /// instruction-like items are held back unless their id is in
    /// `reconfirmed` (the user confirmed them again on the review screen).
    public func script(from items: [ContextItem], unavailableSources: [ContextSourceKind] = [],
                       maxSpokenSeconds: Int? = nil, reconfirmed: Set<UUID> = []) -> BriefingScript {
        let current = now()
        let sanitizer = PromptInjectionSanitizer()
        var excluded: [UUID: BriefingExclusion] = [:]
        var seen: Set<String> = []
        var candidates: [BriefingScriptSegment] = []
        for original in items {
            guard original.isNarratable(at: current) else { excluded[original.id] = .notNarratable; continue }
            let item = sanitizer.sanitized(original, reconfirmed: reconfirmed)
            guard item.isNarratable(at: current) else { excluded[item.id] = .flaggedForReview; continue }
            guard seen.insert(item.provenance).inserted else { excluded[item.id] = .duplicate; continue }
            switch segment(for: item, now: current) {
            case .success(let segment): candidates.append(segment)
            case .failure(let reason): excluded[item.id] = reason
            }
        }
        let order = Dictionary(items.map { ($0.id, ($0.eventAt ?? $0.createdAt, $0.createdAt)) }) { first, _ in first }
        candidates.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            let l = order[lhs.sourceItemID!]!, r = order[rhs.sourceItemID!]!
            if l.0 != r.0 { return l.0 < r.0 }
            if l.1 != r.1 { return l.1 < r.1 }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let degraded = unavailableSources.isEmpty ? "" : " Some sources couldn't be reached, so this may be incomplete."
        let opener = fixed(Self.openerID, .opener, "\(greeting(at: current)). Here's your briefing.\(degraded)")
        let closer = fixed(Self.closerID, .closer, "That's your briefing. Back to the music.")
        var remaining = (maxSpokenSeconds ?? configuration.maxSpokenSeconds)
            - opener.estimatedSpokenSeconds - closer.estimatedSpokenSeconds
        var chosen: [BriefingScriptSegment] = []
        for candidate in candidates {
            if chosen.count >= configuration.maxItemSegments { excluded[candidate.sourceItemID!] = .segmentCap; continue }
            guard candidate.estimatedSpokenSeconds <= remaining else { excluded[candidate.sourceItemID!] = .overBudget; continue }
            chosen.append(candidate)
            remaining -= candidate.estimatedSpokenSeconds
        }

        let segments = chosen.isEmpty
            ? [fixed(Self.fallbackID, .fallback,
                     "\(greeting(at: current)). Nothing needs your attention right now.\(degraded) Enjoy the music.")]
            : [opener] + chosen + [closer]
        return BriefingScript(segments: segments, excluded: excluded, unavailableSources: unavailableSources,
                              experienceSeconds: configuration.experienceSeconds)
    }

    public func plan(from items: [ContextItem], targetSpokenSeconds: Int) async throws -> BriefingPlan {
        script(from: items, maxSpokenSeconds: targetSpokenSeconds).plan
    }

    // MARK: - Templates (item fields only)

    private func segment(for item: ContextItem, now: Date) -> Result<BriefingScriptSegment, BriefingExclusion> {
        let title = Self.clean(item.title)
        var detail = Self.bounded(Self.clean(item.summary), words: configuration.maxDetailWords)
        if detail.caseInsensitiveCompare(title) == .orderedSame { detail = "" }
        guard !title.isEmpty || !detail.isEmpty else { return .failure(.emptyContent) }

        let today = calendar.startOfDay(for: now)
        let kind: BriefingScriptSegment.Kind
        var phrase: String?
        if item.source == .calendar {
            // Contract with the calendar source (#18): all-day items have no
            // `eventAt`; a timed event that has started is still on while
            // `expiresAt` (its end) is in the future. Midnight is just a time.
            if let at = item.eventAt {
                if at < now {
                    guard let end = item.expiresAt, end > now else { return .failure(.pastEvent) }
                    phrase = "now"
                } else if at.timeIntervalSince(now) > configuration.eventHorizon {
                    return .failure(.outsideHorizon)
                } else {
                    phrase = (calendar.isDate(at, inSameDayAs: now) ? "at " : "tomorrow at ") + clockTime(at)
                }
            } else {
                phrase = "today"
            }
            kind = .upcomingEvent
        } else if let at = item.eventAt,
                  let dayAfter = calendar.date(byAdding: .day, value: 2, to: today), at < dayAfter {
            phrase = at < today ? "overdue" : calendar.isDate(at, inSameDayAs: now) ? "due today" : "due tomorrow"
            kind = .dueTask
        } else {
            kind = item.source == .obsidian || item.source == .calendar ? .note : .followUp
        }

        let subject = title.isEmpty ? detail : title
        let lead: String
        switch kind {
        case .upcomingEvent: lead = phrase == "now" ? "Happening now: \(subject)" : "Coming up \(phrase!): \(subject)"
        case .dueTask: lead = "\(phrase!.prefix(1).uppercased())\(phrase!.dropFirst()): \(subject)"
        case .followUp: lead = "To follow up: \(subject)"
        default: lead = "A note: \(subject)"
        }
        var text = Self.sentence(lead)
        if !title.isEmpty, !detail.isEmpty { text += " " + Self.sentence(detail) }
        text += " From \(Self.attribution(item.source))."
        return .success(BriefingScriptSegment(
            id: item.id, kind: kind, text: text, title: title.isEmpty ? nil : title,
            detail: detail.isEmpty ? nil : detail, timePhrase: phrase, sourceItemID: item.id, source: item.source,
            provenance: item.provenance, estimatedSpokenSeconds: DefaultBriefingPlanner.estimatedSpokenSeconds(for: text)))
    }

    private func fixed(_ id: UUID, _ kind: BriefingScriptSegment.Kind, _ text: String) -> BriefingScriptSegment {
        BriefingScriptSegment(id: id, kind: kind, text: text, title: nil, detail: nil, timePhrase: nil,
                              sourceItemID: nil, source: nil, provenance: nil,
                              estimatedSpokenSeconds: DefaultBriefingPlanner.estimatedSpokenSeconds(for: text))
    }

    private func greeting(at date: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        return hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
    }

    private func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.component(.minute, from: date) == 0 ? "h a" : "h:mm a"
        return formatter.string(from: date)
    }

    static func attribution(_ source: ContextSourceKind) -> String {
        switch source {
        case .calendar: "your calendar"
        case .emailShared: "an email you shared"
        case .messagesShared: "a message you shared"
        case .obsidian: "your notes"
        case .userShared: "something you shared"
        }
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func bounded(_ text: String, words: Int) -> String {
        let parts = text.split(separator: " ")
        return parts.count <= words ? text : parts.prefix(words).joined(separator: " ") + "…"
    }

    static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?…".contains(last) ? text : text + "."
    }
}

/// A source whose review screen can re-confirm items the sanitizer flags.
public protocol ReconfirmationProviding: Sendable {
    var reconfirmedItemIDs: Set<UUID> { get async }
}

extension SharedInboxReview: ReconfirmationProviding {}
