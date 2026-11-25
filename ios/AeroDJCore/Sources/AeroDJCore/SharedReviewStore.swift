import Foundation

/// Persisted review state for one shared item. Content is never stored here;
/// a redaction rewrites the inbox envelope itself.
public struct SharedReviewRecord: Codable, Equatable, Sendable {
    public var decision: SharedReviewDecision
    public var label: SharedSourceLabel
    public var isRedacted: Bool
    /// The user confirmed a flagged (instruction-like) item should be read anyway.
    public var isReconfirmed: Bool

    public init(decision: SharedReviewDecision = .pending, label: SharedSourceLabel = .other, isRedacted: Bool = false,
                isReconfirmed: Bool = false) {
        self.decision = decision
        self.label = label
        self.isRedacted = isRedacted
        self.isReconfirmed = isReconfirmed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decision = try c.decode(SharedReviewDecision.self, forKey: .decision)
        label = try c.decode(SharedSourceLabel.self, forKey: .label)
        isRedacted = try c.decode(Bool.self, forKey: .isRedacted)
        // State written before reconfirmation existed loads as not reconfirmed.
        isReconfirmed = try c.decodeIfPresent(Bool.self, forKey: .isReconfirmed) ?? false
    }
}

/// File-backed store so include/exclude/label decisions survive relaunch.
/// One JSON file, written atomically with Data Protection; records for items
/// no longer in the inbox are pruned, so retention follows the inbox.
///
/// Sentinel's n2 (-Nova): the store's folder (`Review/`) is marked excluded from backup on every
/// save, the same marker and read-back `FileAudioCache` uses (`BackupExclusionMarking`).
///
/// #426 (-Sentinel): fails closed, like the voice cache (#416). If the mark throws or reads back
/// unset, one content-free line is logged and the save throws
/// `SharedReviewError.backupExclusionUnverified` before anything is written or moved. The caller
/// keeps its previous state (`SharedInboxReview.update`), so the decision is not applied and the
/// user is told; nothing new lands in a folder that may be backed up. A file already on disk is
/// left as it was, and the next save tries the mark again. A change that only reduces exposure
/// (exclude, delete, edit) is never blocked: `SharedInboxReview` removes the file instead
/// (`removeSavedChoices`), so every item loads as pending.
public struct SharedReviewStore: Sendable {
    public let file: URL
    let backupExclusion: any BackupExclusionMarking
    let backupExclusionLog: @Sendable (String) -> Void
    /// #593 (-Echo): file operations behind `removeSavedChoices`, injectable so tests can fail each step.
    var fileOps: SharedReviewFileOps = .live

    public init(file: URL, backupExclusion: any BackupExclusionMarking = FoundationBackupExclusion(),
                backupExclusionLog: @escaping @Sendable (String) -> Void = SharedReviewStore.emitBackupExclusionFailure) {
        self.file = file
        self.backupExclusion = backupExclusion
        self.backupExclusionLog = backupExclusionLog
    }

    /// The only line logged when the `Review/` folder could not be marked excluded. No path, no error text.
    public static let backupExclusionFailureMessage = "AeroDJ.review backup exclusion failed"

    public static let emitBackupExclusionFailure: @Sendable (String) -> Void = { line in
        CacheBackupExclusionLog.emit(line)
    }

    /// Marks the folder excluded and reads it back. False (after the log line) on a throw or an
    /// unset read-back; a nil read-back (Linux) counts as excluded. A false result blocks the save (#426).
    @discardableResult
    func markFolderExcludedFromBackup() -> Bool {
        let directory = file.deletingLastPathComponent()
        var ok = true
        do {
            try backupExclusion.markExcluded(directory)
            if try backupExclusion.isExcluded(directory) == false { ok = false }
        } catch { ok = false }
        if !ok { backupExclusionLog(Self.backupExclusionFailureMessage) }
        return ok
    }

    /// Missing or unreadable state loads as empty (fails closed: pending).
    /// #593 (-Echo): also empty while the saved choices are revoked (see `removeSavedChoices`).
    public func load() -> [UUID: SharedReviewRecord] {
        guard !isRevoked, let decoded = decodedFile() else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    /// Where an unreadable store is moved before the next save (Fry's #402 nit): `<file>.unreadable`.
    /// Fry's and Sentinel's #414 n1 (-Nova): only the newest copy is kept. Setting a new one aside
    /// removes every older `<file>.unreadable` and `<file>.unreadable-<uuid>` (left by earlier builds).
    public var unreadableBackupPrefix: URL { file.appendingPathExtension("unreadable") }

    public func save(_ records: [UUID: SharedReviewRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard markFolderExcludedFromBackup() else { throw SharedReviewError.backupExclusionUnverified }
        try setAsideUnreadableFile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let keyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        try ProtectedFile.write(encoder.encode(keyed), to: file)
        // #593 (-Echo): the verified write replaced whatever was revoked, so the file is the truth
        // again. If the marker can't be cleared the save throws and the file stays ignored (pending).
        try fileOps.clearMarker(revokedMarker)
        SharedReviewRevocations.shared.clear(file)
    }

    /// #426 (-Sentinel): removes the saved choices so every item loads as pending. Used when a
    /// change that reduces exposure can't be saved privately. Writes nothing. Set-aside
    /// `.unreadable` copies are never loaded and are left alone.
    ///
    /// #593 (-Echo): fails closed and never throws. The old approvals and reconfirms must not load
    /// again even if the file can't be removed. In order, stopping at the first that works:
    /// 1. remove `state.json`;
    /// 2. overwrite it in place with no records (`{}`, no content);
    /// 3. write the empty `<file>.revoked` marker, so a relaunch ignores the file.
    /// The file is also revoked in memory for this process first, so every store on this file
    /// (the sheet builds one per open) loads pending even if all three fail. Steps 2 and 3 log one
    /// content-free line. The next verified `save` replaces the file and ends the revocation.
    public func removeSavedChoices() {
        SharedReviewRevocations.shared.revoke(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if (try? fileOps.remove(file)) != nil { return }
        backupExclusionLog(Self.savedChoicesNotRemovedMessage)
        if (try? fileOps.overwriteEmpty(file)) != nil { return }
        try? fileOps.writeMarker(revokedMarker)
    }

    /// #593 (-Echo): true while this file's saved choices are revoked, by marker or in memory.
    var isRevoked: Bool {
        SharedReviewRevocations.shared.contains(file) || FileManager.default.fileExists(atPath: revokedMarker.path)
    }

    /// #593 (-Echo): zero-byte marker next to the store, `<file>.revoked`. While it exists the file is
    /// never loaded. It holds nothing.
    public var revokedMarker: URL { file.appendingPathExtension("revoked") }

    /// #593 (-Echo): the only line logged when the saved choices could not be removed. No path, no error text.
    public static let savedChoicesNotRemovedMessage = "AeroDJ.review saved choices not removed, ignored until next save"

    private func decodedFile() -> [String: SharedReviewRecord]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([String: SharedReviewRecord].self, from: data)
    }

    /// Fry's #402 nit (-Nova): an unreadable store still loads as empty (pending, nothing invented),
    /// but the next save no longer overwrites it. The file is moved aside first, so the saved
    /// approvals in it are kept on disk; they are never read back as approvals. If it cannot be
    /// moved, the save throws and the caller keeps its state unchanged (`SharedInboxReview.update`).
    private func setAsideUnreadableFile() throws {
        let fm = FileManager.default
        // Only a regular file is set aside; anything else at the path is left for the write to fail on.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              decodedFile() == nil else { return }
        // Move aside under a fresh name first, so a failed move leaves every older copy in place.
        let fresh = file.appendingPathExtension("unreadable-\(UUID().uuidString)")
        try fm.moveItem(at: file, to: fresh)
        for old in unreadableCopies() where old.lastPathComponent != fresh.lastPathComponent {
            try? fm.removeItem(at: old)
        }
        // Best effort: the kept copy takes the plain name. If the rename fails it stays as `-<uuid>`.
        try? fm.moveItem(at: fresh, to: unreadableBackupPrefix)
    }

    /// Every set-aside copy next to the store: `<file>.unreadable` and `<file>.unreadable-*`.
    /// Never loaded back; listed only to cap them.
    func unreadableCopies() -> [URL] {
        let dir = file.deletingLastPathComponent()
        let base = unreadableBackupPrefix.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0 == base || $0.hasPrefix(base + "-") }.map { dir.appendingPathComponent($0) }
    }
}

/// #593 (-Echo): the file steps `SharedReviewStore.removeSavedChoices` and `save` take, so a test can
/// make any one of them fail. `live` uses `FileManager` and `FileHandle`.
struct SharedReviewFileOps: Sendable {
    var remove: @Sendable (URL) throws -> Void
    var overwriteEmpty: @Sendable (URL) throws -> Void
    var writeMarker: @Sendable (URL) throws -> Void
    var clearMarker: @Sendable (URL) throws -> Void

    static let live = SharedReviewFileOps(
        remove: { try FileManager.default.removeItem(at: $0) },
        overwriteEmpty: { url in
            // In place, not atomic: an atomic write needs a rename in the same folder, which is what
            // a failed remove suggests won't work. Truncate first, so a failed write leaves an empty
            // (unreadable, so pending) file rather than the old approvals.
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("{}".utf8))
            try handle.synchronize()
        },
        writeMarker: { url in
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
        },
        clearMarker: { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        })
}

/// #593 (-Echo): files whose saved choices were revoked in this process and not yet replaced by a
/// verified save. Holds standardized paths only.
final class SharedReviewRevocations: @unchecked Sendable {
    static let shared = SharedReviewRevocations()
    private let lock = NSLock()
    private var paths: Set<String> = []
    func revoke(_ file: URL) { lock.withLock { _ = paths.insert(file.standardizedFileURL.path) } }
    func clear(_ file: URL) { lock.withLock { _ = paths.remove(file.standardizedFileURL.path) } }
    func contains(_ file: URL) -> Bool { lock.withLock { paths.contains(file.standardizedFileURL.path) } }
}
