import Foundation

/// Remembers, per `voice.id`, whether that on-device voice rendered recently. After a
/// failure the voice is suspect for `holdOff`, so the renderer skips straight to the next
/// route instead of waiting out another timeout. A success clears it. In memory only:
/// a relaunch starts fresh, and nothing here is logged or persisted.
public final class VoiceHealthLedger: @unchecked Sendable {
    public static let defaultHoldOff: TimeInterval = 10 * 60

    private let lock = NSLock()
    private let holdOff: TimeInterval
    private let now: @Sendable () -> Date
    private var failedAt: [String: Date] = [:]

    public init(holdOff: TimeInterval = VoiceHealthLedger.defaultHoldOff, now: @escaping @Sendable () -> Date = Date.init) {
        self.holdOff = holdOff
        self.now = now
    }

    public func isSuspect(_ voiceID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = failedAt[voiceID] else { return false }
        if now().timeIntervalSince(at) >= holdOff { failedAt[voiceID] = nil; return false }
        return true
    }

    public func recordFailure(_ voiceID: String) {
        lock.lock(); defer { lock.unlock() }
        failedAt[voiceID] = now()
    }

    public func recordSuccess(_ voiceID: String) {
        lock.lock(); defer { lock.unlock() }
        failedAt[voiceID] = nil
    }
}
