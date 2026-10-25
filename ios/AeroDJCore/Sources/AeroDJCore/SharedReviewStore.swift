import Foundation

/// Persisted review state for one shared item. Content is never stored here;
/// a redaction rewrites the inbox envelope itself.
public struct SharedReviewRecord: Codable, Equatable, Sendable {
    public var decision: SharedReviewDecision
    public var label: SharedSourceLabel
    public var isRedacted: Bool
    /// The user confirmed a flagged (instruction-like) item should be read anyway.
    public var isReconfirmed: Bool

    public init(decision: SharedReviewDecision = .pending, label: SharedSourceLabel = .other, isRedacted: Bool = false,
                isReconfirmed: Bool = false) {
        self.decision = decision
        self.label = label
        self.isRedacted = isRedacted
        self.isReconfirmed = isReconfirmed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decision = try c.decode(SharedReviewDecision.self, forKey: .decision)
        label = try c.decode(SharedSourceLabel.self, forKey: .label)
        isRedacted = try c.decode(Bool.self, forKey: .isRedacted)
        // State written before reconfirmation existed loads as not reconfirmed.
        isReconfirmed = try c.decodeIfPresent(Bool.self, forKey: .isReconfirmed) ?? false
    }
}

/// File-backed store so include/exclude/label decisions survive relaunch.
/// One JSON file, written atomically with Data Protection; records for items
/// no longer in the inbox are pruned, so retention follows the inbox.
public struct SharedReviewStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// Missing or unreadable state loads as empty (fails closed: pending).
    public func load() -> [UUID: SharedReviewRecord] {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: SharedReviewRecord].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    public func save(_ records: [UUID: SharedReviewRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let keyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        try ProtectedFile.write(encoder.encode(keyed), to: file)
    }
}
