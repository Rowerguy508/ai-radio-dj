import Foundation

/// An `AsyncStream` whose owner finishes it on release.
///
/// The audio-session monitor holds one of these. Releasing the monitor releases the
/// stream, and deinit finishes it so the consumer loop ends.
public final class FinishingStream<Element: Sendable>: Sendable {
    public let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    public init() {
        let pair = AsyncStream<Element>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    deinit {
        continuation.finish()
    }

    public func yield(_ value: Element) {
        continuation.yield(value)
    }
}
