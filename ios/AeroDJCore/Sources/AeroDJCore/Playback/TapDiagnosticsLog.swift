import Foundation

/// TEMPORARY P0 diagnostics (remove: #121) -Atlas (build 9 no-audio). Remove with the overlay; tracked in
/// the PR that added it (atlas/p0-no-audio-diag).
///
/// A bounded ring of play-path events for the on-screen overlay. A tag is a `StaticString`,
/// so only a literal naming a call site can be recorded: never a title, an ID, a search term,
/// a URL, or error text. Values are enum names, booleans and integers chosen by the caller.
public struct TapDiagnosticsLog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// Milliseconds since the last song tap, nil before the first tap.
        public let offsetMs: Int?
        public let tag: String
        /// Optional short detail: enum names, booleans or integers only.
        public let detail: String
        /// The playback attempt (`PlaybackAttemptID.number`) this record belongs to; nil before the first.
        public let attempt: Int?
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []
    public private(set) var tapAt: TimeInterval?

    public init(capacity: Int = 10) {
        self.capacity = max(1, capacity)
    }

    /// A song row was tapped. Offsets are measured from here.
    public mutating func markTap(at now: TimeInterval) {
        tapAt = now
    }

    public func offsetMs(at now: TimeInterval) -> Int? {
        tapAt.map { Int(((now - $0) * 1000).rounded()) }
    }

    public mutating func record(_ tag: StaticString, detail: String = "", attempt: Int? = nil, at now: TimeInterval) {
        entries.append(Entry(offsetMs: offsetMs(at: now), tag: "\(tag)", detail: detail, attempt: attempt))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}
