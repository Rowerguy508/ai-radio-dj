import Foundation

/// A song loaded while playback is not allowed to start (user pause, call, headphones).
///
/// `take()` reports that index once, when a later play actually starts it. A second
/// successful play does not report the song again.
public struct DeferredSongStart: Equatable, Sendable {
    public private(set) var index: Int?

    public init() {}

    public mutating func arm(_ index: Int) {
        self.index = index
    }

    public mutating func clear() {
        index = nil
    }

    public mutating func take() -> Int? {
        defer { index = nil }
        return index
    }
}
