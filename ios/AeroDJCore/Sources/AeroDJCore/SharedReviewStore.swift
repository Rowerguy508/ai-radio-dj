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
/// save, the same marker and read-back `FileAudioCache` uses (`BackupExclusionMarking`). If the
/// mark fails or reads back unset, a content-free line is logged and the save still goes ahead:
/// review decisions are never dropped because of the flag, and the next save tries again.
public struct SharedReviewStore: Sendable {
    public let file: URL
    let backupExclusion: any BackupExclusionMarking
    let backupExclusionLog: @Sendable (String) -> Void

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
    /// unset read-back; a nil read-back (Linux) counts as excluded. Never blocks the save.
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
    public func load() -> [UUID: SharedReviewRecord] {
        guard let decoded = decodedFile() else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    /// Where an unreadable store is moved before the next save (Fry's #402 nit): `<file>.unreadable`.
    /// Fry's and Sentinel's #414 n1 (-Nova): only the newest copy is kept. Setting a new one aside
    /// removes every older `<file>.unreadable` and `<file>.unreadable-<uuid>` (left by earlier builds).
    public var unreadableBackupPrefix: URL { file.appendingPathExtension("unreadable") }

    public func save(_ records: [UUID: SharedReviewRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        markFolderExcludedFromBackup()
        try setAsideUnreadableFile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let keyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        try ProtectedFile.write(encoder.encode(keyed), to: file)
    }

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
