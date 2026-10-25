import Foundation

/// A single piece of personal context that may be narrated.
/// Provenance-tracked, consent-gated, expiry-aware. Never contains raw inbox data.
public struct ContextItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let source: ContextSourceKind
    public let createdAt: Date
    public let eventAt: Date?
    public let title: String
    public let summary: String
    public let sensitivity: Sensitivity
    public let consent: ConsentState
    public let expiresAt: Date?
    public let provenance: String

    public init(
        id: UUID = UUID(),
        source: ContextSourceKind,
        createdAt: Date = Date(),
        eventAt: Date? = nil,
        title: String,
        summary: String,
        sensitivity: Sensitivity,
        consent: ConsentState,
        expiresAt: Date? = nil,
        provenance: String
    ) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
        self.eventAt = eventAt
        self.title = title
        self.summary = summary
        self.sensitivity = sensitivity
        self.consent = consent
        self.expiresAt = expiresAt
        self.provenance = provenance
    }

    /// Whether this item may be narrated right now.
    public var isNarratable: Bool {
        consent == .granted && sensitivity != .blocked
    }
}

public enum ContextSourceKind: String, Codable, Sendable {
    case calendar
    case emailShared
    case messagesShared
    case obsidian
    case userShared
}

public enum Sensitivity: String, Codable, Sendable {
    case low
    case medium
    case high
    case blocked
}

public enum ConsentState: String, Codable, Sendable {
    case notRequested
    case granted
    case denied
    case revoked
}
