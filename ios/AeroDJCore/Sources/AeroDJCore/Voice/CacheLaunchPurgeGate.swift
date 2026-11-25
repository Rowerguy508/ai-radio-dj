import Foundation

/// #82 F3 (-Sentinel): the launch purge runs in a detached task while the renderer is ready at
/// once, so a read in that window could serve a personal clip left by an earlier launch that the
/// purge was about to delete. While a launch purge is pending, `FileAudioCache` withholds every
/// personal clip on disk that was not stored in this launch; it never waits, so nothing can
/// deadlock, and a purge that never finishes only means misses (fail closed).
///
/// - Pending only after `begin()`, which `AudioCacheSweeper.start(purgingPersonalFirst: true)`
///   calls synchronously before it detaches. A cache nobody starts a launch purge on (tests,
///   `prepareForLaunch` called directly) behaves exactly as before.
/// - `finish()` runs when `purgePersonalItems` completes; after that every read is as before,
///   so `VoiceRenderer.allLinesClipTag`-only clips (never withheld) keep working.
/// - Keys stored in this launch during the window are "fresh": served, and skipped by the purge,
///   so a clip rendered during the window is neither withheld nor wiped. A key is marked under
///   the disk gate's lock together with its write, and the purge deletes under the same lock.
/// Holds keys only, never clip content or item ids, and logs nothing.
/// - #637 P1 (fail closed): a purge that could not remove every file it should have calls
///   `purgeFailed()` instead of `finish()`. The gate stays pending (opened if it was not), so
///   every earlier-launch personal clip, including the one that survived, stays withheld, and
///   `needsRetry` makes the next `purgeExpired` sweep run the purge again. Only a purge whose
///   removals all succeed calls `finish()`.
final class CacheLaunchPurgeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var retry = false
    private var fresh: Set<String> = []

    var isPending: Bool { lock.withLock { pending } }
    /// A launch purge failed to remove something; the next sweep must run it again.
    var needsRetry: Bool { lock.withLock { retry } }

    func begin() { lock.withLock { pending = true; retry = false; fresh = [] } }
    func finish() { lock.withLock { pending = false; retry = false; fresh = [] } }

    /// #637 P1: keep (or start) withholding, and ask for a retry. Keys already stored in this
    /// launch stay fresh; if the gate was not pending, nothing was, so nothing is kept.
    func purgeFailed() { lock.withLock { if !pending { pending = true; fresh = [] }; retry = true } }

    /// Call with the write, under the disk gate's lock, and only after the write succeeded.
    /// Records nothing once the purge is done.
    func markStored(_ key: String) { lock.withLock { if pending { fresh.insert(key) } } }

    /// #637 P1: a store whose write failed is not this launch's clip any more, whatever is left
    /// at its key. Under the disk gate's lock.
    func unmarkStored(_ key: String) { lock.withLock { _ = fresh.remove(key) } }

    /// True while a launch purge is pending and `key` was stored in this launch (purge keeps it).
    func storedThisLaunch(_ key: String) -> Bool { lock.withLock { pending && fresh.contains(key) } }

    /// True while a launch purge is pending and `key` was not stored in this launch. Evaluate it
    /// before reading the file: a store that lands after is withheld too (fail closed).
    func withholdsPersonal(_ key: String) -> Bool { lock.withLock { pending && !fresh.contains(key) } }
}

/// A cache whose reads are gated on the launch purge. `AudioCacheSweeper.start` opens the
/// window (synchronously, before the purge task runs); the cache closes it when its
/// `purgePersonalItems` completes.
protocol LaunchPurgeGated: Sendable {
    func beginLaunchPurge()
}

extension FileAudioCache: LaunchPurgeGated {
    func beginLaunchPurge() { launchGate.begin() }
}
