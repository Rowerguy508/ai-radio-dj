import Foundation

/// The cache a `DJBreakPreparer` with a cloud-voice consent check renders through (tester build,
/// follow-up to #398: Sentinel's N2, Fry's nit 2). It orders cache writes against a decline,
/// which the app records synchronously (`CloudVoiceConsentStore.decline()`) before its drop and
/// purge task runs:
/// - A cloud clip whose write starts after the decline is not written at all.
/// - A cloud clip whose write was already under way when the decline landed is purged again
///   right after it, because the decline's own purge may have run before the write finished.
/// - A cloud clip is never read back while consent is withdrawn, so a stale clip makes the
///   renderer try the next route (on-device) instead of dropping the whole break.
/// On-device, free providers (`localProviders`) pass straight through. Every other call is the
/// base cache's. While consent is granted, nothing changes. -Nova
public struct CloudVoiceConsentCache: AudioCache {
    /// Private (Sentinel's #409 N1): no caller may reach the base cache past the consent checks.
    private let base: any AudioCache
    public let localProviders: Set<String>
    private let isGranted: @Sendable () -> Bool

    public init(base: any AudioCache, localProviders: Set<String>, isGranted: @escaping @Sendable () -> Bool) {
        self.base = base
        self.localProviders = localProviders
        self.isGranted = isGranted
    }

    public func audio(for key: String) async -> CachedAudio? {
        guard let clip = await base.audio(for: key) else { return nil }
        guard localProviders.contains(clip.providerID) || isGranted() else {
            // #397 (-Sentinel): a cloud clip found while consent is not granted (declined, or an
            // acceptance of a superseded copy version, v2 or earlier while v3 is current) is
            // deleted on sight, with every other cloud clip, instead of waiting for a decline or
            // the 7-day expiry. On-device clips stay.
            await base.purgeClips(keepingProviders: localProviders)
            return nil
        }
        return clip
    }

    public func store(_ audio: CachedAudio, for key: String) async {
        guard !localProviders.contains(audio.providerID) else { return await base.store(audio, for: key) }
        guard isGranted() else { return }               // started after the decline: never written
        await base.store(audio, for: key)
        if !isGranted() {                               // a decline landed during the write
            await base.purgeClips(keepingProviders: localProviders)
        }
    }

    public func purge(sourceItemIDs: Set<UUID>) async { await base.purge(sourceItemIDs: sourceItemIDs) }
    public func purgeExpired() async { await base.purgeExpired() }
    public func purgeAllPersonal() async { await base.purgeAllPersonal() }
    public func purgePersonalItems() async { await base.purgePersonalItems() }
    public func purgeClips(keepingProviders providerIDs: Set<String>) async {
        await base.purgeClips(keepingProviders: providerIDs)
    }
}

/// Fry's #404 nit 1: the device-run cache log (`AudioCacheFileLog.record`) counts the base
/// cache's files through this wrapper, cloud clips included whatever the consent: it reports
/// what is on disk, not what may be read back. Counts only; the base cache is never handed out
/// (Sentinel's #409 N1). -Nova
extension CloudVoiceConsentCache: AudioCacheForwarding {
    public func forwardedFileCount() async -> AudioCacheCount? { await AudioCacheFileLog.fileCount(of: base) }
}

/// Sentinel's #409 nit (-Nova): an empty mirror, so `dump`, `Mirror(reflecting:)`, or a debugger
/// summary of the wrapper never shows (or hands out) the base cache behind the consent checks.
extension CloudVoiceConsentCache: CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
