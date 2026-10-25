import Foundation

/// Errors a `MarkdownDocumentReader` reports for one file or the whole selection.
public enum MarkdownReadError: Error, Equatable, Sendable {
    case accessDenied
    case bookmarkStale
    case notDownloaded
    case notFound
}

/// Boundary to the user-selected folder/files. The app implements this with
/// security-scoped bookmarks from the document picker; tests use fixtures.
/// Implementations must only expose what the user picked:
/// - resolve each candidate with `resolvingSymlinksInPath()` (or skip
///   `.isSymbolicLinkKey` entries) and verify the resolved URL is still inside
///   the security-scoped root before reading;
/// - report anything outside the root as `.accessDenied`.
/// `ObsidianImportPolicy` validates path strings only and cannot see symlinks.
public protocol MarkdownDocumentReader: Sendable {
    /// Paths relative to the selection root.
    func selectedPaths() async throws -> [String]
    func read(relativePath: String) async throws -> Data
}

public struct ObsidianImportResult: Equatable, Sendable {
    public let items: [ContextItem]
    public let skipped: [String: ObsidianSkipReason]
    /// Set when the selection itself is unreadable (e.g. revoked); items is empty.
    public let selectionError: MarkdownReadError?
}

/// Turns user-selected Obsidian notes into review-pending `ContextItem`s.
/// Local only: nothing is uploaded. Every item starts with consent
/// `.notRequested`, so nothing is narratable until the user approves it.
public struct ObsidianContextSource: ContextSource {
    public let source: ContextSourceKind = .obsidian
    public static let maxSummaryWords = 40
    public static let maxTitleCharacters = 80

    private let reader: any MarkdownDocumentReader
    private let policy: ObsidianImportPolicy
    private let parser = MarkdownNoteParser()
    private let calendar: Calendar
    private let retention: TimeInterval
    private let now: @Sendable () -> Date

    public init(reader: any MarkdownDocumentReader,
                policy: ObsidianImportPolicy = ObsidianImportPolicy(),
                calendar: Calendar = .current,
                retention: TimeInterval = 7 * 24 * 60 * 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.policy = policy
        self.calendar = calendar
        self.retention = retention
        self.now = now
    }

    public func fetchItems() async throws -> [ContextItem] {
        try await importNotes().items
    }

    public func importNotes() async throws -> ObsidianImportResult {
        let paths: [String]
        do {
            paths = try await reader.selectedPaths()
        } catch let error as MarkdownReadError {
            return ObsidianImportResult(items: [], skipped: [:], selectionError: error)
        }

        let timestamp = now()
        var items: [ContextItem] = []
        var skipped: [String: ObsidianSkipReason] = [:]
        var accepted = 0

        for path in paths.sorted() {
            try Task.checkCancellation()
            if let reason = policy.rejection(forPath: path) { skipped[path] = reason; continue }
            guard accepted < policy.maxFiles else { skipped[path] = .fileLimitReached; continue }
            accepted += 1

            let data: Data
            do {
                data = try await reader.read(relativePath: path)
            } catch let error as MarkdownReadError {
                skipped[path] = Self.reason(for: error)
                continue
            }
            switch policy.decode(data) {
            case .failure(let reason):
                skipped[path] = reason
            case .success(let text):
                switch item(path: path, note: parser.parse(text), at: timestamp) {
                case .success(let item): items.append(item)
                case .failure(let reason): skipped[path] = reason
                }
            }
        }
        return ObsidianImportResult(items: items, skipped: skipped, selectionError: nil)
    }

    func item(path: String, note: MarkdownNote, at timestamp: Date) -> Result<ContextItem, ObsidianSkipReason> {
        let optOut = note.frontmatterValue("aerodj")?.lowercased()
        let isPrivate = note.frontmatterValue("private")?.lowercased() == "true"
        let tags = (note.frontmatter["tags"] ?? []).map { $0.lowercased().trimmingCharacters(in: ["#"]) }
        if optOut == "false" || optOut == "exclude" || isPrivate || tags.contains("private")
            || note.inlineTags.contains("private") {
            return .failure(.optedOut)
        }

        let summary: String
        let open = note.openTasks
        if !open.isEmpty {
            summary = "Open tasks: " + open.prefix(3).map(\.text).joined(separator: "; ")
        } else if let paragraph = note.paragraphs.first {
            summary = paragraph
        } else {
            return .failure(.empty)
        }

        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // A date-like file name ("2024-01-03") isn't a meaningful spoken subject:
        // leave the title empty so the briefing falls back to the summary.
        let rawTitle = note.frontmatterValue("title").map(MarkdownNoteParser.sanitizeInline)
            ?? note.headings.first(where: { $0.level == 1 })?.text
            ?? (Self.isDateLike(fileName) ? "" : fileName)
        let provenance = "obsidian-file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)

        return .success(ContextItem(
            id: Self.stableID(for: provenance),
            source: .obsidian,
            createdAt: timestamp,
            // `date`/`created` record when a note was written, not when anything
            // happens, so only `due`/`scheduled` become `eventAt`.
            eventAt: ["due", "scheduled"].lazy.compactMap { note.frontmatterValue($0) }
                .compactMap(parseDay).first,
            title: Self.bounded(characters: rawTitle, Self.maxTitleCharacters),
            summary: Self.bounded(words: summary, Self.maxSummaryWords),
            sensitivity: Self.sensitivity(note.frontmatterValue("aerodj-sensitivity")),
            consent: .notRequested,
            expiresAt: timestamp.addingTimeInterval(retention),
            provenance: provenance
        ))
    }

    /// Parses `YYYY-MM-DD` (optionally followed by a time, which is ignored)
    /// as the start of that day in the injected calendar's time zone.
    func parseDay(_ value: String) -> Date? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard value.count >= 10, parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// File names made only of digits and date punctuation (daily notes).
    static func isDateLike(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isNumber || "-_. ".contains($0) } && name.contains(where: \.isNumber)
    }

    static func sensitivity(_ value: String?) -> Sensitivity {
        switch value?.lowercased() {
        case "low": return .low
        case "high": return .high
        case "blocked": return .blocked
        default: return .medium // personal notes default above calendar's .low
        }
    }

    static func reason(for error: MarkdownReadError) -> ObsidianSkipReason {
        switch error {
        case .accessDenied: return .accessDenied
        case .bookmarkStale: return .bookmarkStale
        case .notDownloaded: return .notDownloaded
        case .notFound: return .notFound
        }
    }

    static func bounded(words text: String, _ limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count <= limit ? text : words.prefix(limit).joined(separator: " ") + "…"
    }

    static func bounded(characters text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// Deterministic UUID for a provenance string (FNV-1a, two seeds), so a
    /// re-import of the same file yields the same id and can be deduplicated.
    /// Not cryptographic; ids are not secrets.
    static func stableID(for key: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            key.utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        var bytes = withUnsafeBytes(of: a.bigEndian, Array.init) + withUnsafeBytes(of: b.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8 (custom)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
