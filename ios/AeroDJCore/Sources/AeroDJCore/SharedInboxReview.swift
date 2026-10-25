import Foundation

/// What the user says a share is. Never inferred from content.
public enum SharedSourceLabel: String, Codable, Sendable, CaseIterable {
    case email, message, other

    var sourceKind: ContextSourceKind {
        switch self {
        case .email: return .emailShared
        case .message: return .messagesShared
        case .other: return .userShared
        }
    }
}

public enum SharedReviewDecision: String, Codable, Sendable {
    case pending, approved, excluded
}

/// One shared item as the review screen shows it.
public struct SharedReviewEntry: Identifiable, Equatable, Sendable {
    public let item: SharedInboxItem
    public var label: SharedSourceLabel = .other
    public var decision: SharedReviewDecision = .pending
    /// User-edited text that replaces the shared content for narration.
    public var redactedText: String?

    public var id: UUID { item.id }
    public var displayText: String { redactedText ?? item.content }
}

public enum SharedReviewError: Error, Equatable, Sendable {
    case unknownItem
    case emptyRedaction
}

/// Review, redact and delete user-shared items, and expose them as
/// `ContextItem`s. Only `.approved` entries get consent `.granted`; deleting
/// an entry removes its file and it is gone from the next `fetchItems()`.
public actor SharedInboxReview: ContextSource {
    public nonisolated let source: ContextSourceKind = .userShared
    public static let maxSummaryWords = 40
    public static let maxTitleCharacters = 60

    private let reader: SharedInboxReader
    private let store: SharedReviewStore?
    private let now: @Sendable () -> Date
    public private(set) var entries: [SharedReviewEntry] = []

    /// `store` persists decisions across relaunch; `nil` keeps them in memory only.
    public init(reader: SharedInboxReader, store: SharedReviewStore? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.store = store
        self.now = now
    }

    /// Reloads from disk, restoring persisted review state for items that
    /// still exist and pruning state for items that are gone.
    @discardableResult
    public func refresh() throws -> SharedInboxLoadResult {
        let result = try reader.load(now: now())
        let saved = store?.load() ?? [:]
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        entries = result.items.map { item in
            if let entry = previous[item.id] { return entry }
            var entry = SharedReviewEntry(item: item)
            if let record = saved[item.id] {
                entry.decision = record.decision
                entry.label = record.label
                if record.isRedacted { entry.redactedText = item.content }
            }
            return entry
        }
        if store != nil, Set(saved.keys) != Set(entries.map(\.id)) || saved.count != entries.count { try persist() }
        return result
    }

    public func setLabel(_ label: SharedSourceLabel, for id: UUID) throws {
        try update(id) { $0.label = label }
    }

    public func setDecision(_ decision: SharedReviewDecision, for id: UUID) throws {
        try update(id) { $0.decision = decision }
    }

    /// Replaces the narrated text and rewrites the envelope on disk, so the
    /// unredacted original is gone (not kept until expiry).
    public func redact(_ id: UUID, to text: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw SharedReviewError.unknownItem }
        guard let replaced = entries[index].item.replacingContent(text) else { throw SharedReviewError.emptyRedaction }
        try reader.rewrite(replaced)
        var entry = SharedReviewEntry(item: replaced)
        entry.decision = entries[index].decision
        entry.label = entries[index].label
        entry.redactedText = replaced.content
        entries[index] = entry
        try persist()
    }

    /// Deletes the item from disk and from review immediately.
    public func delete(_ id: UUID) throws {
        guard entries.contains(where: { $0.id == id }) else { throw SharedReviewError.unknownItem }
        try reader.delete(id: id)
        entries.removeAll { $0.id == id }
        try persist()
    }

    public func fetchItems() async throws -> [ContextItem] {
        let current = now()
        return entries.filter { !$0.item.isExpired(at: current) }.map(Self.contextItem)
    }

    static func contextItem(_ entry: SharedReviewEntry) -> ContextItem {
        let text = entry.displayText
        let title: String
        if entry.redactedText == nil, entry.item.kind == .url, let host = URL(string: entry.item.content)?.host {
            title = "Link from \(host)"
        } else {
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            title = firstLine.count > maxTitleCharacters
                ? String(firstLine.prefix(maxTitleCharacters)) + "…" : firstLine
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        // A raw URL would be read character by character; speak the title instead.
        let summary = entry.redactedText == nil && entry.item.kind == .url ? title : words.count <= maxSummaryWords
            ? words.joined(separator: " ")
            : words.prefix(maxSummaryWords).joined(separator: " ") + "…"
        let consent: ConsentState = switch entry.decision {
        case .approved: .granted
        case .excluded: .denied
        case .pending: .notRequested
        }
        return ContextItem(
            id: entry.id,
            source: entry.label.sourceKind,
            createdAt: entry.item.createdAt,
            title: title,
            summary: summary,
            sensitivity: .medium,
            consent: consent,
            expiresAt: entry.item.expiresAt,
            provenance: "shared-inbox:\(entry.id.uuidString)"
        )
    }

    private func update(_ id: UUID, _ change: (inout SharedReviewEntry) -> Void) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw SharedReviewError.unknownItem }
        change(&entries[index])
        try persist()
    }

    private func persist() throws {
        guard let store else { return }
        try store.save(Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, SharedReviewRecord(decision: $0.decision, label: $0.label, isRedacted: $0.redactedText != nil))
        }))
    }
}
