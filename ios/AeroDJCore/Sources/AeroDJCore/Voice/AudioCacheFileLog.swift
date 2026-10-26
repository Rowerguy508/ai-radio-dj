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
        guard let counting = cache as? any AudioCacheCounting else { return nil }
        let count = await counting.fileCount()
        let line = message(count, after: moment)
        #if canImport(os)
        // Integers and a fixed moment word only, each marked public: no names, titles or ids.
        Logger(subsystem: "com.aerodj.app", category: "cache").notice(
            "AeroDJ.cache narration cache count=\(count.files, privacy: .public) personal=\(count.personal, privacy: .public) after=\(moment.rawValue, privacy: .public)")
        #endif
        return line
    }
}
