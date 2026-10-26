import Foundation

/// Resumes an on-device speech render exactly once, whichever signal arrives first:
/// the synthesizer's empty final buffer, its did-finish delegate callback, a write
/// error, or cancellation. Later signals are ignored. If no signal ever arrives, the
/// route timeout (20 s for on-device) fails the render, so the DJ break is skipped;
/// there is never a live-speech fallback.
///
/// Kept free of AVFoundation so it can be tested with `swift test` on Linux.
public final class SpeechRenderCompletion: @unchecked Sendable {
    public enum Signal: String, Sendable, Equatable {
        case finalBuffer, didFinish, failed, cancelled
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    private var first: Signal?
    private var resumes = 0

    public init() {}

    /// True once any signal has arrived.
    public var isFinished: Bool { lock.withLock { first != nil } }
    /// The signal that completed the render.
    public var winner: Signal? { lock.withLock { first } }
    /// How many times the waiter was resumed (always 0 or 1).
    public var resumeCount: Int { lock.withLock { resumes } }

    /// Waits for the first signal. `start` runs once the waiter is registered, unless a signal
    /// (e.g. cancellation) already arrived. `onCancel` runs on task cancellation, before the
    /// render is failed with `CancellationError`.
    public func wait(start: () -> Void, onCancel: @escaping @Sendable () -> Void = {}) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let early: Result<Void, Error>? = lock.withLock {
                    if let outcome { resumes += 1; return outcome }
                    continuation = c
                    return nil
                }
                if let early { c.resume(with: early) } else { start() }
            }
        } onCancel: {
            onCancel()
            self.signal(.cancelled, error: CancellationError())
        }
    }

    /// Records a signal. Only the first one completes the render; returns whether this call did.
    @discardableResult
    public func signal(_ signal: Signal, error: Error? = nil) -> Bool {
        let (won, c, result): (Bool, CheckedContinuation<Void, Error>?, Result<Void, Error>) = lock.withLock {
            let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
            guard first == nil else { return (false, nil, result) }
            first = signal
            outcome = result
            let c = continuation
            continuation = nil
            if c != nil { resumes += 1 }
            return (true, c, result)
        }
        c?.resume(with: result)
        return won
    }
}
