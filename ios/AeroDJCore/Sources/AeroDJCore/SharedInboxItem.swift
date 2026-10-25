import Foundation

/// Envelope the Share Extension writes to the App Group inbox and the host app
/// reads. Carries its own expiry so the host can enforce retention.
public struct SharedInboxItem: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text
        case url
    }

    /// Upper bound on stored content. Longer shares are truncated, never stored whole.
    public static let maxContentBytes = 16 * 1024
    /// How long an unreviewed share is kept before the host must delete it.
    public static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60

    public let id: UUID
    public let source: ContextSourceKind
    public let kind: Kind
    public private(set) var content: String
    public private(set) var isTruncated: Bool
    public let createdAt: Date
    public let expiresAt: Date

    /// Returns `nil` when `content` is empty after trimming whitespace.
    public init?(
        id: UUID = UUID(),
        kind: Kind,
        content: String,
        now: Date,
        retention: TimeInterval = SharedInboxItem.defaultRetention
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bounded = Self.truncated(trimmed, maxBytes: Self.maxContentBytes)
        self.id = id
        self.source = .userShared
        self.kind = kind
        self.content = bounded
        self.isTruncated = bounded.utf8.count < trimmed.utf8.count
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(retention)
    }

    /// Same envelope with new content (used by redaction, which replaces the
    /// original on disk). `nil` when `content` is empty after trimming.
    public func replacingContent(_ content: String) -> SharedInboxItem? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var copy = self
        copy.content = Self.truncated(trimmed, maxBytes: Self.maxContentBytes)
        copy.isTruncated = copy.content.utf8.count < trimmed.utf8.count
        return copy
    }

    public func isExpired(at now: Date) -> Bool {
        expiresAt <= now
    }

    /// Longest prefix of `text` that fits in `maxBytes` of UTF-8 without
    /// splitting a character.
    static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= maxBytes else { break }
            result.append(character)
            used += size
        }
        return result
    }
}
