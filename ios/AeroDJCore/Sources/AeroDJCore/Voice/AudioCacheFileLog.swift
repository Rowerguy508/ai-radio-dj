import Foundation
#if canImport(os)
import os
#endif

/// How many rendered-voice clips a cache holds. Counts only: no keys, ids, titles or text.
public struct AudioCacheCount: Equatable, Sendable {
    /// Every stored clip (files, for `FileAudioCache`).
    public let files: Int
    /// Clips derived from at least one personal item (calendar, notes, shared items).
    public let personal: Int
    /// Clips with no personal source (greetings, song intros).
    public var generic: Int { files - personal }

    public init(files: Int, personal: Int) {
        self.files = files
        self.personal = personal
    }
}

/// A cache that can report its size for the device-run log.
public protocol AudioCacheCounting: Sendable {
    func fileCount() async -> AudioCacheCount
}

/// A cache that wraps another and stores nothing of its own (`CloudVoiceConsentCache`). The
/// device-run log counts the wrapped cache's files through it (Fry's #404 nit 1). It forwards
/// the count only, never the wrapped cache itself, so nothing can use it to read or write past
/// the wrapper's checks (Sentinel's #409 N1). Nil: the wrapped cache cannot count. -Nova
public protocol AudioCacheForwarding: Sendable {
    func forwardedFileCount() async -> AudioCacheCount?
}

/// Device-run evidence that purges delete files, not only stop audio (#76 step 9).
/// Stable, content-free line: `AeroDJ.cache narration cache count=<n> personal=<p> after=<purge|launch>`.
/// `count` is every file in the cache directory (metadata and audio, any extension).
/// Per-source breakdown is personal versus generic: clips record item ids, not source kinds,
/// and ids are never logged.
public enum AudioCacheFileLog {
    public enum Moment: String, Sendable { case purge, launch }

    public static func message(_ count: AudioCacheCount, after moment: Moment) -> String {
        "AeroDJ.cache narration cache count=\(count.files) personal=\(count.personal) after=\(moment.rawValue)"
    }

    /// Logs the cache's current count, if it can report one. Returns the line (for tests).
    @discardableResult
    public static func record(_ cache: any AudioCache, after moment: Moment) async -> String? {
        guard let count = await fileCount(of: cache) else { return nil }
        let line = message(count, after: moment)
        #if canImport(os)
        // Integers and a fixed moment word only, each marked public: no names, titles or ids.
        Logger(subsystem: "com.aerodj.app", category: "cache").notice(
            "AeroDJ.cache narration cache count=\(count.files, privacy: .public) personal=\(count.personal, privacy: .public) after=\(moment.rawValue, privacy: .public)")
        #endif
        return line
    }

    /// The cache's count, or the count of the cache it forwards to (`AudioCacheForwarding`, any
    /// depth). Nil when neither can report one: a wrapper never makes up a count.
    public static func fileCount(of cache: any AudioCache) async -> AudioCacheCount? {
        if let counting = cache as? any AudioCacheCounting { return await counting.fileCount() }
        if let wrapper = cache as? any AudioCacheForwarding { return await wrapper.forwardedFileCount() }
        return nil
    }
}
