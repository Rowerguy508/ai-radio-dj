import Foundation

/// Resumes an on-device speech render exactly once, whichever signal arrives first:
/// the synthesizer's empty final buffer, its did-finish delegate callback, a write
/// error, or cancellation. Later signals are ignored. If no signal ever arrives, the
/// route timeout (20 s for on-device) fails the render, so the DJ break is skipped;
/// there is never a live-speech fallback.
///
/// `didFinish` is not guaranteed to arrive after the last data buffer, so it starts a short
/// grace period (default 250 ms) during which buffers are still accepted; the empty final
/// buffer ends the grace early. The route deadline still applies during the grace.
///
/// Kept free of AVFoundation so it can be tested with `swift test` on Linux.
public final class SpeechRenderCompletion: @unchecked Sendable {
    public enum Signal: String, Sendable, Equatable {
        case finalBuffer, didFinish, failed, cancelled
    }

    /// Runs `fire` after `delay`. Injectable so tests need no real sleeps.
    public typealias GraceScheduler = @Sendable (_ delay: Duration, _ fire: @escaping @Sendable () -> Void) -> Void

    public static let defaultDidFinishGrace: Duration = .milliseconds(250)
    public static let taskScheduler: GraceScheduler = { delay, fire in
        Task { try? await Task.sleep(for: delay); fire() }
    }

    private let didFinishGrace: Duration
    private let schedule: GraceScheduler
    private var graceStarted = false
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    private var first: Signal?
    private var resumes = 0

    public init(didFinishGrace: Duration = SpeechRenderCompletion.defaultDidFinishGrace,
                schedule: @escaping GraceScheduler = SpeechRenderCompletion.taskScheduler) {
        self.didFinishGrace = didFinishGrace
        self.schedule = schedule
    }

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

    /// Records a signal. Only the first one completes the render; returns whether this call did
    /// (for `didFinish` with a grace period: whether it started the grace).
    @discardableResult
    public func signal(_ signal: Signal, error: Error? = nil) -> Bool {
        if signal == .didFinish, error == nil, didFinishGrace > .zero {
            let start: Bool = lock.withLock {
                guard first == nil, !graceStarted else { return false }
                graceStarted = true
                return true
            }
            if start { schedule(didFinishGrace) { [self] in complete(.didFinish, error: nil) } }
            return start
        }
        return complete(signal, error: error)
    }

    @discardableResult
    private func complete(_ signal: Signal, error: Error?) -> Bool {
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
