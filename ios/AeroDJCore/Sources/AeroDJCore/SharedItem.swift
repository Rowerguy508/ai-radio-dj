import Foundation

/// A user-shared item (email/message excerpt, URL, or text) awaiting review.
/// Provenance-tracked; never implies whole-inbox access.
public struct SharedItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let source: String
    public let createdAt: Date
    public let isURL: Bool

    public init(id: UUID = UUID(), text: String, source: String,
                createdAt: Date = Date(), isURL: Bool = false) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.isURL = isURL
    }
}

/// Validates and bounds user-shared content. Pure logic, testable.
public struct SharedItemValidator: Sendable {
    public let maxLength: Int
    public let maxItems: Int
    public let retentionDays: Int

    public init(maxLength: Int = 2_000, maxItems: Int = 50, retentionDays: Int = 7) {
        self.maxLength = maxLength
        self.maxItems = maxItems
        self.retentionDays = retentionDays
    }

    public enum ValidationError: Error, Equatable {
        case empty
        case tooLong
    }

    /// Validate length/format. Returns a trimmed, safe item.
    public func validate(_ raw: String, source: String, now: Date = Date()) throws -> SharedItem {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard trimmed.count <= maxLength else { throw ValidationError.tooLong }
        let isURL = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        return SharedItem(text: trimmed, source: source, createdAt: now, isURL: isURL)
    }

    /// Enforce bounded retention + item cap. Returns items that survive.
    public func prune(_ items: [SharedItem], now: Date = Date()) -> [SharedItem] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let fresh = items.filter { $0.createdAt >= cutoff }
        return Array(fresh.sorted { $0.createdAt > $1.createdAt }.prefix(maxItems))
    }
}
