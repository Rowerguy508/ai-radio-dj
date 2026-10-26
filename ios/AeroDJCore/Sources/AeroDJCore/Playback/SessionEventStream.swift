import Foundation

/// An `AsyncStream` whose owner is supposed to finish it on release.
///
/// The audio-session monitor uses this so a released monitor ends its consumer loop.
/// Deinit does not finish the stream yet.
public final class FinishingStream<Element: Sendable>: Sendable {
    public let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    public init() {
        let pair = AsyncStream<Element>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    deinit {}

    public func yield(_ value: Element) {
        continuation.yield(value)
    }
}
