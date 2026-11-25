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
final class CacheLaunchPurgeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var fresh: Set<String> = []

    var isPending: Bool { lock.withLock { pending } }

    func begin() { lock.withLock { pending = true; fresh = [] } }
    func finish() { lock.withLock { pending = false; fresh = [] } }

    /// Call with the write, under the disk gate's lock. Records nothing once the purge is done.
    func markStored(_ key: String) { lock.withLock { if pending { fresh.insert(key) } } }

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
