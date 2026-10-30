import Foundation
#if canImport(os)
import os
#endif

/// Keeps the spoken-clip cache (`Voice/Cache`) out of iCloud and computer backups.
///
/// Clips are disposable (re-rendered on demand) and some are derived from personal items, so
/// they must never travel in a backup. The flag is set on the folder every time the cache
/// creates it (first store, or after it was deleted) and every time the app opens an existing
/// one, because a restore or migration can drop it.
///
/// A seam so Linux tests can verify the call: the Foundation marker only touches the resource
/// value on Apple platforms; tests inject a recording marker.
public protocol BackupExclusionMarking: Sendable {
    /// Sets `isExcludedFromBackup = true` on `directory`.
    func markExcluded(_ directory: URL) throws
    /// Reads the flag back from the URL; nil where the platform cannot report it (Linux).
    func isExcluded(_ directory: URL) -> Bool?
}

/// `URLResourceValues.isExcludedFromBackup` on Apple platforms; a no-op on Linux (no backup there).
public struct FoundationBackupExclusion: BackupExclusionMarking {
    public init() {}

    public func markExcluded(_ directory: URL) throws {
        #if canImport(Darwin)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #endif
    }

    public func isExcluded(_ directory: URL) -> Bool? {
        #if canImport(Darwin)
        // A fresh URL, so a cached resource value on the caller's URL cannot answer for the disk.
        let fresh = URL(fileURLWithPath: directory.path, isDirectory: true)
        return try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #else
        return nil
        #endif
    }
}

/// Content-free log for a failed backup exclusion. The line names only the moment, never the
/// path, the error text (which can carry the path) or any clip key.
public enum CacheBackupExclusionLog {
    public enum Moment: String, Sendable { case create, open }

    public static func message(_ moment: Moment) -> String {
        "AeroDJ.cache backup exclusion failed moment=\(moment.rawValue)"
    }

    /// Default sink: one public, fixed-vocabulary line on Apple platforms.
    public static let emit: @Sendable (String) -> Void = { line in
        #if canImport(os)
        Logger(subsystem: "com.aerodj.app", category: "cache").error("\(line, privacy: .public)")
        #endif
    }
}

extension FileAudioCache {
    /// Marks the cache folder excluded from backup. Never throws: a failure is logged (content-free)
    /// and the cache keeps working, so playback is never affected.
    func applyBackupExclusion(_ moment: CacheBackupExclusionLog.Moment) {
        do {
            try backupExclusion.markExcluded(directory)
        } catch {
            backupExclusionLog(CacheBackupExclusionLog.message(moment))
        }
    }
}
