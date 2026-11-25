import Foundation

/// #82 F3 (-Sentinel): the launch purge runs in a detached task while the renderer is ready at
/// once, so a read in that window could serve a personal clip left by an earlier launch that the
/// purge was about to delete. While a launch purge is pending, `FileAudioCache` withholds every
/// personal clip on disk that was not stored in this launch; it never waits, so nothing can
/// deadlock, and a purge that never finishes only means misses (fail closed).
///
/// - Pending only after `begin()`, which `AudioCacheSweeper.startPurgingPersonalFirst`
///   calls synchronously before it detaches. A cache nobody starts a launch purge on (tests,
///   the internal `prepareForLaunch` called directly) behaves exactly as before.
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

/// A cache whose reads are gated on the launch purge. `AudioCacheSweeper.startPurgingPersonalFirst`
/// opens the window (synchronously, before the purge task runs); the cache closes it when its
/// `purgePersonalItems` completes.
///
/// #637 follow-up (-Sentinel, Nova's nit): the launch purge only starts on a cache of this type,
/// checked at compile time, so no build (Release included) can start it on a cache that would
/// serve an earlier launch's personal clips during the window. An `any AudioCache` is gated by
/// wrapping it in `LaunchPurgeGatedCache`, and every read must go through that wrapper.
/// Calling `beginLaunchPurge()` with no purge after it only means misses (fail closed).
public protocol LaunchPurgeGated: AudioCache {
    func beginLaunchPurge()
}

extension FileAudioCache: LaunchPurgeGated {
    public func beginLaunchPurge() { launchGate.begin() }
}

/// #637 follow-up (-Sentinel): gates any `AudioCache` on the launch purge, so a cache that is
/// not `LaunchPurgeGated` itself (a wrapper, a future cache) cannot serve an earlier launch's
/// personal clip before the purge completes.
/// - Base gated (`FileAudioCache`, another wrapper): `beginLaunchPurge` is forwarded and the base
///   gates its own reads, failed removals included. Nothing else changes, so today's gated
///   caches behave exactly as before.
/// - Base not gated: this wrapper withholds every personal clip while the purge is pending,
///   except a clip it stored itself in this launch and reads back unchanged (an earlier clip
///   left at the key by a write that failed is not served as this launch's). The window closes
///   when the base's `purgePersonalItems` returns through this wrapper. Never waits.
/// - Requirement on an ungated base (#656 nit): its `purgePersonalItems` must really delete every
///   personal clip, or not return. This wrapper cannot see a failed or partial purge, so a purge
///   that fails silently closes the window early and the clips it left are served again. A cache
///   whose removals can fail must gate itself and keep its gate shut on failure, as
///   `FileAudioCache` does (#637 P1), so that this wrapper forwards to it instead.
/// Holds keys and content fingerprints only, and only while its own window is open: none are
/// recorded when no purge is pending, and all are dropped when the window closes. Never clip
/// content or item ids, and it logs nothing.
/// The base cache is private and never handed out (Sentinel's #409 N1).
public struct LaunchPurgeGatedCache: LaunchPurgeGated {
    private let wrapped: any AudioCache
    private let state = State()

    public init(base: any AudioCache) { self.wrapped = base }

    public func beginLaunchPurge() {
        if let gated = wrapped as? any LaunchPurgeGated { gated.beginLaunchPurge() } else { state.begin() }
    }

    public func audio(for key: String) async -> CachedAudio? {
        // Decided before the read, as in `FileAudioCache`: a store landing after is withheld too.
        let held = state.heldFingerprint(key)
        guard let clip = await wrapped.audio(for: key) else { return nil }
        switch held {
        case .open: return clip
        case .pending(let fresh):
            guard clip.hasPersonalItem else { return clip }
            return fresh == Fingerprint(clip) ? clip : nil
        }
    }

    public func store(_ audio: CachedAudio, for key: String) async {
        let fingerprint = Fingerprint(audio)
        state.unmark(key)                               // until the new write has returned
        await wrapped.store(audio, for: key)
        state.mark(key, fingerprint)
    }

    public func purgePersonalItems() async {
        await wrapped.purgePersonalItems()
        state.finish()
    }

    public func purge(sourceItemIDs: Set<UUID>) async { await wrapped.purge(sourceItemIDs: sourceItemIDs) }
    public func purgeExpired() async { await wrapped.purgeExpired() }
    public func purgeAllPersonal() async { await wrapped.purgeAllPersonal() }
    public func purgeClips(keepingProviders providerIDs: Set<String>) async {
        await wrapped.purgeClips(keepingProviders: providerIDs)
    }

    /// True while this wrapper's own window is open (base not gated, purge not returned).
    var isWithholding: Bool { state.isPending }
    /// Fingerprints held now (tests): zero whenever the window is closed.
    var heldFingerprintCount: Int { state.fingerprintCount }

    private struct Fingerprint: Equatable {
        let bytes: Int, hash: Int, createdAt: Date, providerID: String, voiceID: String
        init(_ clip: CachedAudio) {
            var hasher = Hasher()
            clip.data.withUnsafeBytes { hasher.combine(bytes: $0) }
            bytes = clip.data.count; hash = hasher.finalize()
            createdAt = clip.createdAt; providerID = clip.providerID; voiceID = clip.voiceID
        }
    }

    private enum Held { case open, pending(Fingerprint?) }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false
        private var fresh: [String: Fingerprint] = [:]

        var isPending: Bool { lock.withLock { pending } }
        var fingerprintCount: Int { lock.withLock { fresh.count } }
        func begin() { lock.withLock { pending = true; fresh = [:] } }
        func finish() { lock.withLock { pending = false; fresh.removeAll() } }   // drop every fingerprint
        /// Records nothing unless the window is open (a write that returns after it closed included).
        func mark(_ key: String, _ print: Fingerprint) { lock.withLock { if pending { fresh[key] = print } } }
        func unmark(_ key: String) { lock.withLock { _ = fresh.removeValue(forKey: key) } }
        func heldFingerprint(_ key: String) -> Held { lock.withLock { pending ? .pending(fresh[key]) : .open } }
    }
}

extension LaunchPurgeGatedCache: AudioCacheForwarding {
    public func forwardedFileCount() async -> AudioCacheCount? { await AudioCacheFileLog.fileCount(of: wrapped) }
}

extension LaunchPurgeGatedCache: CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
